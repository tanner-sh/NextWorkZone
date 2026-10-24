//! 编辑 Wiki 页面时保留没有修改的内容。
//!
//! 文档模型不能完整表达页面的写法（列宽、表格样式、空段落、`&nbsp;`、颜色写法等），整页重新生成会改动大量没编辑过的地方。
//! 这里把编辑用的 HTML 按顶层拆成片段，记下每段的原文（占位块已换成 `<!--nwz:N-->`）和它产生了几个块；
//! 保存时把编辑后的块与原来的块对齐，整段没有修改的片段原样写回，只有修改过的块重新生成。

use serde::{Deserialize, Serialize};

use crate::html::from_html;
use crate::model::{Block, Doc};
use crate::xhtml::to_xhtml;

/// 一个顶层片段：原文（编辑格式，可直接还原为 storage）和它对应的块数。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    pub source: String,
    pub count: usize,
}

/// 编辑用的 HTML → 文档模型和片段。文档模型的块依次属于各个片段。
pub fn edit_load(html: &str) -> (Doc, Vec<Segment>) {
    let mut s = Splitter::default();
    s.split(html);
    // 末尾不产生块的内容（空段落等）并入最后一段
    if let Some(last) = s.segments.last_mut() {
        last.source.push_str(&s.pending);
    }
    (Doc { blocks: s.blocks }, s.segments)
}

/// 编辑后的文档 → 编辑格式的 XHTML。`baseline` 是编辑前的文档（与片段的块数一一对应）；
/// 所有块都没变的片段写回原文，其余的块重新生成。
pub fn edit_xhtml(segments: &[Segment], baseline: &Doc, edited: &Doc) -> String {
    let base = &baseline.blocks;
    let new = &edited.blocks;
    if segments.iter().map(|s| s.count).sum::<usize>() != base.len() {
        return to_xhtml(edited);
    }
    let matched = align(base, new);
    let mut seg_of = Vec::with_capacity(base.len());
    let mut seg_start = Vec::with_capacity(segments.len());
    for (s, seg) in segments.iter().enumerate() {
        seg_start.push(seg_of.len());
        seg_of.extend(std::iter::repeat_n(s, seg.count));
    }
    let mut out = String::new();
    let mut e = 0;
    while e < new.len() {
        if let Some(b) = matched[e] {
            let s = seg_of[b];
            let count = segments[s].count;
            if b == seg_start[s] && (0..count).all(|k| e + k < new.len() && matched[e + k] == Some(b + k)) {
                out.push_str(&segments[s].source);
                e += count;
                continue;
            }
        }
        out.push_str(&to_xhtml(&Doc { blocks: vec![new[e].clone()] }));
        e += 1;
    }
    out
}

/// 编辑后每个块对应的原来的块（最长公共子序列；先去掉相同的开头和结尾，通常只剩很少的块要比较）。
fn align(base: &[Block], new: &[Block]) -> Vec<Option<usize>> {
    let mut matched = vec![None; new.len()];
    let mut head = 0;
    while head < base.len() && head < new.len() && base[head] == new[head] {
        matched[head] = Some(head);
        head += 1;
    }
    let mut tail = 0;
    while tail < base.len() - head && tail < new.len() - head && base[base.len() - 1 - tail] == new[new.len() - 1 - tail] {
        matched[new.len() - 1 - tail] = Some(base.len() - 1 - tail);
        tail += 1;
    }
    let a = &base[head..base.len() - tail];
    let b = &new[head..new.len() - tail];
    let (n, m) = (a.len(), b.len());
    if n == 0 || m == 0 {
        return matched;
    }
    let mut lcs = vec![0u32; (n + 1) * (m + 1)];
    let at = |i: usize, j: usize| i * (m + 1) + j;
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[at(i, j)] = if a[i] == b[j] { lcs[at(i + 1, j + 1)] + 1 } else { lcs[at(i + 1, j)].max(lcs[at(i, j + 1)]) };
        }
    }
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        if a[i] == b[j] {
            matched[head + j] = Some(head + i);
            i += 1;
            j += 1;
        } else if lcs[at(i + 1, j)] >= lcs[at(i, j + 1)] {
            i += 1;
        } else {
            j += 1;
        }
    }
    matched
}

// ---------- 拆分 ----------

const VOID: &[&str] = &["br", "img", "hr", "col", "input", "meta", "link", "area", "base", "wbr", "source"];
const BLOCK: &[&str] = &["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "div", "blockquote", "pre", "hr"];

/// 一个标签：位置、名称、是否结束标签、是否自闭合。
struct Tag<'a> {
    start: usize,
    end: usize,
    name: String,
    closing: bool,
    selfclosing: bool,
    text: &'a str,
}

