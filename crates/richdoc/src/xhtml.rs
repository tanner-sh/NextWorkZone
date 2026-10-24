//! 文档模型 → Confluence 的 XHTML（storage 格式）。
//!
//! - 编辑页面（[`to_xhtml`]）：不可编辑的占位块、布局容器的起止写成 `<!--nwz:N-->`，
//!   保存时由 confluence 模块换回原文；新加的代码块、信息框、Jira 问题、状态写成对应的宏。
//! - 发布笔记（[`markdown_to_storage`]）：本地图片写成附件引用（文件名占位 `ws-asset:<id>`，上传时替换为真实文件名），
//!   工作空间内部链接在 Wiki 上无法打开，只保留文字。

use crate::markdown::from_markdown;
use crate::model::{Block, Doc, Inline, marks};

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Edit,
    Publish,
}

pub fn to_xhtml(doc: &Doc) -> String {
    let mut w = Writer { mode: Mode::Edit, out: String::new(), assets: Vec::new() };
    w.blocks(&doc.blocks);
    w.out
}

/// Markdown → storage，返回 storage 和引用到的本地图片 id。
pub fn markdown_to_storage(markdown: &str) -> (String, Vec<String>) {
    let doc = from_markdown(markdown);
    let mut w = Writer { mode: Mode::Publish, out: String::new(), assets: Vec::new() };
    w.blocks(&doc.blocks);
    let mut assets = Vec::new();
    for a in w.assets {
        if !assets.contains(&a) {
            assets.push(a);
        }
    }
    (w.out, assets)
}

/// 正文中引用的本地图片：`ws://asset/<id>`
const ASSET_PREFIX: &str = "ws://asset/";

pub(crate) fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

struct Writer {
    mode: Mode,
    out: String,
    assets: Vec<String>,
}

impl Writer {
    fn blocks(&mut self, blocks: &[Block]) {
        for b in blocks {
            self.block(b);
        }
    }

