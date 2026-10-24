//! Markdown ⇄ 文档模型。工作空间的笔记、知识库以 Markdown 保存。
//!
//! 约定（与 Tauri 版编辑器相同）：本地图片写作 `ws://asset/<id>`，指向其他文档的链接写作 `ws://doc/<id>`，
//! 任务列表为 `- [ ]` / `- [x]`，表格为 GFM 表格。

use pulldown_cmark::{Options, Parser, html};

use crate::html::from_html;
use crate::model::{Block, Doc, Inline, Item, marks};

pub fn from_markdown(markdown: &str) -> Doc {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    let parser = Parser::new_ext(markdown, options);
    let mut out = String::new();
    html::push_html(&mut out, parser);
    from_html(&out)
}

pub fn to_markdown(doc: &Doc) -> String {
    let mut out = String::new();
    write_blocks(&doc.blocks, "", &mut out);
    let text = out.trim_end().to_string();
    if text.is_empty() { text } else { text + "\n" }
}

fn write_blocks(blocks: &[Block], indent: &str, out: &mut String) {
    for (i, b) in blocks.iter().enumerate() {
        if i > 0 {
            // 块之间空一行（缩进内的空行不带缩进，避免尾随空格）
            out.push('\n');
        }
        write_block(b, indent, out);
    }
}

/// 给每行加上前缀（第一行可以不同，例如列表标记）。
fn prefixed(text: &str, first: &str, rest: &str, out: &mut String) {
    for (i, line) in text.lines().enumerate() {
        let p = if i == 0 { first } else { rest };
        if line.is_empty() {
            out.push_str(p.trim_end());
        } else {
            out.push_str(p);
            out.push_str(line);
        }
        out.push('\n');
    }
    if text.is_empty() {
        out.push_str(first.trim_end());
        out.push('\n');
    }
}

fn write_block(b: &Block, indent: &str, out: &mut String) {
    match b {
        Block::Para { inl } => prefixed(&escape_line_start(&inlines(inl)), indent, indent, out),
        Block::Heading { level, inl, .. } => {
            out.push_str(indent);
            out.push_str(&"#".repeat((*level).clamp(1, 6) as usize));
            out.push(' ');
            out.push_str(&inlines(inl).replace('\n', " "));
            out.push('\n');
        }
        Block::List { ordered, start, items } => write_list(*ordered, *start, items, indent, out),
        Block::Quote { blocks } => {
            let mut inner = String::new();
            write_blocks(blocks, "", &mut inner);
            prefixed(inner.trim_end(), &format!("{indent}> "), &format!("{indent}> "), out);
        }
        Block::Panel { title, blocks, .. } => {
            let mut inner = String::new();
            if !title.is_empty() {
                inner.push_str(&format!("**{}**\n\n", escape(title)));
            }
            write_blocks(blocks, "", &mut inner);
            prefixed(inner.trim_end(), &format!("{indent}> "), &format!("{indent}> "), out);
        }
        Block::Code { lang, text } => {
            // 内容中有 ``` 时用更长的围栏
            let mut fence = "```".to_string();
            while text.contains(&fence) {
                fence.push('`');
            }
            out.push_str(&format!("{indent}{fence}{lang}\n"));
            for line in text.lines() {
                out.push_str(indent);
                out.push_str(line);
                out.push('\n');
            }
            out.push_str(&format!("{indent}{fence}\n"));
        }
        Block::Table { rows } => {
            let width = rows.iter().map(|r| r.cells.iter().map(|c| c.colspan as usize).sum::<usize>()).max().unwrap_or(0);
            if width == 0 {
                return;
            }
            let row_text = |cells: &[crate::model::Cell]| -> String {
                let mut parts: Vec<String> = cells
                    .iter()
                    .flat_map(|c| {
                        let mut text = String::new();
                        for (i, b) in c.blocks.iter().enumerate() {
                            if i > 0 {
                                text.push_str("<br>");
                            }
                            text.push_str(&cell_text(b));
                        }
                        std::iter::once(text.replace('|', "\\|")).chain(std::iter::repeat_n(String::new(), c.colspan as usize - 1))
                    })
                    .collect();
                parts.resize(width, String::new());
                format!("{indent}| {} |\n", parts.join(" | "))
            };
            out.push_str(&row_text(&rows[0].cells));
            out.push_str(&format!("{indent}|{}\n", " --- |".repeat(width)));
            for row in &rows[1..] {
                out.push_str(&row_text(&row.cells));
            }
        }
        Block::Rule => {
            out.push_str(indent);
            out.push_str("---\n");
        }
        Block::Opaque(o) => prefixed(&escape(&o.label), indent, indent, out),
        Block::Marker { .. } => {}
    }
}

fn cell_text(b: &Block) -> String {
    match b {
        Block::Para { inl } | Block::Heading { inl, .. } => inlines(inl).replace('\n', "<br>"),
        Block::List { items, .. } => items.iter().map(|i| i.blocks.iter().map(cell_text).collect::<Vec<_>>().join(" ")).collect::<Vec<_>>().join("<br>"),
        Block::Code { text, .. } => format!("`{}`", text.replace('\n', " ")),
        other => {
            let mut s = String::new();
            write_block(other, "", &mut s);
            s.trim().replace('\n', "<br>")
        }
    }
}

