//! 工作空间（待办、笔记、知识库）的命令，以及后台同步。

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nextworkzone_core::{Error, Result};
use nextworkzone_workspace::{
    AssetMeta, AssignedIssue, Backlink, Doc, DocInput, DocSummary, JiraTodoSync, SearchHit, SyncReport, Todo, TodoInput,
    Workspace,
};
use serde::Serialize;

use crate::state::AppState;

/// 其他设备的修改合并进来后发给前端的事件，前端据此刷新列表。
pub const SYNCED_EVENT: &str = "workspace-synced";
const SYNC_INTERVAL: Duration = Duration::from_secs(60);

/// 最近一次同步的结果，供设置页显示。
static LAST_SYNC: Mutex<Option<std::result::Result<SyncReport, String>>> = Mutex::new(None);

/// 数据库操作放到阻塞线程中执行，不占用异步运行时。
async fn run<T: Send + 'static>(ws: &Arc<Workspace>, f: impl FnOnce(&Workspace) -> Result<T> + Send + 'static) -> Result<T> {
    let ws = ws.clone();
    tokio::task::spawn_blocking(move || f(&ws)).await.map_err(|e| Error::Other(e.to_string()))?
}

// ---------- 待办 ----------

pub async fn ws_todos(state: &AppState) -> Result<Vec<Todo>> {
    run(&state.workspace, |ws| ws.todos()).await
}

pub async fn ws_save_todo(state: &AppState, input: TodoInput) -> Result<Todo> {
    run(&state.workspace, move |ws| ws.save_todo(input)).await
}

/// 勾选待办。由 Wiki 页面任务自动创建的待办，同时勾选页面上的任务。
pub async fn ws_set_todo_done(state: &AppState, id: String, done: bool) -> Result<Todo> {
    let lookup = id.clone();
    let todo = run(&state.workspace, move |ws| ws.todo(&lookup)).await?;
    if let Some(todo) = todo.filter(|t| t.source.as_deref() == Some("wiki"))
        && let (Some(page), Some(task)) = (todo.ref_key.as_deref(), wiki_task_id(&todo.id)) {
            state.confluence()?.set_task_status(page, &task, done).await?;
            let (p, t) = (page.to_string(), task.clone());
            let index = state.wiki_index.clone();
            let _ = tokio::task::spawn_blocking(move || index.set_task_done(&p, &t, done)).await;
        }
    run(&state.workspace, move |ws| ws.set_todo_done(&id, done)).await
}

/// `wiki-<页面>-<任务>` 中的任务 id。
fn wiki_task_id(todo_id: &str) -> Option<String> {
    todo_id.strip_prefix("wiki-")?.rsplit_once('-').map(|(_, task)| task.to_string())
}

pub async fn ws_move_todo(state: &AppState, id: String, sort: f64) -> Result<()> {
    run(&state.workspace, move |ws| ws.move_todo(&id, sort)).await
}

pub async fn ws_delete_todo(state: &AppState, id: String) -> Result<()> {
    run(&state.workspace, move |ws| ws.delete_todo(&id)).await
}

/// 按“分配给我的未解决问题”更新自动创建的待办；未开启该功能时返回 `None`。
pub async fn ws_refresh_jira_todos(state: &AppState) -> Result<Option<JiraTodoSync>> {
    if !state.config().workspace.jira_todos {
        return Ok(None);
    }
    let result = state
        .jira()?
        .search("assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC", 0, 500)
        .await?;
    // 只拿到部分结果时不做“自动完成”，避免把没取到的问题误判为已解决
    if result.issues.len() < result.total as usize {
        return Err(Error::Other(format!("分配给我的问题有 {} 个，超过一次能获取的数量", result.total)));
    }
    let issues: Vec<AssignedIssue> = result
        .issues
        .into_iter()
        .map(|i| AssignedIssue { key: i.key, summary: i.summary, due: i.due_date })
        .collect();
    run(&state.workspace, move |ws| ws.sync_jira_todos(&issues)).await.map(Some)
}

// ---------- 文档 ----------

pub async fn ws_docs(state: &AppState, kind: String) -> Result<Vec<DocSummary>> {
    run(&state.workspace, move |ws| ws.docs(&kind)).await
}

pub async fn ws_full_docs(state: &AppState, kind: String) -> Result<Vec<Doc>> {
    run(&state.workspace, move |ws| ws.full_docs(&kind)).await
}

pub async fn ws_doc(state: &AppState, id: String) -> Result<Option<Doc>> {
    run(&state.workspace, move |ws| ws.doc(&id).map(|d| d.filter(|d| !d.deleted))).await
}

pub async fn ws_daily(state: &AppState, day: String) -> Result<Doc> {
    run(&state.workspace, move |ws| ws.daily(&day)).await
}

pub async fn ws_daily_days(state: &AppState) -> Result<Vec<String>> {
    run(&state.workspace, |ws| ws.daily_days()).await
}

pub async fn ws_save_doc(state: &AppState, input: DocInput) -> Result<Doc> {
    run(&state.workspace, move |ws| ws.save_doc(input)).await
}