/// 从 `from` 开始找下一个标签（跳过注释）。注释作为自闭合的“标签”返回，名称为 `!--`。
fn next_tag(s: &str, from: usize) -> Option<Tag<'_>> {
    let bytes = s.as_bytes();
    let mut i = s[from..].find('<')? + from;
    loop {
        if s[i..].starts_with("<!--") {
            let end = s[i..].find("-->").map(|p| i + p + 3).unwrap_or(s.len());
            return Some(Tag { start: i, end, name: "!--".into(), closing: false, selfclosing: true, text: &s[i..end] });
        }
        let closing = bytes.get(i + 1) == Some(&b'/');
        let name_start = i + 1 + closing as usize;
        let name_len = s[name_start..].find(|c: char| !(c.is_ascii_alphanumeric() || c == ':' || c == '-')).unwrap_or(s.len() - name_start);
        if name_len == 0 {
            // 不是标签的“<”
            i = s[i + 1..].find('<')? + i + 1;
            continue;
        }
        // 找到“>”，跳过引号中的内容
        let mut j = name_start + name_len;
        let mut quote: Option<u8> = None;
        while j < bytes.len() {
            let c = bytes[j];
            match quote {
                Some(q) if c == q => quote = None,
                Some(_) => {}
                None if c == b'"' || c == b'\'' => quote = Some(c),
                None if c == b'>' => break,
                None => {}
            }
            j += 1;
        }
        let end = (j + 1).min(s.len());
        let name = s[name_start..name_start + name_len].to_ascii_lowercase();
        let selfclosing = !closing && (s[..end].ends_with("/>") || VOID.contains(&name.as_str()));
        return Some(Tag { start: i, end, name, closing, selfclosing, text: &s[i..end] });
    }
}

/// 与开始标签配对的结束标签的位置（结束标签的开始、结束）。
fn matching_end(s: &str, open: &Tag) -> (usize, usize) {
    let mut depth = 0;
    let mut pos = open.end;
    while let Some(t) = next_tag(s, pos) {
        pos = t.end;
        if t.selfclosing || t.name != open.name {
            continue;
        }
        if t.closing {
            if depth == 0 {
                return (t.start, t.end);
            }
            depth -= 1;
        } else {
            depth += 1;
        }
    }
    (s.len(), s.len())
}

fn attr_value<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let key = format!(" {name}=\"");
    let at = tag.find(&key)? + key.len();
    let end = tag[at..].find('"')? + at;
    Some(&tag[at..end])
}

fn is_container(tag: &Tag) -> bool {
    tag.name == "div" && attr_value(tag.text, "class").is_some_and(|c| c.split(' ').any(|c| c == "nwz-container"))
}

/// 占位块和布局容器换成标记：与编辑器保存时的写法相同。
fn placeholders(s: &str) -> String {
    let mut out = String::new();
    let mut pos = 0;
    while let Some(t) = next_tag(s, pos) {
        if !t.closing && !t.selfclosing {
            if let Some(n) = attr_value(t.text, "data-nwz") {
                let (_, end) = matching_end(s, &t);
                out.push_str(&s[pos..t.start]);
                out.push_str(&format!("<!--nwz:{n}-->"));
                pos = end;
                continue;
            }
            if is_container(&t) {
                let (close_start, close_end) = matching_end(s, &t);
                out.push_str(&s[pos..t.start]);
                out.push_str(&format!("<!--nwz:{}-->", attr_value(t.text, "data-nwz-open").unwrap_or_default()));
                out.push_str(&placeholders(&s[t.end..close_start]));
                out.push_str(&format!("<!--nwz:{}-->", attr_value(t.text, "data-nwz-close").unwrap_or_default()));
                pos = close_end;
                continue;
            }
        }
        out.push_str(&s[pos..t.end]);
        pos = t.end;
    }
    out.push_str(&s[pos..]);
    out
}

/// 拆分的结果：块、片段，以及还没有归属的原文（不产生块的空段落等，并入下一段）。
#[derive(Default)]
struct Splitter {
    blocks: Vec<Block>,
    segments: Vec<Segment>,
    pending: String,
}

impl Splitter {
    fn push(&mut self, source: String, produced: Vec<Block>) {
        if produced.is_empty() {
            self.pending.push_str(&source);
            return;
        }
        self.segments.push(Segment { source: std::mem::take(&mut self.pending) + &source, count: produced.len() });
        self.blocks.extend(produced);
    }