    fn block(&mut self, b: &Block) {
        match b {
            Block::Para { inl } => {
                self.out.push_str("<p>");
                self.inlines(inl);
                self.out.push_str("</p>");
            }
            Block::Heading { level, inl, .. } => {
                let l = level.clamp(&1, &6);
                self.out.push_str(&format!("<h{l}>"));
                self.inlines(inl);
                self.out.push_str(&format!("</h{l}>"));
            }
            Block::List { ordered, items, .. } => {
                let tag = if *ordered { "ol" } else { "ul" };
                self.out.push_str(&format!("<{tag}>"));
                for item in items {
                    self.out.push_str("<li>");
                    if let Some(task) = &item.task {
                        self.out.push_str(if task.done { "☑ " } else { "☐ " });
                    }
                    // 列表项中只有一个段落时不加 <p>
                    match item.blocks.as_slice() {
                        [Block::Para { inl }, rest @ ..] => {
                            self.inlines(inl);
                            self.blocks(rest);
                        }
                        blocks => self.blocks(blocks),
                    }
                    self.out.push_str("</li>");
                }
                self.out.push_str(&format!("</{tag}>"));
            }
            Block::Quote { blocks } => {
                self.out.push_str("<blockquote>");
                self.blocks(blocks);
                self.out.push_str("</blockquote>");
            }
            Block::Code { lang, text } => {
                self.out.push_str(r#"<ac:structured-macro ac:name="code">"#);
                if !lang.is_empty() {
                    self.out.push_str(&format!(r#"<ac:parameter ac:name="language">{}</ac:parameter>"#, escape(lang)));
                }
                self.out.push_str(&format!("<ac:plain-text-body><![CDATA[{}]]></ac:plain-text-body></ac:structured-macro>", text.replace("]]>", "]]]]><![CDATA[>")));
            }
            Block::Table { rows } => {
                self.out.push_str("<table><tbody>");
                for row in rows {
                    self.out.push_str("<tr>");
                    for cell in &row.cells {
                        let tag = if cell.head { "th" } else { "td" };
                        let mut attrs = String::new();
                        if cell.colspan > 1 {
                            attrs.push_str(&format!(r#" colspan="{}""#, cell.colspan));
                        }
                        if cell.rowspan > 1 {
                            attrs.push_str(&format!(r#" rowspan="{}""#, cell.rowspan));
                        }
                        self.out.push_str(&format!("<{tag}{attrs}>"));
                        self.blocks(&cell.blocks);
                        self.out.push_str(&format!("</{tag}>"));
                    }
                    self.out.push_str("</tr>");
                }
                self.out.push_str("</tbody></table>");
            }
            Block::Rule => self.out.push_str("<hr />"),
            Block::Panel { kind, title, blocks } => {
                let name = match kind.as_str() {
                    "info" | "note" | "warning" | "tip" | "panel" | "expand" => kind.as_str(),
                    _ => "panel",
                };
                self.out.push_str(&format!(r#"<ac:structured-macro ac:name="{name}">"#));
                if !title.is_empty() {
                    self.out.push_str(&format!(r#"<ac:parameter ac:name="title">{}</ac:parameter>"#, escape(title)));
                }
                self.out.push_str("<ac:rich-text-body>");
                self.blocks(blocks);
                self.out.push_str("</ac:rich-text-body></ac:structured-macro>");
            }
            Block::Opaque(o) => self.marker(o.n, &o.label),
            Block::Marker { n } => self.marker(*n, ""),
        }
    }

    fn marker(&mut self, n: usize, label: &str) {
        match self.mode {
            Mode::Edit => self.out.push_str(&format!("<!--nwz:{n}-->")),
            Mode::Publish => {
                if !label.is_empty() {
                    self.out.push_str(&format!("<p>{}</p>", escape(label)));
                }
            }
        }
    }

    fn inlines(&mut self, list: &[Inline]) {
        for i in list {
            match i {
                Inline::Text { s, m, link, color } => {
                    let mut text = escape(s);
                    let wraps: [(u16, &str); 8] = [
                        (marks::CODE, "code"),
                        (marks::SUB, "sub"),
                        (marks::SUP, "sup"),
                        (marks::STRIKE, "s"),
                        (marks::UNDERLINE, "u"),
                        (marks::ITALIC, "em"),
                        (marks::BOLD, "strong"),
                        (marks::MARK, "span"),
                    ];
                    for (bit, tag) in wraps {
                        if m & bit != 0 {
                            text = if bit == marks::MARK {
                                format!(r#"<span style="background-color: rgb(255,255,0);">{text}</span>"#)
                            } else {
                                format!("<{tag}>{text}</{tag}>")
                            };
                        }
                    }
                    if let Some(color) = color {
                        text = format!(r#"<span style="color: {};">{text}</span>"#, escape(color));
                    }
                    match link {
                        // 工作空间内部链接在 Wiki 上无法打开，只保留文字
                        Some(href) if !href.starts_with("ws://") => self.out.push_str(&format!(r#"<a href="{}">{text}</a>"#, escape(href))),
                        _ => self.out.push_str(&text),
                    }
                }
                Inline::Br => self.out.push_str("<br />"),
                Inline::Image { src, .. } => {
                    if let Some(id) = src.strip_prefix(ASSET_PREFIX) {
                        self.assets.push(id.to_string());
                        self.out.push_str(&format!(r#"<ac:image><ri:attachment ri:filename="ws-asset:{}" /></ac:image>"#, escape(id)));
                    } else if let Some(file) = src.strip_prefix("attachment:") {
                        self.out.push_str(&format!(r#"<ac:image><ri:attachment ri:filename="{}" /></ac:image>"#, escape(file)));
                    } else {
                        self.out.push_str(&format!(r#"<ac:image><ri:url ri:value="{}" /></ac:image>"#, escape(src)));
                    }
                }
                Inline::Issue { key } => self.out.push_str(&format!(
                    r#"<ac:structured-macro ac:name="jira"><ac:parameter ac:name="key">{}</ac:parameter></ac:structured-macro>"#,
                    escape(key)
                )),
                Inline::Status { text, color } => {
                    let colour = match color.as_str() {
                        "green" => "Green",
                        "red" => "Red",
                        "yellow" => "Yellow",
                        "blue" => "Blue",
                        _ => "Grey",
                    };
                    self.out.push_str(&format!(
                        r#"<ac:structured-macro ac:name="status"><ac:parameter ac:name="colour">{colour}</ac:parameter><ac:parameter ac:name="title">{}</ac:parameter></ac:structured-macro>"#,
                        escape(text)
                    ));
                }
                Inline::Mention { name, .. } => self.out.push_str(&escape(&format!("@{name}"))),
                Inline::Attachment { file } => self.out.push_str(&escape(file)),
                Inline::Opaque(o) => self.marker(o.n, &o.label),
                Inline::Marker { n } => self.marker(*n, ""),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::html::from_html;

    #[test]
    fn edit_round_trip_keeps_placeholders() {
        let html = r#"<div class="nwz-container" data-nwz-open="0" data-nwz-close="1"><p>文字 <strong>粗</strong> <span class="nwz-opaque" data-nwz="2">AB-1</span></p></div>"#;
        assert_eq!(to_xhtml(&from_html(html)), "<!--nwz:0--><p>文字 <strong>粗</strong> <!--nwz:2--></p><!--nwz:1-->");
    }

    #[test]
    fn markdown_to_storage_assets_and_code() {
        let (storage, assets) = markdown_to_storage("![](ws://asset/a1)\n\n```js\nx]]>y\n```\n\n[笔记](ws://doc/d1) [网站](https://example.com)\n\n- [x] 完成\n");
        assert_eq!(assets, vec!["a1".to_string()]);
        assert!(storage.contains(r#"<ri:attachment ri:filename="ws-asset:a1" />"#));
        assert!(storage.contains("<![CDATA[x]]]]><![CDATA[>y]]>"));
        assert!(storage.contains(r#"<p>笔记 <a href="https://example.com">网站</a></p>"#));
        assert!(storage.contains("<li>☑ 完成</li>"));
    }
}
