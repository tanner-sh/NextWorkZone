//! 在应用内编辑页面：storage ⇄ 可编辑的 HTML。
//!
//! storage 本身就是 XHTML，普通的段落、标题、列表、表格、文字格式原样交给编辑器；
//! 宏、图片、页面链接等 `ac:` / `ri:` 元素无法在 HTML 编辑器中安全编辑，替换为不可编辑的占位块，
//! 原文保存在 `fragments` 中。保存时编辑器把占位块序列化为 `<!--nwz:N-->`，这里再换回原文，
//! 因此这些内容逐字节保持不变。页面布局（`ac:layout*`）只是容器，其中的内容仍可编辑。

use std::sync::LazyLock;

use nextworkzone_core::{Error, Result};
use quick_xml::Reader;
use quick_xml::events::Event;
use regex::Regex;
use serde::Serialize;

use crate::storage::{Doc, TokKind, escape_text};
use crate::text::{attr, readable_lines};

static MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<!--nwz:(\d+)-->").unwrap());

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Editable {
    pub html: String,
    /// 占位块对应的 storage 原文，下标即占位编号。
    pub fragments: Vec<String>,
    /// 内容中提到的用户（userkey），供界面显示名字。
    pub users: Vec<String>,
}

/// HTML 的空元素，可以自闭合。
const VOID_ELEMENTS: &[&str] = &["br", "hr", "img", "col", "wbr", "area", "input", "source"];
/// 只是容器的元素：保留首尾标签，内容可编辑。
const CONTAINERS: &[&str] = &["ac:layout", "ac:layout-section", "ac:layout-cell"];
/// 行内评论标记：包着被评论的文字，文字仍可编辑。
const INLINE_CONTAINER: &str = "ac:inline-comment-marker";
/// 行内显示的宏。
const INLINE_MACROS: &[&str] = &["jira", "status", "anchor", "emoticon", "mention", "profile-picture", "lozenge", "highlight"];
const INLINE_ELEMENTS: &[&str] = &["ac:link", "ac:image", "ac:emoticon", "ac:placeholder", "ri:user", "ri:page", "ri:attachment", "at:var", "time"];

pub fn to_editable(storage: &str) -> Result<Editable> {
    let doc = Doc::parse(storage).map_err(|e| Error::Other(e.to_string()))?;
    let mut ed = Editable { html: String::new(), fragments: Vec::new(), users: Vec::new() };
    emit(&doc, 0..doc.toks.len(), &mut ed);
    Ok(ed)
}

