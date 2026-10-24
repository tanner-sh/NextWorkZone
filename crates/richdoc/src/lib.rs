//! 富文本的统一文档模型（[`Doc`]），以及与 HTML、Markdown、Jira wiki 标记、Confluence XHTML 之间的转换。
//!
//! 原生界面用文档模型显示和编辑富文本：系统渲染出的 HTML 先转为文档模型再显示；
//! 编辑后的文档模型再转为各系统的格式保存（Jira 字段为 wiki 标记，Wiki 页面为 XHTML，笔记为 Markdown）。

mod edit;
mod html;
mod markdown;
mod model;
mod wiki;
mod xhtml;

pub use edit::{Segment, edit_load, edit_xhtml};
pub use html::from_html;
pub use markdown::{from_markdown, to_markdown};
pub use model::{Block, Cell, Doc, Inline, Item, Opaque, Row, Task, marks};
pub use wiki::to_wiki;
pub use xhtml::{markdown_to_storage, to_xhtml};

/// 系统渲染的 HTML → Markdown（沉淀、剪藏到知识库）。
/// 相对地址补全为 `base_url` 下的完整地址；缩略图换成原图。
pub fn html_to_markdown(html: &str, base_url: &str) -> String {
    let mut doc = from_html(html);
    absolutize(&mut doc.blocks, base_url);
    to_markdown(&doc)
}

/// 把相对地址补全为 `base_url` 下的完整地址；图片改用原图。
pub fn absolutize(blocks: &mut [Block], base_url: &str) {
    let fix = |url: &mut String| {
        if url.starts_with('/') && !url.starts_with("//") {
            *url = format!("{base_url}{url}");
        }
    };
    for b in blocks {
        match b {
            Block::Para { inl } | Block::Heading { inl, .. } => absolutize_inlines(inl, &fix),
            Block::List { items, .. } => items.iter_mut().for_each(|i| absolutize(&mut i.blocks, base_url)),
            Block::Quote { blocks } | Block::Panel { blocks, .. } => absolutize(blocks, base_url),
            Block::Table { rows } => rows.iter_mut().flat_map(|r| r.cells.iter_mut()).for_each(|c| absolutize(&mut c.blocks, base_url)),
            _ => {}
        }
    }
}

fn absolutize_inlines(inl: &mut [Inline], fix: &impl Fn(&mut String)) {
    for i in inl {
        match i {
            Inline::Text { link: Some(link), .. } => fix(link),
            Inline::Image { src, full, .. } => {
                if let Some(original) = full.take() {
                    *src = original;
                }
                fix(src);
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_to_markdown_absolutizes() {
        let md = html_to_markdown(r#"<p><a href="/browse/AB-1">AB-1</a> <a href="/secure/attachment/1/1_x.png"><img src="/secure/thumbnail/1/_thumb_1.png"></a></p>"#, "https://jira.example.com");
        assert_eq!(md, "[AB-1](https://jira.example.com/browse/AB-1) ![](https://jira.example.com/secure/attachment/1/1_x.png)\n");
    }
}
