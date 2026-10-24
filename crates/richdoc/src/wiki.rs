//! 文档模型 → Jira wiki 标记（描述、评论等多行文本字段）。规则与 Tauri 版的 htmlToWiki 相同。

use crate::model::{Block, Doc, Inline, Item, marks};

/// 行内格式标记先用占位符表示，最后根据前后字符决定写成 `*x*` 还是 `{*}x{*}`：
/// Jira 只在标记两侧不是字母、数字（含汉字）时识别简写形式。
const OPEN: char = '\u{E000}';
const CLOSE: char = '\u{E001}';

/// Jira 表情图标 → wiki 写法
const EMOTICONS: &[(&str, &str)] = &[
    ("smile", ":)"),
    ("sad", ":("),
    ("tongue", ":P"),
    ("biggrin", ":D"),
    ("wink", ";)"),
    ("thumbs_up", "(y)"),
    ("thumbs_down", "(n)"),
    ("information", "(i)"),
    ("check", "(/)"),
    ("error", "(x)"),
    ("warning", "(!)"),
    ("add", "(+)"),
    ("forbidden", "(-)"),
    ("help_16", "(?)"),
    ("lightbulb_on", "(on)"),
    ("lightbulb", "(off)"),
    ("star_yellow", "(*)"),
    ("star_red", "(*r)"),
    ("star_green", "(*g)"),
    ("star_blue", "(*b)"),
    ("flag", "(flag)"),
    ("flag_grey", "(flagoff)"),
];

pub fn to_wiki(doc: &Doc) -> String {
    let blocks = blocks(&doc.blocks, false);
    let text = resolve_marks(&blocks.join("\n\n"));
    collapse_blank_lines(&text).trim().to_string()
}

fn collapse_blank_lines(text: &str) -> String {
    let mut out = String::new();
    let mut newlines = 0;
    for c in text.chars() {
        if c == '\n' {
            newlines += 1;
            if newlines <= 2 {
                out.push(c);
            }
        } else {
            newlines = 0;
            out.push(c);
        }
    }
    out
}

fn blocks(list: &[Block], in_table: bool) -> Vec<String> {
    list.iter().filter_map(|b| block(b, in_table)).filter(|s| !s.trim().is_empty()).collect()
}