    /// 一段原文：空白并入下一段，其余转为块。
    fn push_html(&mut self, html: &str) {
        if html.trim().is_empty() {
            self.pending.push_str(html);
        } else {
            self.push(placeholders(html), from_html(html).blocks);
        }
    }

    /// 按顶层拆分：块级元素各成一段，相邻的行内内容合成一段，布局容器拆成开始标记、内部各段、结束标记。
    fn split(&mut self, html: &str) {
        let mut pos = 0;
        // 正在累积的行内内容的开始位置
        let mut run: Option<usize> = None;
        while let Some(t) = next_tag(html, pos) {
            let block_level = !t.closing && BLOCK.contains(&t.name.as_str()) && attr_value(t.text, "data-nwz").is_none();
            if !block_level {
                // 行内内容（含不可编辑的行内占位块）并入当前的一段
                run.get_or_insert(pos);
                pos = if !t.closing && !t.selfclosing { matching_end(html, &t).1 } else { t.end };
                continue;
            }
            self.push_html(&html[run.take().unwrap_or(pos)..t.start]);
            let (close_start, close_end) = if t.selfclosing { (t.end, t.end) } else { matching_end(html, &t) };
            if is_container(&t) {
                if let Some(n) = attr_value(t.text, "data-nwz-open").and_then(|v| v.parse().ok()) {
                    self.push(format!("<!--nwz:{n}-->"), vec![Block::Marker { n }]);
                }
                self.split(&html[t.end..close_start]);
                if let Some(n) = attr_value(t.text, "data-nwz-close").and_then(|v| v.parse().ok()) {
                    self.push(format!("<!--nwz:{n}-->"), vec![Block::Marker { n }]);
                }
            } else {
                let source = &html[t.start..close_end];
                self.push(placeholders(source), from_html(source).blocks);
            }
            pos = close_end;
        }
        self.push_html(&html[run.unwrap_or(pos)..]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Inline;

    const HTML: &str = concat!(
        r#"<div class="nwz-container" data-nwz-open="0" data-nwz-close="1">"#,
        r#"<p>文字 <strong>粗</strong> <span class="nwz-opaque" contenteditable="false" data-nwz="2"><span class="nwz-jira" data-jira-key="AB-1">AB-1</span></span></p>"#,
        r#"<p class="auto-cursor-target"><br /></p>"#,
        r#"<table class="wrapped"><colgroup><col style="width: 100.0px;" /></colgroup><tbody><tr><td>格</td></tr></tbody></table>"#,
        r#"<p>第二段&nbsp; 末尾</p>"#,
        "</div>"
    );

    fn identity() -> String {
        placeholders(HTML)
    }

    #[test]
    fn unchanged_round_trip_is_identical() {
        let (doc, segments) = edit_load(HTML);
        assert_eq!(segments.iter().map(|s| s.count).sum::<usize>(), doc.blocks.len());
        assert_eq!(segments.iter().map(|s| s.source.as_str()).collect::<String>(), identity());
        assert_eq!(edit_xhtml(&segments, &doc, &doc), identity());
    }

    #[test]
    fn only_changed_blocks_are_rewritten() {
        let (doc, segments) = edit_load(HTML);
        let mut edited = doc.clone();
        let last = edited.blocks.iter().rposition(|b| matches!(b, Block::Para { .. })).unwrap();
        edited.blocks[last] = Block::para(vec![Inline::text("改过")]);
        let out = edit_xhtml(&segments, &doc, &edited);
        // 表格的列宽、样式等原样保留，只有改过的段落重新生成
        assert!(out.contains(r#"<table class="wrapped"><colgroup><col style="width: 100.0px;" /></colgroup>"#), "{out}");
        assert!(out.contains("<p>改过</p>"), "{out}");
        assert!(!out.contains("第二段"), "{out}");
        assert!(out.starts_with("<!--nwz:0--><p>文字 <strong>粗</strong> <!--nwz:2--></p>"), "{out}");
        assert!(out.ends_with("<!--nwz:1-->"), "{out}");
    }

    #[test]
    fn inserted_block_keeps_neighbours() {
        let (doc, segments) = edit_load(HTML);
        let mut edited = doc.clone();
        edited.blocks.insert(2, Block::para(vec![Inline::text("新的")]));
        let out = edit_xhtml(&segments, &doc, &edited);
        assert!(out.contains("<p>新的</p>"), "{out}");
        assert!(out.contains("第二段&nbsp; 末尾"), "{out}");
    }
}