pub async fn ws_move_doc(state: &AppState, id: String, parent_id: Option<String>, sort: f64) -> Result<Doc> {
    run(&state.workspace, move |ws| ws.move_doc(&id, parent_id.as_deref(), sort)).await
}

pub async fn ws_delete_doc(state: &AppState, id: String) -> Result<usize> {
    run(&state.workspace, move |ws| ws.delete_doc(&id)).await
}

#[derive(Serialize)]
pub struct TagCount {
    name: String,
    count: usize,
}

pub async fn ws_tags(state: &AppState) -> Result<Vec<TagCount>> {
    let tags = run(&state.workspace, |ws| ws.tags()).await?;
    Ok(tags.into_iter().map(|(name, count)| TagCount { name, count }).collect())
}

pub async fn ws_backlinks(state: &AppState, system: String, key: String) -> Result<Vec<Backlink>> {
    run(&state.workspace, move |ws| ws.backlinks(&system, &key)).await
}

pub async fn ws_search(state: &AppState, query: String) -> Result<Vec<SearchHit>> {
    run(&state.workspace, move |ws| ws.search(&query, 30)).await
}

/// 保存粘贴进笔记的图片（`data` 为 base64），返回图片信息；正文中以 `ws://asset/<id>` 引用。
pub async fn ws_save_asset(state: &AppState, data: String, mime: String) -> Result<AssetMeta> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data.as_bytes())
        .map_err(|_| Error::Other("图片数据格式不正确".into()))?;
    run(&state.workspace, move |ws| ws.save_asset(&mime, &bytes)).await
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

// ---------- 设置与同步 ----------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSettings {
    sync_dir: String,
    jira_todos: bool,
    device_id: String,
    last_sync: Option<SyncReport>,
    last_error: Option<String>,
    capture_shortcut: String,
    /// 快捷键注册失败的原因。
    capture_error: Option<String>,
}

fn settings(state: &AppState) -> WorkspaceSettings {
    let config = state.config().workspace;
    let (last_sync, last_error) = match LAST_SYNC.lock().unwrap().clone() {
        Some(Ok(report)) => (Some(report), None),
        Some(Err(e)) => (None, Some(e)),
        None => (None, None),
    };
    WorkspaceSettings {
        sync_dir: config.sync_dir,
        jira_todos: config.jira_todos,
        device_id: state.workspace.device_id().to_string(),
        last_sync,
        last_error,
        capture_shortcut: config.capture_shortcut,
        capture_error: state.host.shortcut_error(crate::host::Shortcut::Capture),
    }
}

/// 修改快速记录的快捷键：先注册新的，失败时恢复原来的并返回错误。
pub async fn ws_save_capture_shortcut(state: &AppState, shortcut: String) -> Result<WorkspaceSettings> {
    let shortcut = shortcut.trim().to_string();
    let mut config = state.config();
    state.host.set_shortcut(crate::host::Shortcut::Capture, &shortcut)?;
    config.workspace.capture_shortcut = shortcut;
    state.update_config(config)?;
    Ok(settings(state))
}

pub async fn ws_settings(state: &AppState) -> WorkspaceSettings {
    settings(state)
}

pub async fn ws_save_settings(
    state: &AppState,
    sync_dir: String,
    jira_todos: bool,
) -> Result<WorkspaceSettings> {
    let sync_dir = sync_dir.trim().to_string();
    if !sync_dir.is_empty() && !PathBuf::from(&sync_dir).is_dir() {
        return Err(Error::Other(format!("同步文件夹不存在：{sync_dir}")));
    }
    let mut config = state.config();
    let changed_dir = config.workspace.sync_dir != sync_dir;
    config.workspace.sync_dir = sync_dir;
    config.workspace.jira_todos = jira_todos;
    state.update_config(config)?;
    if changed_dir {
        *LAST_SYNC.lock().unwrap() = None;
        let _ = sync_now(state).await;
    }
    Ok(settings(state))
}

/// 立即同步；未设置同步文件夹时返回 `None`。
pub async fn ws_sync(state: &AppState) -> Result<Option<SyncReport>> {
    sync_now(state).await
}

async fn sync_now(state: &AppState) -> Result<Option<SyncReport>> {
    let dir = state.config().workspace.sync_dir;
    if dir.is_empty() {
        return Ok(None);
    }
    // 同步文件夹在 iCloud 等位置时，加上子目录，避免与其他文件混在一起
    let dir = PathBuf::from(dir).join("NextWorkZone").join("v2");
    let result = run(&state.workspace, move |ws| ws.sync(&dir)).await;
    *LAST_SYNC.lock().unwrap() = Some(result.as_ref().map(Clone::clone).map_err(ToString::to_string));
    let report = result?;
    if report.imported > 0 || report.conflicts > 0 {
        state.emit(SYNCED_EVENT, &report);
    }
    Ok(Some(report))
}

/// 后台定期同步。
pub async fn sync_loop(state: Arc<AppState>) {
    let mut interval = tokio::time::interval(SYNC_INTERVAL);
    loop {
        interval.tick().await;
        let _ = sync_now(&state).await;
    }
}