fn block(b: &Block, in_table: bool) -> Option<String> {
    Some(match b {
        Block::Para { inl } => escape_line_starts(&inline(inl, in_table)),
        Block::Heading { level, inl, .. } => format!("h{}. {}", level.clamp(&1, &6), inline(inl, in_table).trim()),
        Block::List { ordered, items, .. } => list(*ordered, items, "", in_table),
        Block::Quote { blocks: inner } => {
            let text = blocks(inner, in_table).join("\n\n");
            if text.contains('\n') { format!("{{quote}}\n{text}\n{{quote}}") } else { format!("bq. {text}") }
        }
        Block::Code { lang, text } => {
            if lang.is_empty() {
                format!("{{noformat}}\n{text}\n{{noformat}}")
            } else {
                format!("{{code:{lang}}}\n{text}\n{{code}}")
            }
        }
        Block::Table { rows } => rows
            .iter()
            .filter_map(|row| {
                let mut line = String::new();
                let mut last = "|";
                for cell in &row.cells {
                    let sep = if cell.head { "||" } else { "|" };
                    // 单元格内可以续行，但不能有空行（会结束表格）
                    let content = blocks(&cell.blocks, true).join("\n").split('\n').filter(|l| !l.trim().is_empty()).collect::<Vec<_>>().join("\n");
                    line.push_str(sep);
                    line.push_str(if content.trim().is_empty() { " " } else { content.trim() });
                    last = sep;
                }
                (!line.is_empty()).then(|| line + last)
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Block::Rule => "----".into(),
        Block::Panel { kind, title, blocks: inner } => {
            let text = blocks(inner, in_table).join("\n\n");
            let name = match kind.as_str() {
                "info" | "note" | "warning" | "tip" => kind.as_str(),
                _ => "panel",
            };
            if title.is_empty() { format!("{{{name}}}\n{text}\n{{{name}}}") } else { format!("{{{name}:title={title}}}\n{text}\n{{{name}}}") }
        }
        Block::Opaque(o) => o.label.clone(),
        Block::Marker { .. } => return None,
    })
}

fn list(ordered: bool, items: &[Item], prefix: &str, in_table: bool) -> String {
    let marker = format!("{prefix}{}", if ordered { "#" } else { "*" });
    let mut lines = Vec::new();
    for item in items {
        let (nested, rest): (Vec<&Block>, Vec<&Block>) = item.blocks.iter().partition(|b| matches!(b, Block::List { .. }));
        // 列表项内的换行写成续行；空行会结束列表，多个段落用空格连接
        let text = rest.iter().filter_map(|b| block(b, in_table)).collect::<Vec<_>>().join(" ");
        let text = text.split('\n').filter(|l| !l.trim().is_empty()).collect::<Vec<_>>().join("\n");
        let task = item.task.as_ref().map(|t| if t.done { "(/) " } else { "(x) " }).unwrap_or("");
        lines.push(format!("{marker} {task}{text}"));
        for b in nested {
            if let Block::List { ordered, items, .. } = b {
                lines.push(list(*ordered, items, &marker, in_table));
            }
        }
    }
    lines.join("\n")
}

fn inline(list: &[Inline], in_table: bool) -> String {
    let mut out = String::new();
    for i in list {
        match i {
            Inline::Text { s, m, link, color } => {
                let mut text = if m & marks::CODE != 0 {
                    wrap("{{", &s.replace('{', "\\{").replace('}', "\\}"))
                } else {
                    escape_text(s, in_table)
                };
                if m & marks::CODE == 0 {
                    if m & marks::SUB != 0 {
                        text = wrap("~", &text);
                    }
                    if m & marks::SUP != 0 {
                        text = wrap("^", &text);
                    }
                    if m & marks::STRIKE != 0 {
                        text = wrap("-", &text);
                    }
                    if m & marks::UNDERLINE != 0 {
                        text = wrap("+", &text);
                    }
                    if m & marks::ITALIC != 0 {
                        text = wrap("_", &text);
                    }
                    if m & marks::BOLD != 0 {
                        text = wrap("*", &text);
                    }
                }
                if let Some(color) = color
                    && !text.trim().is_empty()
                {
                    text = format!("{{color:{color}}}{text}{{color}}");
                }
                match link {
                    Some(href) if !href.starts_with('#') => {
                        // 自动识别的网址：链接文字就是地址本身
                        if s.trim() == href || percent_decode(s.trim()) == percent_decode(href) {
                            out.push_str(&format!("[{href}]"));
                        } else {
                            let label = text.trim().replace('|', "\\|").replace(']', "\\]");
                            out.push_str(&format!("[{label}|{href}]"));
                        }
                    }
                    _ => out.push_str(&text),
                }
            }
            Inline::Br => out.push('\n'),
            Inline::Image { src, file, thumb, width, height, .. } => {
                let params: Vec<String> = if *thumb {
                    vec!["thumbnail".into()]
                } else {
                    [width.map(|w| format!("width={w}")), height.map(|h| format!("height={h}"))].into_iter().flatten().collect()
                };
                let suffix = if params.is_empty() { String::new() } else { format!("|{}", params.join(",")) };
                if let Some(file) = file {
                    out.push_str(&format!("!{file}{suffix}!"));
                } else if let Some(name) = emoticon(src) {
                    out.push_str(name);
                } else if src.starts_with("http://") || src.starts_with("https://") {
                    out.push_str(&format!("!{src}{suffix}!"));
                }
            }
            Inline::Issue { key } => out.push_str(key),
            Inline::Status { text, .. } => out.push_str(&escape_text(text, in_table)),
            Inline::Mention { name, user } => {
                if user.is_empty() {
                    out.push_str(&escape_text(&format!("@{name}"), in_table));
                } else {
                    out.push_str(&format!("[~{user}]"));
                }
            }
            Inline::Attachment { file } => out.push_str(&format!("[^{file}]")),
            Inline::Opaque(o) => out.push_str(&o.label),
            Inline::Marker { .. } => {}
        }
    }
    out
}

fn emoticon(src: &str) -> Option<&'static str> {
    let rest = src.split("/images/icons/emoticons/").nth(1)?;
    let name = rest.split('.').next()?;
    EMOTICONS.iter().find(|(n, _)| *n == name).map(|(_, w)| *w)
}

fn percent_decode(s: &str) -> String {
    crate::html::percent_decode(s)
}

fn wrap(mark: &str, inner: &str) -> String {
    if inner.trim().is_empty() {
        return inner.to_string();
    }
    let lead = &inner[..inner.len() - inner.trim_start().len()];
    let trail = &inner[inner.trim_end().len()..];
    let core = inner.trim();
    format!("{lead}{OPEN}{mark}{OPEN}{core}{CLOSE}{mark}{CLOSE}{trail}")
}

fn is_word(c: Option<char>) -> bool {
    c.is_some_and(|c| c.is_alphanumeric())
}

/// 把占位的格式标记落实为 `*x*`，或在紧挨文字时写成 `{*}x{*}`。
fn resolve_marks(text: &str) -> String {
    let mut chars: Vec<char> = text.chars().collect();
    // 找第一个开始标记 OPEN mark OPEN
    while let Some(start) = chars.iter().position(|&c| c == OPEN) {
        let Some(end_rel) = chars[start + 1..].iter().position(|&c| c == OPEN) else { break };
        let end = start + 1 + end_rel;
        let mark: String = chars[start + 1..end].iter().collect();
        let open_len = end - start + 1;
        // 对应的结束标记（考虑嵌套的同类标记）
        let open_tok: Vec<char> = format!("{OPEN}{mark}{OPEN}").chars().collect();
        let close_tok: Vec<char> = format!("{CLOSE}{mark}{CLOSE}").chars().collect();
        let mut depth = 0;
        let mut close_at = None;
        let mut i = end + 1;
        while i < chars.len() {
            if chars[i..].starts_with(&open_tok) {
                depth += 1;
            } else if chars[i..].starts_with(&close_tok) {
                if depth == 0 {
                    close_at = Some(i);
                    break;
                }
                depth -= 1;
            }
            i += 1;
        }
        let Some(close_at) = close_at else {
            chars.drain(start..start + open_len);
            continue;
        };
        let before = visible(&chars[..start], true);
        let after = visible(&chars[close_at + close_tok.len()..], false);
        let braces = is_word(before) || is_word(after);
        let closing = if mark == "{{" { "}}".to_string() } else { mark.clone() };
        let left = if braces { format!("{{{mark}}}") } else { mark.clone() };
        let right = if braces { format!("{{{closing}}}") } else { closing };
        let mut next: Vec<char> = chars[..start].to_vec();
        next.extend(left.chars());
        next.extend_from_slice(&chars[start + open_len..close_at]);
        next.extend(right.chars());
        next.extend_from_slice(&chars[close_at + close_tok.len()..]);
        chars = next;
    }
    chars.into_iter().filter(|&c| c != OPEN && c != CLOSE).collect()
}

/// 前（`backward`）或后一个实际可见的字符（跳过其他占位标记）。
fn visible(chars: &[char], backward: bool) -> Option<char> {
    let mut inside = false;
    let iter: Box<dyn Iterator<Item = &char>> = if backward { Box::new(chars.iter().rev()) } else { Box::new(chars.iter()) };
    for &c in iter {
        if c == OPEN || c == CLOSE {
            inside = !inside;
            continue;
        }
        if !inside {
            return Some(c);
        }
    }
    None
}

/// 转义会被 Jira 当作标记的字符。格式符号只在可能构成格式时转义（例如日期中的“-”不转义）。
fn escape_text(text: &str, in_table: bool) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    for (i, &c) in chars.iter().enumerate() {
        let prev_space = i == 0 || chars[i - 1].is_whitespace();
        let next_space = i + 1 == chars.len() || chars[i + 1].is_whitespace();
        if "\\{}[]".contains(c) || (c == '|' && in_table) || (c == '!' && !next_space) || ("*_+-^~?".contains(c) && prev_space != next_space) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// 段落中以列表、标题、引用、分隔线写法开头的行需要转义，否则会被当作对应的块。
fn escape_line_starts(text: &str) -> String {
    text.split('\n')
        .map(|line| {
            let t = line;
            let list = t.starts_with(['*', '#', '-']) && {
                let marks = t.trim_start_matches(['*', '#', '-']);
                marks.starts_with(char::is_whitespace) && t.chars().take_while(|c| matches!(c, '*' | '#' | '-')).collect::<std::collections::HashSet<_>>().len() == 1
            };
            let heading = t.len() > 3 && (t.starts_with('h') && t.as_bytes().get(1).is_some_and(|b| (b'1'..=b'6').contains(b)) && t[2..].starts_with(". ") || t.starts_with("bq. "));
            if list || heading || t.starts_with("----") { format!("\\{t}") } else { t.to_string() }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::html::from_html;

    fn wiki(html: &str) -> String {
        to_wiki(&from_html(html))
    }

    #[test]
    fn formats_and_braces() {
        assert_eq!(wiki("<p>a <b>粗</b> b</p>"), "a *粗* b");
        // 紧挨文字时用花括号
        assert_eq!(wiki("<p>前<b>粗</b>后</p>"), "前{*}粗{*}后");
        assert_eq!(wiki("<p>x <code>a{b}</code></p>"), "x {{a\\{b\\}}}");
    }

    #[test]
    fn blocks() {
        assert_eq!(wiki("<h2>标题</h2><ul><li>一<ul><li>二</li></ul></li></ul><ol><li>甲</li></ol>"), "h2. 标题\n\n* 一\n** 二\n\n# 甲");
        assert_eq!(wiki("<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>"), "||a||b||\n|1|2|");
        assert_eq!(wiki(r#"<div class="code panel"><pre class="code-java">x</pre></div>"#), "{code:java}\nx\n{code}");
    }

    #[test]
    fn escapes() {
        assert_eq!(wiki("<p>2026-07-17 - 项目 [x]</p>"), "2026-07-17 - 项目 \\[x\\]");
        assert_eq!(wiki("<p>* 不是列表</p>"), "\\* 不是列表");
        assert_eq!(wiki(r#"<p><a href="https://example.com">https://example.com</a> <a href="https://a.com/x">文字</a></p>"#), "[https://example.com] [文字|https://a.com/x]");
        assert_eq!(wiki(r#"<p><a class="user-hover" rel="zhangsan">张三</a></p>"#), "[~zhangsan]");
    }
}
