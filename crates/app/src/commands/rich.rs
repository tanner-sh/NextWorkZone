//! 富文本格式转换（见 nextworkzone-richdoc）：原生界面用文档模型显示和编辑，保存时转为各系统的格式。

use nextworkzone_core::Result;
use nextworkzone_richdoc::{self as rich, Doc};
use serde::Serialize;

pub async fn rich_from_html(html: String) -> Result<Doc> {
    Ok(rich::from_html(&html))
}

pub async fn rich_from_markdown(markdown: String) -> Result<Doc> {
    Ok(rich::from_markdown(&markdown))
}

pub async fn rich_to_markdown(doc: Doc) -> Result<String> {
    Ok(rich::to_markdown(&doc))
}

pub async fn rich_to_wiki(doc: Doc) -> Result<String> {
    Ok(rich::to_wiki(&doc))
}

pub async fn rich_to_xhtml(doc: Doc) -> Result<String> {
    Ok(rich::to_xhtml(&doc))
}

#[derive(Serialize)]
pub struct EditLoad {
    doc: Doc,
    segments: Vec<rich::Segment>,
}

/// Wiki 编辑用的 HTML → 文档模型，以及保存时保留未修改内容所需的片段。
pub async fn rich_edit_load(html: String) -> Result<EditLoad> {
    let (doc, segments) = rich::edit_load(&html);
    Ok(EditLoad { doc, segments })
}

/// 编辑后的文档 → 编辑格式的 XHTML：没有修改的片段原样写回。
pub async fn rich_edit_xhtml(segments: Vec<rich::Segment>, baseline: Doc, doc: Doc) -> Result<String> {
    Ok(rich::edit_xhtml(&segments, &baseline, &doc))
}

/// 系统渲染的 HTML → Markdown（沉淀、剪藏到知识库）。
pub async fn rich_html_to_markdown(html: String, base_url: String) -> Result<String> {
    Ok(rich::html_to_markdown(&html, &base_url))
}

#[derive(Serialize)]
pub struct Storage {
    storage: String,
    assets: Vec<String>,
}

/// Markdown → Confluence storage（发布笔记到 Wiki）。
pub async fn rich_markdown_to_storage(markdown: String) -> Result<Storage> {
    let (storage, assets) = rich::markdown_to_storage(&markdown);
    Ok(Storage { storage, assets })
}