fn emit(doc: &Doc, range: std::ops::Range<usize>, ed: &mut Editable) {
    let mut i = range.start;
    while i < range.end {
        let tok = &doc.toks[i];
        let src = &doc.src[tok.span.clone()];
        match tok.kind {
            TokKind::Text => ed.html.push_str(src),
            TokKind::Other => {
                if let Some(body) = src.strip_prefix("<![CDATA[").and_then(|t| t.strip_suffix("]]>")) {
                    ed.html.push_str(&escape_text(body));
                }
            }
            TokKind::End => {}
            TokKind::Start | TokKind::Empty => {
                let name = tok.name.as_str();
                // 自闭合的非空元素（如日期 `<time … />`）在 HTML 中会吞掉后面的内容，作为占位块保留
                let self_closing = tok.kind == TokKind::Empty && !VOID_ELEMENTS.contains(&name);
                if !name.contains(':') && !self_closing {
                    ed.html.push_str(src);
                    if tok.kind == TokKind::Start {
                        emit(doc, doc.children(i), ed);
                        if let Some(close) = tok.close {
                            ed.html.push_str(&doc.src[doc.toks[close].span.clone()]);
                        }
                        i = tok.close.unwrap_or(i);
                    }
                } else if (CONTAINERS.contains(&name) || name == INLINE_CONTAINER) && tok.kind == TokKind::Start && tok.close.is_some() {
                    let close = tok.close.unwrap();
                    let open_n = push_fragment(ed, src.to_string());
                    let close_n = push_fragment(ed, doc.src[doc.toks[close].span.clone()].to_string());
                    let tag = if name == INLINE_CONTAINER { "span" } else { "div" };
                    ed.html.push_str(&format!(r#"<{tag} class="nwz-container" data-nwz-open="{open_n}" data-nwz-close="{close_n}">"#));
                    emit(doc, doc.children(i), ed);
                    ed.html.push_str(&format!("</{tag}>"));
                    i = close;
                } else {
                    let outer = doc.outer(i);
                    let n = push_fragment(ed, doc.src[outer].to_string());
                    let (inline, label) = describe(doc, i, ed);
                    // 一律用 span：宏常出现在段落中，段落里的 div 会被浏览器拆开，改变页面结构
                    let class = if inline { "nwz-opaque" } else { "nwz-opaque nwz-block" };
                    ed.html.push_str(&format!(r#"<span class="{class}" contenteditable="false" data-nwz="{n}">{label}</span>"#));
                    i = tok.close.unwrap_or(i);
                }
            }
        }
        i += 1;
    }
}

fn push_fragment(ed: &mut Editable, source: String) -> usize {
    ed.fragments.push(source);
    ed.fragments.len() - 1
}

fn escape_attr(text: &str) -> String {
    escape_text(text).replace('"', "&quot;")
}

/// 宏的参数值。
fn param(doc: &Doc, open: usize, name: &str) -> Option<String> {
    doc.children(open).find_map(|j| {
        let t = &doc.toks[j];
        (t.kind == TokKind::Start && t.name == "ac:parameter" && attr(&doc.src[t.span.clone()], "ac:name").as_deref() == Some(name))
            .then(|| doc.text(doc.children(j)))
    })
}

/// 第一个指定名称的子元素。
fn child(doc: &Doc, open: usize, name: &str) -> Option<usize> {
    doc.children(open).find(|&j| doc.toks[j].name == name && matches!(doc.toks[j].kind, TokKind::Start | TokKind::Empty))
}

/// 占位块是否行内显示，以及显示的内容（HTML，只用 span，原因同上）。
fn describe(doc: &Doc, i: usize, ed: &mut Editable) -> (bool, String) {
    let tok = &doc.toks[i];
    let src = &doc.src[tok.span.clone()];
    let name = tok.name.as_str();
    match name {
        "ac:structured-macro" | "ac:macro" => {
            let macro_name = attr(src, "ac:name").unwrap_or_default();
            let inline = INLINE_MACROS.contains(&macro_name.as_str());
            let label = match macro_name.as_str() {
                "jira" => match param(doc, i, "key") {
                    Some(key) => format!(r#"<span class="nwz-jira" data-jira-key="{}">{}</span>"#, escape_attr(&key), escape_text(&key)),
                    None => "Jira 问题列表".to_string(),
                },
                "status" => format!(r#"<span class="nwz-status">{}</span>"#, escape_text(&param(doc, i, "title").unwrap_or_default())),
                "anchor" => "⚓".to_string(),
                "code" | "noformat" => {
                    let body = child(doc, i, "ac:plain-text-body").map(|b| {
                        doc.children(b)
                            .filter_map(|j| doc.src[doc.toks[j].span.clone()].strip_prefix("<![CDATA[").and_then(|t| t.strip_suffix("]]>")))
                            .collect::<String>()
                    });
                    let title = param(doc, i, "title").map(|t| format!(r#"<span class="nwz-macro-title">{}</span>"#, escape_text(&t))).unwrap_or_default();
                    format!(r#"{title}<span class="nwz-code">{}</span>"#, escape_text(&body.unwrap_or_default()))
                }
                _ => {
                    let title = param(doc, i, "title");
                    let body = child(doc, i, "ac:rich-text-body")
                        .map(|b| readable_lines(&doc.src[doc.inner(b)]))
                        .unwrap_or_default();
                    let mut html = format!(
                        r#"<span class="nwz-macro-title">{}{}</span>"#,
                        escape_text(&macro_label(&macro_name)),
                        title.map(|t| format!("：{}", escape_text(&t))).unwrap_or_default()
                    );
                    for line in body.iter().take(12) {
                        html.push_str(&format!(r#"<span class="nwz-line">{}</span>"#, escape_text(line)));
                    }
                    if body.len() > 12 {
                        html.push_str(r#"<span class="nwz-line">…</span>"#);
                    }
                    html
                }
            };
            (inline, label)
        }
        "ac:task-list" => {
            let mut html = String::new();
            for t in crate::text::inline_tasks(&doc.src[doc.outer(i)]) {
                for key in &t.assignees {
                    if !ed.users.contains(key) {
                        ed.users.push(key.clone());
                    }
                }
                html.push_str(&format!(r#"<span class="nwz-line">{} {}</span>"#, if t.done { "☑" } else { "☐" }, escape_text(&t.text)));
            }
            (false, html)
        }
        "ac:image" => {
            let label = if let Some(a) = child(doc, i, "ri:attachment") {
                let file = attr(&doc.src[doc.toks[a].span.clone()], "ri:filename").unwrap_or_default();
                format!(r#"<img data-nwz-attachment="{}" alt="{}">"#, escape_attr(&file), escape_attr(&file))
            } else if let Some(u) = child(doc, i, "ri:url") {
                let url = attr(&doc.src[doc.toks[u].span.clone()], "ri:value").unwrap_or_default();
                format!(r#"<img data-nwz-url="{}" alt="">"#, escape_attr(&url))
            } else {
                "[图片]".to_string()
            };
            (true, label)
        }
        "ac:link" => {
            let body = child(doc, i, "ac:plain-text-link-body")
                .or_else(|| child(doc, i, "ac:link-body"))
                .map(|b| doc.text(doc.children(b)).replace("<![CDATA[", "").replace("]]>", ""))
                .filter(|t| !t.is_empty());
            let label = if let Some(u) = child(doc, i, "ri:user") {
                let key = attr(&doc.src[doc.toks[u].span.clone()], "ri:userkey").or_else(|| attr(&doc.src[doc.toks[u].span.clone()], "ri:username")).unwrap_or_default();
                if !ed.users.contains(&key) {
                    ed.users.push(key.clone());
                }
                format!(r#"<span class="nwz-user" data-nwz-user="{}">@用户</span>"#, escape_attr(&key))
            } else {
                let target = child(doc, i, "ri:page")
                    .and_then(|p| attr(&doc.src[doc.toks[p].span.clone()], "ri:content-title"))
                    .or_else(|| child(doc, i, "ri:attachment").and_then(|p| attr(&doc.src[doc.toks[p].span.clone()], "ri:filename")))
                    .or_else(|| attr(src, "ac:anchor"))
                    .unwrap_or_else(|| "链接".into());
                format!(r#"<span class="nwz-link">{}</span>"#, escape_text(&body.unwrap_or(target)))
            };
            (true, label)
        }
        "ac:emoticon" => (true, emoticon(&attr(src, "ac:name").unwrap_or_default()).to_string()),
        "time" => (true, format!(r#"<span class="nwz-date">{}</span>"#, escape_text(&attr(src, "datetime").unwrap_or_default()))),
        "ac:placeholder" => (true, format!(r#"<span class="nwz-placeholder">{}</span>"#, escape_text(&doc.text(doc.children(i))))),
        _ => {
            let inline = INLINE_ELEMENTS.contains(&name);
            let text = readable_lines(&doc.src[doc.outer(i)]).join(" ");
            (inline, if text.is_empty() { format!("[{}]", escape_text(name)) } else { escape_text(&text) })
        }
    }
}

fn macro_label(name: &str) -> String {
    match name {
        "info" => "信息".into(),
        "note" => "注意".into(),
        "tip" => "提示".into(),
        "warning" => "警告".into(),
        "panel" => "面板".into(),
        "expand" => "展开块".into(),
        "toc" => "目录".into(),
        "children" => "子页面列表".into(),
        "include" | "excerpt-include" => "引用其他页面".into(),
        "excerpt" => "摘要".into(),
        "section" | "column" => "分栏".into(),
        "attachments" => "附件列表".into(),
        _ => format!("宏 {name}"),
    }
}

fn emoticon(name: &str) -> &'static str {
    match name {
        "smile" => "🙂",
        "sad" => "🙁",
        "cheeky" => "😛",
        "laugh" => "😄",
        "wink" => "😉",
        "thumbs-up" => "👍",
        "thumbs-down" => "👎",
        "information" => "ℹ️",
        "tick" => "✅",
        "cross" => "❌",
        "warning" => "⚠️",
        "plus" => "➕",
        "minus" => "➖",
        "question" => "❓",
        "light-on" | "light-off" => "💡",
        "yellow-star" | "red-star" | "green-star" | "blue-star" => "⭐",
        "heart" => "❤️",
        "broken-heart" => "💔",
        _ => "🙂",
    }
}

/// 把编辑器序列化后的 XHTML（占位块为 `<!--nwz:N-->`）还原为 storage，并检查格式是否正确。
pub fn from_editable(xhtml: &str, fragments: &[String]) -> Result<String> {
    let mut missing = None;
    let storage = MARKER
        .replace_all(xhtml, |c: &regex::Captures| {
            let n: usize = c[1].parse().unwrap_or(usize::MAX);
            match fragments.get(n) {
                Some(f) => f.clone(),
                None => {
                    missing = Some(n);
                    String::new()
                }
            }
        })
        .into_owned();
    if let Some(n) = missing {
        return Err(Error::Other(format!("编辑内容中有无法识别的占位块（{n}）")));
    }
    validate(&storage)?;
    Ok(storage)
}

/// 检查 storage 是否是格式正确的 XML（标签配对、属性加引号等），避免把损坏的内容保存到页面。
pub fn validate(storage: &str) -> Result<()> {
    let wrapped = format!(r#"<nwz-root xmlns:ac="urn:ac" xmlns:ri="urn:ri" xmlns:at="urn:at">{storage}</nwz-root>"#);
    let mut reader = Reader::from_str(&wrapped);
    reader.config_mut().check_end_names = true;
    loop {
        match reader.read_event() {
            Ok(Event::Eof) => return Ok(()),
            Ok(_) => {}
            Err(e) => return Err(Error::Other(format!("页面内容格式不正确，未保存：{e}"))),
        }
    }
}

/// Confluence 模板中的变量声明和变量在新页面中没有意义：去掉声明，变量换成空白。
pub fn strip_template_variables(storage: &str) -> String {
    static DECL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<at:declarations\s*/>|<at:declarations>.*?</at:declarations>").unwrap());
    static VAR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<at:var\b[^>]*/>|<at:var\b[^>]*>.*?</at:var>").unwrap());
    VAR.replace_all(&DECL.replace_all(storage, ""), "").into_owned()
}

/// 纯文本（评论等）转为 storage：每行一个段落。
pub fn plain_to_storage(text: &str) -> String {
    text.trim()
        .split('\n')
        .map(|line| if line.trim().is_empty() { "<p>&nbsp;</p>".to_string() } else { format!("<p>{}</p>", escape_text(line)) })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = r#"<ac:layout><ac:layout-section ac:type="single"><ac:layout-cell><p>文字 <strong>粗</strong> <ac:structured-macro ac:name="jira" ac:schema-version="1"><ac:parameter ac:name="key">AB-1</ac:parameter></ac:structured-macro></p><ac:structured-macro ac:name="code"><ac:plain-text-body><![CDATA[a < b]]></ac:plain-text-body></ac:structured-macro><p><ac:link><ri:user ri:userkey="k1" /></ac:link></p></ac:layout-cell></ac:layout-section></ac:layout>"#;

    #[test]
    fn opaque_and_containers() {
        let ed = to_editable(PAGE).unwrap();
        assert_eq!(ed.fragments.len(), 9, "{:?}", ed.fragments);
        assert!(ed.html.contains("<strong>粗</strong>"));
        assert!(ed.html.contains(r#"data-jira-key="AB-1""#));
        assert!(ed.html.contains(r#"<span class="nwz-code">a &lt; b</span>"#));
        assert!(ed.html.contains(r#"data-nwz-user="k1""#));
        assert_eq!(ed.users, vec!["k1"]);
        assert!(ed.html.starts_with(r#"<div class="nwz-container" data-nwz-open="0" data-nwz-close="1">"#), "{}", ed.html);
    }

    #[test]
    fn round_trip() {
        let ed = to_editable(PAGE).unwrap();
        // 模拟编辑器的序列化：容器换成首尾两个标记，占位块换成一个标记
        let container = Regex::new(r#"<div class="nwz-container" data-nwz-open="(\d+)" data-nwz-close="(\d+)">"#).unwrap();
        let mut html = ed.html.clone();
        let mut closes = Vec::new();
        for c in container.captures_iter(&ed.html) {
            html = html.replacen(&c[0], &format!("<!--nwz:{}-->", &c[1]), 1);
            closes.push(c[2].to_string());
        }
        let opaque = Regex::new(r#"<(span) class="nwz-opaque[^"]*" contenteditable="false" data-nwz="(\d+)">"#).unwrap();
        loop {
            let Some(c) = opaque.captures(&html) else { break };
            let (whole, tag, n) = (c.get(0).unwrap(), c[1].to_string(), c[2].to_string());
            // 找到配对的结束标签
            let mut depth = 0;
            let mut pos = whole.end();
            let open = format!("<{tag}");
            let close = format!("</{tag}>");
            loop {
                let next_open = html[pos..].find(&open).map(|p| p + pos);
                let next_close = html[pos..].find(&close).map(|p| p + pos).unwrap();
                match next_open {
                    Some(o) if o < next_close => {
                        depth += 1;
                        pos = o + open.len();
                    }
                    _ if depth > 0 => {
                        depth -= 1;
                        pos = next_close + close.len();
                    }
                    _ => {
                        html.replace_range(whole.start()..next_close + close.len(), &format!("<!--nwz:{n}-->"));
                        break;
                    }
                }
            }
        }
        for n in &closes {
            let at = html.rfind("</div>").unwrap();
            html.replace_range(at..at + 6, &format!("<!--nwz:{n}-->"));
        }
        assert_eq!(from_editable(&html, &ed.fragments).unwrap(), PAGE);
    }

    #[test]
    fn rejects_broken_xml() {
        assert!(from_editable("<p>a<b>c</p>", &[]).is_err());
        assert!(from_editable("<p>x<!--nwz:5--></p>", &[]).is_err());
        assert!(validate("<p>a&nbsp;b<br /></p>").is_ok());
    }

    #[test]
    fn self_closing_date() {
        let ed = to_editable(r#"<p>截止 <time datetime="2026-10-30" /> 前完成<br /></p>"#).unwrap();
        assert_eq!(ed.fragments, vec![r#"<time datetime="2026-10-30" />"#]);
        assert!(ed.html.contains("2026-10-30</span></span> 前完成<br />"), "{}", ed.html);
    }

    #[test]
    fn template_variables() {
        let s = r#"<at:declarations><at:string at:name="x" /></at:declarations><p>日期 <at:var at:name="x" /></p>"#;
        assert_eq!(strip_template_variables(s), "<p>日期 </p>");
        assert_eq!(plain_to_storage("a<b\n\nc"), "<p>a&lt;b</p><p>&nbsp;</p><p>c</p>");
    }
}