fn write_list(ordered: bool, start: u32, items: &[Item], indent: &str, out: &mut String) {
    let first = if start == 0 { 1 } else { start };
    for (i, item) in items.iter().enumerate() {
        let mut marker = if ordered { format!("{}. ", first as usize + i) } else { "- ".to_string() };
        if let Some(task) = &item.task {
            marker.push_str(if task.done { "[x] " } else { "[ ] " });
        }
        let child_indent = format!("{indent}{}", " ".repeat(if ordered { marker.split(' ').next().unwrap().len() + 1 } else { 2 }));
        let mut blocks = item.blocks.iter().peekable();
        // 第一个段落跟在标记后面
        match blocks.peek() {
            Some(Block::Para { inl }) => {
                prefixed(&escape_line_start(&inlines(inl)), &format!("{indent}{marker}"), &child_indent, out);
                blocks.next();
            }
            _ => {
                out.push_str(indent);
                out.push_str(marker.trim_end());
                out.push('\n');
            }
        }
        // 其余块（嵌套的列表、后续段落）缩进放在下面；嵌套列表紧跟，段落前空一行
        for b in blocks {
            if !matches!(b, Block::List { .. }) {
                out.push('\n');
            }
            write_block(b, &child_indent, out);
        }
    }
}

/// 段落开头会被当作其他块的写法需要转义（列表、标题、引用、编号）。
fn escape_line_start(text: &str) -> String {
    text.lines()
        .map(|line| {
            let t = line.trim_start();
            let needs = t.starts_with('#') && t.trim_start_matches('#').starts_with(' ')
                || t.starts_with("> ")
                || (t.starts_with("- ") || t.starts_with("+ ") || t.starts_with("* "))
                || t.split_once(". ").is_some_and(|(n, _)| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
            if needs && let Some(pos) = line.find(|c: char| !c.is_whitespace()) {
                let (head, rest) = line.split_at(pos);
                // 编号列表：转义点号
                if let Some((n, tail)) = rest.split_once(". ")
                    && n.chars().all(|c| c.is_ascii_digit())
                {
                    return format!("{head}{n}\\. {tail}");
                }
                return format!("{head}\\{rest}");
            }
            line.to_string()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// 转义行内的 Markdown 符号。
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if matches!(c, '\\' | '*' | '_' | '`' | '[' | ']' | '<' | '~') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

pub(crate) fn inlines(inl: &[Inline]) -> String {
    let mut out = String::new();
    for i in inl {
        match i {
            Inline::Text { s, m, link, .. } => {
                let mut text = if m & marks::CODE != 0 {
                    // 内容中有反引号时用更长的反引号包住
                    let ticks = if s.contains('`') { "``" } else { "`" };
                    let pad = if s.starts_with('`') || s.ends_with('`') { " " } else { "" };
                    format!("{ticks}{pad}{s}{pad}{ticks}")
                } else {
                    escape(s)
                };
                if m & marks::CODE == 0 && !text.trim().is_empty() {
                    // 格式标记不能紧挨空白：把首尾空白放到标记外面
                    let lead = text.len() - text.trim_start().len();
                    let trail = text.len() - text.trim_end().len();
                    let (head, rest) = text.split_at(lead);
                    let (core, tail) = rest.split_at(rest.len() - trail);
                    if !core.is_empty() {
                        let mut core = core.to_string();
                        if m & marks::STRIKE != 0 {
                            core = format!("~~{core}~~");
                        }
                        if m & marks::ITALIC != 0 {
                            core = format!("*{core}*");
                        }
                        if m & marks::BOLD != 0 {
                            core = format!("**{core}**");
                        }
                        if m & marks::UNDERLINE != 0 {
                            core = format!("<u>{core}</u>");
                        }
                        if m & marks::SUP != 0 {
                            core = format!("<sup>{core}</sup>");
                        }
                        if m & marks::SUB != 0 {
                            core = format!("<sub>{core}</sub>");
                        }
                        if m & marks::MARK != 0 {
                            core = format!("<mark>{core}</mark>");
                        }
                        text = format!("{head}{core}{tail}");
                    }
                }
                match link {
                    Some(href) => out.push_str(&format!("[{text}]({})", link_target(href))),
                    None => out.push_str(&text),
                }
            }
            Inline::Image { src, alt, .. } => out.push_str(&format!("![{}]({})", escape(alt), link_target(src))),
            Inline::Br => out.push_str("\\\n"),
            Inline::Issue { key } => out.push_str(key),
            Inline::Status { text, .. } => out.push_str(&format!("`{text}`")),
            Inline::Mention { name, .. } => out.push_str(&format!("@{}", escape(name))),
            Inline::Attachment { file } => out.push_str(&escape(file)),
            Inline::Opaque(o) => out.push_str(&escape(&o.label.replace('\n', " "))),
            Inline::Marker { .. } => {}
        }
    }
    // 连续的同类格式合并（**a****b** → **ab**）
    out.replace("****", "").replace("~~~~", "")
}

/// 地址中有空格或括号时用尖括号包住。
fn link_target(url: &str) -> String {
    if url.contains([' ', '(', ')', '<', '>']) { format!("<{}>", url.replace('<', "%3C").replace('>', "%3E")) } else { url.to_string() }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(md: &str) -> String {
        to_markdown(&from_markdown(md))
    }

    #[test]
    fn round_trips_common_markdown() {
        let md = "# 标题\n\n一段 **粗体** 和 *斜体*、`代码`，[链接](https://example.com)。\n\n- 一\n  - 二\n- 三\n\n1. 甲\n2. 乙\n\n- [ ] 未完成\n- [x] 已完成\n\n> 引用\n\n```rust\nfn main() {}\n```\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n![图](ws://asset/abc)\n\n---\n";
        assert_eq!(round_trip(md), md);
    }

    #[test]
    fn escapes_markdown_symbols() {
        let doc = Doc { blocks: vec![Block::para(vec![Inline::text("1. 不是列表 *星号*")])] };
        let md = to_markdown(&doc);
        assert_eq!(md, "1\\. 不是列表 \\*星号\\*\n");
        assert_eq!(from_markdown(&md), doc);
    }
}
