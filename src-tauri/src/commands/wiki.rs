//! Wiki：浏览、搜索、历史版本、评论、编辑，本机 Wiki 库的后台同步，以及与 Jira、待办的关联。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nextworkzone_confluence::browse::{CqlHit, CqlQuery, PageDetail, PageNode, Space, VersionInfo, WikiAttachment, WikiComment, WikiTemplate};
use nextworkzone_confluence::edit::{self, Editable};
use nextworkzone_confluence::index::{WikiHit, WikiIndex, WikiIndexStats, WikiQuery, WikiScope, WikiSyncProgress, sync};
use nextworkzone_confluence::storage::normalize_entities;
use nextworkzone_confluence::{Ancestor, diff};
use nextworkzone_core::config::WikiToolsConfig;
use nextworkzone_core::{Error, Result};
use nextworkzone_workspace::AssignedWikiTask;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::sync::Notify;

use crate::commands::workspace::SYNCED_EVENT;
use crate::state::AppState;

/// 本机 Wiki 库有变化（同步进度、同步完成）时发给前端的事件。
pub const INDEX_EVENT: &str = "wiki-index-changed";
const SYNC_INTERVAL: Duration = Duration::from_secs(10 * 60);
/// 启动后稍等片刻再同步，不和界面首屏、问题库的首次同步抢网络。
const STARTUP_DELAY: Duration = Duration::from_secs(40);
const SPACES_CACHE: &str = "wiki:spaces";

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncState {
    running: bool,
    progress: Option<WikiSyncProgress>,
    error: Option<String>,
}

static SYNC_STATE: Mutex<SyncState> = Mutex::new(SyncState { running: false, progress: None, error: None });
static WAKE: Notify = Notify::const_new();

async fn blocking<T: Send + 'static>(index: &Arc<WikiIndex>, f: impl FnOnce(&WikiIndex) -> Result<T> + Send + 'static) -> Result<T> {
    let index = index.clone();
    tauri::async_runtime::spawn_blocking(move || f(&index)).await.map_err(|e| Error::Other(e.to_string()))?
}

pub fn wake() {
    WAKE.notify_one();
}

/// 页面 id，或能解析出页面的地址（短链接、`/display/空间/标题` 等）。
async fn page_id(state: &AppState, page: &str) -> Result<String> {
    if !page.is_empty() && page.chars().all(|c| c.is_ascii_digit()) {
        return Ok(page.to_string());
    }
    state.confluence()?.resolve_page(page).await?.ok_or_else(|| Error::Other(format!("无法识别的 Wiki 页面地址：{page}")))
}

// ---------- 浏览 ----------

