//! Confluence storage 格式（XHTML + `ac:` 宏）的轻量扫描器。
//!
//! 只做“定位”，不做“重写”：记录每个标签在原文中的字节位置，修改时直接拼接原文片段，
//! 保证未修改的部分逐字节保持原样（重新序列化会改变格式，并可能破坏宏）。

use std::ops::Range;

use quick_xml::Reader;
use quick_xml::events::Event;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokKind {
    Start,
    End,
    Empty,
    Text,
    Other,
}

#[derive(Debug, Clone)]
pub struct Tok {
    pub kind: TokKind,
    /// 标签名（含命名空间前缀，例如 `ac:structured-macro`）；文本为空字符串。
    pub name: String,
    /// 在原文中的字节范围。
    pub span: Range<usize>,
    /// 元素所在的嵌套深度（顶层为 0）。
    pub depth: usize,
    /// 起始标签对应的结束标签下标。
    pub close: Option<usize>,
}

pub struct Doc<'a> {
    pub src: &'a str,
    pub toks: Vec<Tok>,
}

#[derive(Debug)]
pub struct ScanError(pub String);

impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "页面内容解析失败：{}", self.0)
    }
}

impl std::error::Error for ScanError {}

impl<'a> Doc<'a> {
    pub fn parse(src: &'a str) -> Result<Self, ScanError> {
        let mut reader = Reader::from_str(src);
        let config = reader.config_mut();
        config.check_end_names = false;
        config.allow_unmatched_ends = true;
        config.trim_text_start = false;
        config.trim_text_end = false;

        let mut toks: Vec<Tok> = Vec::new();
        let mut stack: Vec<usize> = Vec::new();
        loop {
            let start = reader.buffer_position() as usize;
            let event = reader.read_event().map_err(|e| ScanError(format!("{e}（位置 {start}）")))?;
            let end = reader.buffer_position() as usize;
            let depth = stack.len();
            let (kind, name) = match &event {
                Event::Eof => break,
                Event::Start(e) => (TokKind::Start, e.name().into_inner().to_string()),
                Event::End(e) => (TokKind::End, e.name().into_inner().to_string()),
                Event::Empty(e) => (TokKind::Empty, e.name().into_inner().to_string()),
                Event::Text(_) | Event::GeneralRef(_) => (TokKind::Text, String::new()),
                _ => (TokKind::Other, String::new()),
            };
            let index = toks.len();
            match kind {
                TokKind::Start => {
                    toks.push(Tok { kind, name, span: start..end, depth, close: None });
                    stack.push(index);
                }
                TokKind::End => {
                    // 找到同名的起始标签；容忍个别未闭合的标签。
                    if let Some(pos) = stack.iter().rposition(|&i| toks[i].name == name) {
                        let open = stack[pos];
                        stack.truncate(pos);
                        toks[open].close = Some(index);
                        toks.push(Tok { kind, name, span: start..end, depth: pos, close: None });
                    } else {
                        toks.push(Tok { kind: TokKind::Other, name, span: start..end, depth, close: None });
                    }
                }
                _ => toks.push(Tok { kind, name, span: start..end, depth, close: None }),
            }
        }
        Ok(Doc { src, toks })
    }

    /// 元素（起始标签下标）的完整字节范围，包含首尾标签。
    pub fn outer(&self, open: usize) -> Range<usize> {
        let tok = &self.toks[open];
        match tok.close {
            Some(close) => tok.span.start..self.toks[close].span.end,
            None => tok.span.clone(),
        }
    }

    /// 元素内部内容的字节范围（不含首尾标签）。
    pub fn inner(&self, open: usize) -> Range<usize> {
        let tok = &self.toks[open];
        match tok.close {
            Some(close) => tok.span.end..self.toks[close].span.start,
            None => tok.span.end..tok.span.end,
        }
    }

    /// 元素内部的 token 下标范围（不含首尾标签）。
    pub fn children(&self, open: usize) -> Range<usize> {
        match self.toks[open].close {
            Some(close) => open + 1..close,
            None => open + 1..open + 1,
        }
    }

    /// 某个 token 范围内的纯文本（解码实体、合并空白）。
    pub fn text(&self, range: Range<usize>) -> String {
        let mut out = String::new();
        for tok in &self.toks[range] {
            match tok.kind {
                TokKind::Text => out.push_str(&decode_entities(&self.src[tok.span.clone()])),
                TokKind::Empty if tok.name == "br" => out.push(' '),
                _ => {}
            }
        }
        collapse_whitespace(&out)
    }

    /// 在 token 范围内，查找某一深度上指定名称的起始标签。
    pub fn find_children(&self, range: Range<usize>, depth: usize, name: &str) -> Vec<usize> {
        range
            .filter(|&i| {
                let t = &self.toks[i];
                t.kind == TokKind::Start && t.depth == depth && t.name == name
            })
            .collect()
    }
}

