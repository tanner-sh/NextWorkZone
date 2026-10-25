//! 尚未迁移的 Jira 和 Wiki 互通；工作台存储入口已迁入 Swift。
use std::sync::Arc;
use nextworkzone_core::{Error, Result};
use nextworkzone_workspace::{Doc, Workspace};
use serde::Serialize;
use crate::state::AppState;
pub const SYNCED_EVENT: &str = "workspace-synced";
async fn run<T: Send + 'static>(ws: &Arc<Workspace>, f: impl FnOnce(&Workspace) -> Result<T> + Send + 'static) -> Result<T> {
    let ws = ws.clone();
    tokio::task::spawn_blocking(move || f(&ws)).await.map_err(|e| Error::Other(e.to_string()))?
}

// ---------- 与 Wiki 互通 ----------

/// 读取 Wiki 页面（地址或页面 id）渲染后的内容，用于剪藏到知识库。
pub async fn ws_wiki_page(state: &AppState, page: String) -> Result<nextworkzone_confluence::PageView> {
    let id = nextworkzone_core::config::parse_page_id(&page).ok_or_else(|| Error::Other("无法识别的页面地址".into()))?;
    state.confluence()?.page_view(&id).await
}

/// 图片附件文件名：图片 id 加上扩展名。
pub fn asset_filename(id: &str, mime: &str) -> String {
    let ext = match mime {
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/svg+xml" => "svg",
        _ => "png",
    };
    format!("{id}.{ext}")
}

/// 发布结果。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Published {
    url: String,
    /// 更新已发布的页面（而不是新建）。
    updated: bool,
    doc: Option<Doc>,
}

/// 发布到 Wiki 的页面地址，带上发布后的版本，用于下次发布时判断页面是否被别人改过。
fn published_url(confluence: &nextworkzone_confluence::ConfluenceClient, page_id: &str, version: u64) -> String {
    format!("{}&pageVersion={version}", confluence.page_url(page_id))
}

/// 发布地址中的 (页面 id, 版本)。
fn parse_published(url: &str) -> Option<(String, u64)> {
    let id = nextworkzone_core::config::parse_page_id(url)?;
    let version = url.split("pageVersion=").nth(1)?.split(['&', '#']).next()?.parse().ok()?;
    Some((id, version))
}

/// 把知识库页面发布到 Wiki，正文引用的图片作为附件上传。
///
/// `mode`：`create` 在 `parent` 页面下新建；`update` 更新上次发布的页面，页面在那之后被别人改过时报冲突；
/// `overwrite` 确认覆盖别人的修改后更新。发布后在文档上记下页面地址和版本。
pub async fn ws_publish_to_wiki(
    state: &AppState,
    doc_id: Option<String>,
    mode: Option<String>,
    parent: String,
    title: String,
    storage: String,
    assets: Vec<String>,
) -> Result<Published> {
    let confluence = state.confluence()?;
    let mode = mode.unwrap_or_else(|| "create".into());
    // 正文里图片附件的文件名占位为 ws-asset:<id>，按图片类型换成真实文件名
    let mut storage = storage;
    let mut files = Vec::new();
    for id in assets {
        let lookup = id.clone();
        if let Some((mime, data)) = run(&state.workspace, move |ws| ws.asset(&lookup)).await? {
            let filename = asset_filename(&id, &mime);
            storage = storage.replace(&format!("ws-asset:{id}"), &filename);
            files.push((filename, mime, data));
        }
    }
    let (page_id, version, updated) = if mode == "create" {
        let parent_id = nextworkzone_core::config::parse_page_id(&parent).ok_or_else(|| Error::Other("无法识别的上级页面地址".into()))?;
        let id = confluence.create_page(&parent_id, title.trim(), &storage).await?;
        (id, 1, false)
    } else {
        let id = doc_id.clone().ok_or_else(|| Error::Other("缺少知识库页面".into()))?;
        let doc = run(&state.workspace, move |ws| ws.doc(&id)).await?.ok_or_else(|| Error::Other("知识库页面不存在".into()))?;
        let (page_id, published_version) = doc
            .published_url
            .as_deref()
            .and_then(parse_published)
            .ok_or_else(|| Error::Other("这篇知识库页面还没有发布过".into()))?;
        let base = if mode == "overwrite" { confluence.page(&page_id).await?.version } else { published_version };
        let message = "从 NextWorkZone 知识库更新";
        let version = confluence.save_page(&page_id, title.trim(), &storage, base, false, message).await?;
        (page_id, version, true)
    };
    let existing = if updated { confluence.attachment_names(&page_id).await.unwrap_or_default() } else { Vec::new() };
    for (filename, mime, data) in files.into_iter().filter(|(name, ..)| !existing.contains(name)) {
        confluence.attach(&page_id, &filename, &mime, data).await?;
    }
    let url = published_url(&confluence, &page_id, version);
    let doc = match doc_id {
        Some(id) => {
            let u = url.clone();
            Some(run(&state.workspace, move |ws| ws.set_published(&id, &u)).await?)
        }
        None => None,
    };
    Ok(Published { url: confluence.page_url(&page_id), updated, doc })
}