/// 上次获取的空间列表（先显示，再刷新）。
#[tauri::command]
pub async fn wiki_cached_spaces(state: State<'_, AppState>) -> Result<Option<Vec<SpaceOut>>> {
    Ok(state.cache.get(SPACES_CACHE))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceOut {
    key: String,
    name: String,
    homepage_id: Option<String>,
    description: String,
}

impl From<Space> for SpaceOut {
    fn from(s: Space) -> Self {
        Self { key: s.key, name: s.name, homepage_id: s.homepage_id, description: s.description }
    }
}

#[tauri::command]
pub async fn wiki_spaces(state: State<'_, AppState>) -> Result<Vec<SpaceOut>> {
    let spaces: Vec<SpaceOut> = state.confluence()?.spaces().await?.into_iter().map(SpaceOut::from).collect();
    state.cache.put(SPACES_CACHE, &spaces);
    Ok(spaces)
}

#[tauri::command]
pub async fn wiki_space_roots(state: State<'_, AppState>, space: String) -> Result<Vec<PageNode>> {
    state.confluence()?.space_roots(&space).await
}

#[tauri::command]
pub async fn wiki_children(state: State<'_, AppState>, page: String) -> Result<Vec<PageNode>> {
    state.confluence()?.children(&page).await
}

/// 打开页面：解析地址、读取内容，并记入最近查看。
#[tauri::command]
pub async fn wiki_page(state: State<'_, AppState>, page: String) -> Result<PageDetail> {
    let id = page_id(&state, &page).await?;
    let detail = state.confluence()?.page_detail(&id).await?;
    let (id, title, space) = (detail.id.clone(), detail.title.clone(), detail.space_name.clone());
    let _ = blocking(&state.wiki_index, move |i| i.mark_viewed(&id, &title, &space)).await;
    Ok(detail)
}

/// 把地址解析为页面 id；不是 Wiki 页面地址时返回 `None`。
#[tauri::command]
pub async fn wiki_resolve(state: State<'_, AppState>, input: String) -> Result<Option<String>> {
    state.confluence()?.resolve_page(&input).await
}

#[tauri::command]
pub async fn wiki_attachments(state: State<'_, AppState>, page: String) -> Result<Vec<WikiAttachment>> {
    state.confluence()?.attachments(&page).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentPage {
    id: String,
    title: String,
    space: String,
    /// 毫秒
    at: i64,
    /// `app`：在本应用中查看；`web`：在网页上查看
    source: &'static str,
}

/// 最近查看的页面：本应用中查看的，加上 Confluence 记录的网页查看。
#[tauri::command]
pub async fn wiki_recent(state: State<'_, AppState>, limit: Option<u32>) -> Result<Vec<RecentPage>> {
    let limit = limit.unwrap_or(30);
    let local = blocking(&state.wiki_index, move |i| i.recent(limit)).await?;
    let web = match state.confluence() {
        Ok(c) => c.recently_viewed(limit).await.unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    let mut list: Vec<RecentPage> = local
        .into_iter()
        .map(|v| RecentPage { id: v.id, title: v.title, space: v.space_key, at: v.at, source: "app" })
        .collect();
    for (id, title, space, at) in web {
        match list.iter_mut().find(|p| p.id == id) {
            Some(existing) if at > existing.at => existing.at = at,
            Some(_) => {}
            None => list.push(RecentPage { id, title, space, at, source: "web" }),
        }
    }
    list.sort_by_key(|p| std::cmp::Reverse(p.at));
    list.truncate(limit as usize);
    Ok(list)
}

// ---------- 历史版本 ----------

#[tauri::command]
pub async fn wiki_versions(state: State<'_, AppState>, page: String) -> Result<Vec<VersionInfo>> {
    state.confluence()?.versions(&page).await
}

/// 两个版本之间的差异（统一 diff 格式，按段落比较纯文本）。
#[tauri::command]
pub async fn wiki_diff(state: State<'_, AppState>, page: String, from: u64, to: u64) -> Result<String> {
    let c = state.confluence()?;
    let (old, new) = tokio::try_join!(c.version_storage(&page, from), c.version_storage(&page, to))?;
    Ok(diff::unified(&old, &new))
}

/// 某个历史版本渲染后的内容。
#[tauri::command]
pub async fn wiki_version_html(state: State<'_, AppState>, page: String, version: u64) -> Result<String> {
    state.confluence()?.version_html(&page, version).await
}

/// 页面当前的标题和版本（判断剪藏、发布过的页面是否有更新）。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageVersion {
    title: String,
    version: u64,
    by: String,
    when: String,
}

#[tauri::command]
pub async fn wiki_page_version(state: State<'_, AppState>, page: String) -> Result<PageVersion> {
    let (title, version, by, when) = state.confluence()?.page_version(&page).await?;
    Ok(PageVersion { title, version, by, when })
}

// ---------- 评论与任务 ----------

#[tauri::command]
pub async fn wiki_comments(state: State<'_, AppState>, page: String) -> Result<Vec<WikiComment>> {
    state.confluence()?.comments(&page).await
}

/// 发表评论（纯文本，每行一段）；`parent` 不为空时是回复。
#[tauri::command]
pub async fn wiki_add_comment(state: State<'_, AppState>, page: String, parent: Option<String>, text: String) -> Result<Vec<WikiComment>> {
    if text.trim().is_empty() {
        return Err(Error::Other("评论内容为空".into()));
    }
    let c = state.confluence()?;
    c.add_comment(&page, parent.as_deref(), &edit::plain_to_storage(&text)).await?;
    c.comments(&page).await
}

/// 勾选或取消页面中的任务，同时更新本机记录和对应的待办。
#[tauri::command]
pub async fn wiki_set_task(app: AppHandle, state: State<'_, AppState>, page: String, task: String, done: bool) -> Result<()> {
    state.confluence()?.set_task_status(&page, &task, done).await?;
    let (p, t) = (page.clone(), task.clone());
    blocking(&state.wiki_index, move |i| i.set_task_done(&p, &t, done)).await?;
    let id = nextworkzone_workspace::wiki_todo_id(&page, &task);
    let ws = state.workspace.clone();
    let changed = tauri::async_runtime::spawn_blocking(move || match ws.todo(&id)? {
        Some(todo) if todo.done != done && !todo.deleted => ws.set_todo_done(&id, done).map(|_| true),
        _ => Ok(false),
    })
    .await
    .map_err(|e| Error::Other(e.to_string()))??;
    if changed {
        let _ = app.emit(SYNCED_EVENT, ());
    }
    Ok(())
}

/// 用户的显示名（userkey → 名字）。
#[tauri::command]
pub async fn wiki_users(state: State<'_, AppState>, keys: Vec<String>) -> Result<HashMap<String, String>> {
    Ok(state.confluence()?.user_names(&keys).await?.into_iter().collect())
}

// ---------- 搜索 ----------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiSearchResult {
    /// `local`：本机 Wiki 库；`server`：Confluence 搜索
    source: &'static str,
    total: u32,
    hits: Vec<WikiHit>,
}

fn from_cql(h: CqlHit) -> WikiHit {
    WikiHit {
        id: h.id,
        kind: h.kind,
        title: h.title,
        space_key: h.space_key,
        space_name: h.space_name,
        ancestors: h.ancestors,
        author_name: h.author_name,
        modified: h.modified,
        snippet: h.snippet,
    }
}

/// 搜索页面：本机 Wiki 库有数据时在本机搜索（快、支持两个字的中文词），`server` 为真或本机没有数据时用 Confluence 搜索。
#[tauri::command]
pub async fn wiki_search(state: State<'_, AppState>, query: WikiQuery, server: bool, start: Option<u32>) -> Result<WikiSearchResult> {
    let local = state.config().wiki_tools.index_enabled && !server && !blocking(&state.wiki_index, |i| i.is_empty()).await?;
    if local {
        let me = state.wiki_me().await.map(|(key, _)| key).unwrap_or_default();
        let hits = blocking(&state.wiki_index, move |i| i.search(&query, &me)).await?;
        return Ok(WikiSearchResult { source: "local", total: hits.len() as u32, hits });
    }
    let me = state.wiki_me().await.map(|(_, name)| name).unwrap_or_default();
    let cql = CqlQuery {
        text: query.text,
        space: query.space,
        mine: query.mine,
        days: query.days,
        kind: query.kind,
        label: String::new(),
        start: start.unwrap_or(0),
        limit: query.limit,
    };
    let (total, hits) = state.confluence()?.cql_search(&cql, &me).await?;
    Ok(WikiSearchResult { source: "server", total, hits: hits.into_iter().map(from_cql).collect() })
}

/// 引用了某个 Jira 问题的 Wiki 页面：Jira 上的远程链接、本机 Wiki 库中的引用；本机没有数据时用 Confluence 搜索。
#[tauri::command]
pub async fn wiki_issue_pages(state: State<'_, AppState>, key: String) -> Result<Vec<WikiHit>> {
    let confluence = state.confluence()?;
    let linked = match state.jira() {
        Ok(jira) => jira.wiki_page_links(&key).await.unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    let use_index = state.config().wiki_tools.index_enabled && !blocking(&state.wiki_index, |i| i.is_empty()).await?;
    let k = key.clone();
    let mut pages: Vec<WikiHit> = if use_index {
        blocking(&state.wiki_index, move |i| i.pages_with_issue(&k, 30)).await?
    } else {
        let q = CqlQuery { text: key.clone(), limit: 20, ..Default::default() };
        confluence.cql_search(&q, "").await.map(|(_, h)| h.into_iter().map(from_cql).collect()).unwrap_or_default()
    };
    let missing: Vec<String> = linked.into_iter().filter(|id| !pages.iter().any(|p| &p.id == id)).collect();
    let ids = missing.clone();
    let known = blocking(&state.wiki_index, move |i| i.titles(&ids)).await.unwrap_or_default();
    for id in missing {
        let found = known.iter().find(|(k, _, _)| *k == id);
        let (title, space) = match found {
            Some((_, title, space)) => (title.clone(), space.clone()),
            None => match confluence.page_version(&id).await {
                Ok((title, ..)) => (title, String::new()),
                // 没有权限或已删除的页面不显示
                Err(_) => continue,
            },
        };
        pages.push(WikiHit {
            id,
            kind: "page".into(),
            title,
            space_key: String::new(),
            space_name: space,
            ancestors: Vec::<Ancestor>::new(),
            author_name: String::new(),
            modified: String::new(),
            snippet: String::new(),
        });
    }
    Ok(pages)
}

// ---------- 编辑 ----------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditSession {
    /// 新建页面时为空。
    page_id: Option<String>,
    title: String,
    space_key: String,
    /// 开始编辑时的版本，保存时据此检查是否被别人改过。
    version: u64,
    #[serde(flatten)]
    editable: Editable,
}

/// 开始编辑页面。
#[tauri::command]
pub async fn wiki_edit(state: State<'_, AppState>, page: String) -> Result<EditSession> {
    let p = state.confluence()?.page(&page).await?;
    Ok(EditSession { page_id: Some(p.id), title: p.title, space_key: p.space_key, version: p.version, editable: edit::to_editable(&p.storage)? })
}

/// 开始编写新页面：内容来自 Confluence 模板，或本机模板转换成的 storage，都没有时为空白页。
#[tauri::command]
pub async fn wiki_new_page(state: State<'_, AppState>, space: String, template: Option<String>, storage: Option<String>) -> Result<EditSession> {
    let body = match (template, storage) {
        (Some(id), _) => edit::strip_template_variables(&state.confluence()?.template_storage(&id).await?),
        (None, Some(s)) => s,
        (None, None) => "<p></p>".into(),
    };
    Ok(EditSession { page_id: None, title: String::new(), space_key: space, version: 0, editable: edit::to_editable(&body)? })
}

#[tauri::command]
pub async fn wiki_templates(state: State<'_, AppState>, space: Option<String>) -> Result<Vec<WikiTemplate>> {
    state.confluence()?.templates(space.as_deref()).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SavePreview {
    storage: String,
    /// 与当前内容的差异；新建页面时为空。
    diff: String,
    changed: bool,
}

/// 保存前预览：还原 storage、检查格式，并给出与页面当前内容的差异。
#[tauri::command]
pub async fn wiki_preview_save(state: State<'_, AppState>, page: Option<String>, xhtml: String, fragments: Vec<String>) -> Result<SavePreview> {
    let storage = edit::from_editable(&xhtml, &fragments)?;
    let Some(page) = page else {
        return Ok(SavePreview { diff: String::new(), changed: true, storage });
    };
    let current = state.confluence()?.page(&page).await?;
    let diff = diff::unified(&current.storage, &storage);
    // 实体写法不同（`&rarr;` 与 `→`）不算修改；只改了格式（加粗等）时文字差异为空，但仍算修改
    let changed = normalize_entities(&current.storage) != normalize_entities(&storage);
    Ok(SavePreview { changed, diff, storage })
}

/// 保存编辑。页面在开始编辑之后被别人改过时报冲突，不覆盖。返回新版本号。
#[tauri::command]
pub async fn wiki_save(
    state: State<'_, AppState>,
    page: String,
    title: String,
    xhtml: String,
    fragments: Vec<String>,
    base_version: u64,
    minor_edit: bool,
    message: String,
) -> Result<u64> {
    let title = title.trim();
    if title.is_empty() {
        return Err(Error::Other("页面标题不能为空".into()));
    }
    let storage = edit::from_editable(&xhtml, &fragments)?;
    let version = state.confluence()?.save_page(&page, title, &storage, base_version, minor_edit, message.trim()).await?;
    wake();
    Ok(version)
}

/// 新建页面，返回页面 id。`parent` 为空时建在空间顶层。
#[tauri::command]
pub async fn wiki_create(state: State<'_, AppState>, space: String, parent: Option<String>, title: String, xhtml: String, fragments: Vec<String>) -> Result<String> {
    let title = title.trim();
    if title.is_empty() {
        return Err(Error::Other("页面标题不能为空".into()));
    }
    let storage = edit::from_editable(&xhtml, &fragments)?;
    let id = state.confluence()?.create_in(&space, parent.as_deref(), title, &storage).await?;
    wake();
    Ok(id)
}

// ---------- 本机 Wiki 库 ----------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexStatus {
    enabled: bool,
    #[serde(flatten)]
    stats: WikiIndexStats,
    #[serde(flatten)]
    sync: SyncState,
}

#[tauri::command]
pub async fn wiki_index_status(state: State<'_, AppState>) -> Result<IndexStatus> {
    let stats = blocking(&state.wiki_index, |i| i.stats()).await?;
    Ok(IndexStatus { enabled: state.config().wiki_tools.index_enabled, stats, sync: SYNC_STATE.lock().unwrap().clone() })
}

#[tauri::command]
pub fn wiki_index_sync() {
    wake();
}

#[tauri::command]
pub async fn wiki_index_rebuild(state: State<'_, AppState>) -> Result<IndexStatus> {
    blocking(&state.wiki_index, |i| i.clear()).await?;
    wake();
    wiki_index_status(state).await
}

#[tauri::command]
pub fn wiki_tools_settings(state: State<'_, AppState>) -> WikiToolsConfig {
    state.config().wiki_tools
}

#[tauri::command]
pub async fn wiki_save_tools_settings(app: AppHandle, state: State<'_, AppState>, settings: WikiToolsConfig) -> Result<WikiToolsConfig> {
    let mut config = state.config();
    let clean = |list: Vec<String>| -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for s in list.into_iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
            if !out.contains(&s) {
                out.push(s);
            }
        }
        out
    };
    let settings = WikiToolsConfig { index_spaces: clean(settings.index_spaces), muted_pages: clean(settings.muted_pages), ..settings };
    config.wiki_tools = settings.clone();
    state.update_config(config)?;
    if settings.index_enabled {
        wake();
    }
    // 关闭任务同步时，已自动加入的待办保留，但不再更新
    if !settings.task_todos {
        let _ = app.emit(INDEX_EVENT, ());
    }
    Ok(settings)
}