pub fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 解码 storage 中常见的 HTML 实体（`&nbsp;` 等不属于 XML 预定义实体，需要自行处理）。
pub fn decode_entities(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(pos) = rest.find('&') {
        out.push_str(&rest[..pos]);
        rest = &rest[pos..];
        // 实体名很短，只在 `&` 之后的少量字符内找 `;`（按字符而不是字节，避免切断中文）
        let Some(end) = rest.char_indices().take(12).find(|&(_, c)| c == ';').map(|(i, _)| i) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let entity = &rest[1..end];
        let decoded = match entity {
            "nbsp" | "ensp" | "emsp" | "thinsp" => Some(' '),
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "ndash" => Some('–'),
            "mdash" => Some('—'),
            "hellip" => Some('…'),
            "middot" => Some('·'),
            "ldquo" => Some('“'),
            "rdquo" => Some('”'),
            "lsquo" => Some('‘'),
            "rsquo" => Some('’'),
            "times" => Some('×'),
            _ => named_entity(entity).or_else(|| entity
                .strip_prefix("#x")
                .or_else(|| entity.strip_prefix("#X"))
                .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                .or_else(|| entity.strip_prefix('#').and_then(|dec| dec.parse().ok()))
                .and_then(char::from_u32)),
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// 其他常见的 HTML 命名实体（Confluence 编辑器会写入 `&rarr;`、`&ne;` 等）。
fn named_entity(name: &str) -> Option<char> {
    Some(match name {
        "rarr" => '→',
        "larr" => '←',
        "uarr" => '↑',
        "darr" => '↓',
        "harr" => '↔',
        "rArr" => '⇒',
        "lArr" => '⇐',
        "hArr" => '⇔',
        "ne" => '≠',
        "le" => '≤',
        "ge" => '≥',
        "asymp" => '≈',
        "plusmn" => '±',
        "divide" => '÷',
        "minus" => '−',
        "deg" => '°',
        "permil" => '‰',
        "infin" => '∞',
        "radic" => '√',
        "sum" => '∑',
        "copy" => '©',
        "reg" => '®',
        "trade" => '™',
        "laquo" => '«',
        "raquo" => '»',
        "lsaquo" => '‹',
        "rsaquo" => '›',
        "bdquo" => '„',
        "sbquo" => '‚',
        "bull" => '•',
        "sect" => '§',
        "para" => '¶',
        "dagger" => '†',
        "yen" => '¥',
        "euro" => '€',
        "pound" => '£',
        "cent" => '¢',
        "iexcl" => '¡',
        "iquest" => '¿',
        "shy" => '\u{ad}',
        "zwj" => '\u{200d}',
        "zwnj" => '\u{200c}',
        "acute" => '´',
        "uml" => '¨',
        "macr" => '¯',
        "frac12" => '½',
        "frac14" => '¼',
        "frac34" => '¾',
        "sup1" => '¹',
        "sup2" => '²',
        "sup3" => '³',
        "micro" => 'µ',
        "alpha" => 'α',
        "beta" => 'β',
        "gamma" => 'γ',
        "delta" => 'δ',
        "pi" => 'π',
        "sigma" => 'σ',
        "mu" => 'μ',
        "lambda" => 'λ',
        "Delta" => 'Δ',
        "Omega" => 'Ω',
        "check" => '✓',
        "hearts" => '♥',
        "star" => '☆',
        _ => return None,
    })
}

/// 把 `&amp;` `&lt;` `&gt;` 以外的实体换成字符，用于比较两份 storage 的内容是否相同
/// （浏览器序列化时会把 `&rarr;` 写成 `→`、文字中的 `&quot;` 写成 `"`，含义不变）。只用于比较，不用于保存。
pub fn normalize_entities(storage: &str) -> String {
    let mut out = String::with_capacity(storage.len());
    let mut rest = storage;
    while let Some(pos) = rest.find('&') {
        out.push_str(&rest[..pos]);
        rest = &rest[pos..];
        let end = rest.char_indices().take(12).find(|&(_, c)| c == ';').map(|(i, _)| i);
        match end.map(|e| (e, &rest[1..e])) {
            Some((e, name)) if !matches!(name, "amp" | "lt" | "gt") => {
                let decoded = decode_entities(&rest[..=e]);
                if decoded.chars().count() == 1 && !decoded.starts_with('&') {
                    out.push_str(&decoded);
                    rest = &rest[e + 1..];
                    continue;
                }
                out.push('&');
                rest = &rest[1..];
            }
            _ => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

pub fn escape_text(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_spans_and_depth() {
        let src = "<h1>标题</h1><table><tbody><tr><td>a&nbsp;b<br />c</td></tr></tbody></table>";
        let doc = Doc::parse(src).unwrap();
        let tds = doc.find_children(0..doc.toks.len(), 3, "td");
        assert_eq!(tds.len(), 1);
        assert_eq!(&src[doc.inner(tds[0])], "a&nbsp;b<br />c");
        assert_eq!(doc.text(doc.children(tds[0])), "a b c");
        let h1 = doc.find_children(0..doc.toks.len(), 0, "h1");
        assert_eq!(&src[doc.outer(h1[0])], "<h1>标题</h1>");
    }

    #[test]
    fn decodes_entities() {
        assert_eq!(decode_entities("a&nbsp;&ndash;&#65;&#x42;&unknown;&"), "a –AB&unknown;&");
        assert_eq!(decode_entities("费用&融易报周报汇总"), "费用&融易报周报汇总");
        assert_eq!(decode_entities("A&B；中文"), "A&B；中文");
        assert_eq!(decode_entities("1.14&rarr;1.30 &ne;"), "1.14→1.30 ≠");
        assert_eq!(normalize_entities("a&rarr;b &amp; &lt;p&gt; &#160; &quot;x&quot;"), "a→b &amp; &lt;p&gt; \u{a0} \"x\"");
    }
}