/// 后台定期增量同步本机 Wiki 库，同步后更新“分配给我的页面任务”待办。
pub async fn sync_loop(app: AppHandle) {
    tokio::time::sleep(STARTUP_DELAY).await;
    loop {
        sync_once(&app).await;
        let _ = tokio::time::timeout(SYNC_INTERVAL, WAKE.notified()).await;
    }
}

async fn sync_once(app: &AppHandle) {
    let state = app.state::<AppState>();
    let config = state.config().wiki_tools;
    let Ok(client) = state.confluence() else { return };
    if !config.index_enabled {
        return;
    }
    *SYNC_STATE.lock().unwrap() = SyncState { running: true, progress: None, error: None };
    let _ = app.emit(INDEX_EVENT, ());
    let scope = WikiScope { spaces: config.index_spaces.clone() };
    let result = sync(&client, &state.wiki_index, &scope, |p| {
        SYNC_STATE.lock().unwrap().progress = Some(p);
        let _ = app.emit(INDEX_EVENT, ());
    })
    .await;
    let error = result.err().map(|e| e.to_string());
    if error.is_none() && config.task_todos
        && let Err(e) = refresh_task_todos(app).await {
            eprintln!("更新 Wiki 任务待办失败：{e}");
        }
    *SYNC_STATE.lock().unwrap() = SyncState { running: false, progress: None, error };
    let _ = app.emit(INDEX_EVENT, ());
}

/// 让“页面中分配给我的未完成任务”与待办保持一致。
async fn refresh_task_todos(app: &AppHandle) -> Result<()> {
    let state = app.state::<AppState>();
    let (me, _) = state.wiki_me().await?;
    let tasks = blocking(&state.wiki_index, move |i| i.assigned_tasks(&me)).await?;
    let items: Vec<AssignedWikiTask> = tasks
        .into_iter()
        .map(|t| AssignedWikiTask { page_id: t.page_id, page_title: t.page_title, task_id: t.task.task_id, text: t.task.text, due: t.task.due })
        .collect();
    let ws = state.workspace.clone();
    let report = tauri::async_runtime::spawn_blocking(move || ws.sync_wiki_todos(&items)).await.map_err(|e| Error::Other(e.to_string()))??;
    if report.added + report.completed + report.reopened > 0 {
        let _ = app.emit(SYNCED_EVENT, ());
    }
    Ok(())
}
