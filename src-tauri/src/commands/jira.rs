use std::path::{Path, PathBuf};

use nextworkzone_core::{Result, Service};
use nextworkzone_jira::{
    Attachment, Comment, CommentLevel, CommentVisibility, parse_comment_levels, CreateProject, FieldInfo, FieldMeta, Filter, HistoryEntry, IssueDetail, IssueRef, IssueSummary,
    JiraClient, LinkType, Priority, SearchResult, Transition, UserRef, Watchers, Worklog, WorklogInput,
};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_opener::OpenerExt;

use crate::state::AppState;

fn search_cache_key(jql: &str, fields: &[String]) -> String {
    if fields.is_empty() { format!("jira:search:{jql}") } else { format!("jira:search:{jql}|{}", fields.join(",")) }
}

/// 上一次同一 JQL 的搜索结果，用于界面秒开。
#[tauri::command]
pub fn jira_cached_search(state: State<'_, AppState>, jql: String, fields: Option<Vec<String>>) -> Option<SearchResult> {
    state.cache.get(&search_cache_key(&jql, &fields.unwrap_or_default()))
}

/// `fields` 为列表中额外显示的字段。
#[tauri::command]
pub async fn jira_search(
    state: State<'_, AppState>,
    jql: String,
    start_at: u32,
    max_results: u32,
    fields: Option<Vec<String>>,
) -> Result<SearchResult> {
    let fields = fields.unwrap_or_default();
    let result = state.jira()?.search_with_fields(&jql, start_at, max_results, &fields).await?;
    if start_at == 0 {
        state.cache.put(&search_cache_key(&jql, &fields), &result);
    }
    Ok(result)
}

/// 某个时间段内自己登记的工作日志，每个问题一项。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorklogSum {
    key: String,
    summary: String,
    seconds: u64,
}

#[tauri::command]
pub async fn jira_my_worklogs(state: State<'_, AppState>, from: String, to: String) -> Result<Vec<WorklogSum>> {
    let me = state.jira_username().await?;
    let logs = state.jira()?.my_worklogs(&me, &from, &to).await?;
    Ok(logs
        .into_iter()
        .map(|(issue, logs)| WorklogSum { key: issue.key, summary: issue.summary, seconds: logs.iter().map(|w| w.time_spent_seconds).sum() })
        .collect())
}

const FIELDS_CACHE: &str = "jira:fields";

/// 可在列表中显示的字段。`refresh` 为假时有缓存就直接返回（界面先显示，再刷新）。
#[tauri::command]
pub async fn jira_fields(state: State<'_, AppState>, refresh: bool) -> Result<Vec<FieldInfo>> {
    fields(&state, refresh).await
}

pub async fn fields(state: &AppState, refresh: bool) -> Result<Vec<FieldInfo>> {
    if !refresh && let Some(cached) = state.cache.get::<Vec<FieldInfo>>(FIELDS_CACHE) {
        return Ok(cached);
    }
    let list = state.jira()?.list_fields().await?;
    state.cache.put(FIELDS_CACHE, &list);
    Ok(list)
}

/// 问题详情，并标出哪些评论是自己写的。
async fn load_issue(state: &AppState, jira: &JiraClient, key: &str) -> Result<IssueDetail> {
    let (issue, me) = tokio::join!(jira.issue(key), state.jira_username());
    let mut issue = issue?;
    let me = me.unwrap_or_default();
    issue.comments.iter_mut().for_each(|c| c.mark_mine(&me));
    Ok(issue)
}

async fn mine(state: &AppState, mut comment: Comment) -> Comment {
    comment.mark_mine(&state.jira_username().await.unwrap_or_default());
    comment
}

#[tauri::command]
pub async fn jira_issue(state: State<'_, AppState>, key: String) -> Result<IssueDetail> {
    load_issue(&state, &state.jira()?, &key).await
}

/// 当前 Jira 用户名。
#[tauri::command]
pub async fn jira_me(state: State<'_, AppState>) -> Result<String> {
    state.jira_username().await
}

#[tauri::command]
pub async fn jira_transitions(state: State<'_, AppState>, key: String) -> Result<Vec<Transition>> {
    state.jira()?.transitions(&key).await
}

/// 执行流转；填写了评论时在流转成功后追加评论。返回刷新后的问题详情。
#[tauri::command]
pub async fn jira_transition(
    state: State<'_, AppState>,
    key: String,
    transition_id: String,
    fields: Value,
    comment: Option<String>,
    visibility: Option<CommentVisibility>,
) -> Result<IssueDetail> {
    let jira = state.jira()?;
    jira.transition(&key, &transition_id, fields).await?;
    if let Some(body) = comment.as_deref().map(str::trim).filter(|c| !c.is_empty()) {
        jira.add_comment(&key, body, visibility.as_ref()).await?;
    }
    load_issue(&state, &jira, &key).await
}

#[tauri::command]
pub async fn jira_add_comment(
    state: State<'_, AppState>,
    key: String,
    body: String,
    visibility: Option<CommentVisibility>,
) -> Result<Comment> {
    let comment = state.jira()?.add_comment(&key, &body, visibility.as_ref()).await?;
    Ok(mine(&state, comment).await)
}

#[tauri::command]
pub async fn jira_update_comment(
    state: State<'_, AppState>,
    key: String,
    id: String,
    body: String,
    visibility: Option<CommentVisibility>,
) -> Result<Comment> {
    let comment = state.jira()?.update_comment(&key, &id, &body, visibility.as_ref()).await?;
    Ok(mine(&state, comment).await)
}

/// 评论可选的可见范围（来自网页“添加评论”表单，需要网页登录）。按项目缓存。
/// 没有网页会话时返回空列表，界面上不显示可见范围选项。
#[tauri::command]
pub async fn jira_comment_levels(state: State<'_, AppState>, key: String) -> Result<Vec<CommentLevel>> {
    let project = key.rsplit_once('-').map_or(key.as_str(), |(p, _)| p);
    let cache_key = format!("jira:comment-levels:{project}");
    if let Some(cached) = state.cache.get::<Vec<CommentLevel>>(&cache_key) {
        return Ok(cached);
    }
    // 网页表单按问题的数字 id 打开
    let issue_id = state.jira()?.get_path(&format!("/rest/api/2/issue/{key}?fields=summary")).await?["id"].as_str().unwrap_or_default().to_string();
    let url = state.resolve_url(Service::Jira, &format!("/secure/AddComment!default.jspa?id={issue_id}"))?;
    let html = match state.fetch_web(Service::Jira, &url).await {
        Ok((bytes, _)) => String::from_utf8_lossy(&bytes).into_owned(),
        Err(nextworkzone_core::Error::SessionRequired(_)) => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let levels = parse_comment_levels(&html);
    // 解析不到时不缓存（可能是会话失效后返回了别的页面）
    if !levels.is_empty() {
        state.cache.put(&cache_key, &levels);
    }
    Ok(levels)
}

#[tauri::command]
pub async fn jira_delete_comment(state: State<'_, AppState>, key: String, id: String) -> Result<()> {
    state.jira()?.delete_comment(&key, &id).await
}

/// 分配问题；`assignee` 为空时取消分配。返回刷新后的问题详情。
#[tauri::command]
pub async fn jira_assign(state: State<'_, AppState>, key: String, assignee: Option<String>) -> Result<IssueDetail> {
    let jira = state.jira()?;
    jira.assign(&key, assignee.as_deref()).await?;
    load_issue(&state, &jira, &key).await
}

#[tauri::command]
pub async fn jira_watchers(state: State<'_, AppState>, key: String) -> Result<Watchers> {
    state.jira()?.watchers(&key).await
}

#[tauri::command]
pub async fn jira_set_watching(state: State<'_, AppState>, key: String, watching: bool) -> Result<Watchers> {
    let jira = state.jira()?;
    jira.set_watching(&key, &state.jira_username().await?, watching).await?;
    jira.watchers(&key).await
}

const PRIORITIES_CACHE: &str = "jira:priorities";

#[tauri::command]
pub async fn jira_priorities(state: State<'_, AppState>) -> Result<Vec<Priority>> {
    // 优先级几乎不变，有缓存时直接使用
    if let Some(cached) = state.cache.get::<Vec<Priority>>(PRIORITIES_CACHE) {
        return Ok(cached);
    }
    let list = state.jira()?.priorities().await?;
    state.cache.put(PRIORITIES_CACHE, &list);
    Ok(list)
}

/// 修改优先级。返回刷新后的问题详情。
#[tauri::command]
pub async fn jira_set_priority(state: State<'_, AppState>, key: String, priority_id: String) -> Result<IssueDetail> {
    let jira = state.jira()?;
    jira.update_issue(&key, serde_json::json!({ "priority": { "id": priority_id } })).await?;
    load_issue(&state, &jira, &key).await
}

#[tauri::command]
pub async fn jira_favourite_filters(state: State<'_, AppState>) -> Result<Vec<Filter>> {
    state.jira()?.favourite_filters().await
}

#[tauri::command]
pub async fn jira_upload_attachments(
    state: State<'_, AppState>,
    key: String,
    paths: Vec<String>,
) -> Result<Vec<Attachment>> {
    let jira = state.jira()?;
    let mut uploaded = Vec::new();
    for path in paths {
        uploaded.extend(jira.upload_attachment(&key, Path::new(&path)).await?);
    }
    Ok(uploaded)
}

#[tauri::command]
pub async fn jira_edit_fields(state: State<'_, AppState>, key: String) -> Result<Vec<FieldMeta>> {
    state.jira()?.edit_fields(&key).await
}

/// 保存编辑；`fields` 只包含有变化的字段。返回刷新后的问题详情。
#[tauri::command]
pub async fn jira_update_issue(
    state: State<'_, AppState>,
    key: String,
    fields: Value,
) -> Result<IssueDetail> {
    let jira = state.jira()?;
    jira.update_issue(&key, fields).await?;
    load_issue(&state, &jira, &key).await
}

const CREATE_PROJECTS_CACHE: &str = "jira:createProjects";

/// 上一次获取的可创建问题的项目，用于创建对话框秒开。
#[tauri::command]
pub fn jira_cached_create_projects(state: State<'_, AppState>) -> Option<Vec<CreateProject>> {
    state.cache.get(CREATE_PROJECTS_CACHE)
}

#[tauri::command]
pub async fn jira_create_projects(state: State<'_, AppState>) -> Result<Vec<CreateProject>> {
    let projects = state.jira()?.create_projects().await?;
    state.cache.put(CREATE_PROJECTS_CACHE, &projects);
    Ok(projects)
}

#[tauri::command]
pub async fn jira_create_fields(
    state: State<'_, AppState>,
    project_key: String,
    issue_type_id: String,
) -> Result<Vec<FieldMeta>> {
    state.jira()?.create_fields(&project_key, &issue_type_id).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreatedIssue {
    key: String,
    /// 问题已创建但附件上传失败时的错误信息。
    attachment_error: Option<String>,
}

/// 创建问题，随后上传选择的附件。
/// 附件上传失败不算创建失败（问题已经存在），单独返回错误，避免用户重复创建。
#[tauri::command]
pub async fn jira_create_issue(
    state: State<'_, AppState>,
    fields: Value,
    attachments: Vec<String>,
) -> Result<CreatedIssue> {
    let jira = state.jira()?;
    let key = jira.create_issue(fields).await?;
    let mut attachment_error = None;
    for path in &attachments {
        if let Err(e) = jira.upload_attachment(&key, Path::new(path)).await {
            attachment_error = Some(format!("{}：{e}", file_name(path)));
            break;
        }
    }
    Ok(CreatedIssue { key, attachment_error })
}

fn file_name(path: &str) -> String {
    Path::new(path).file_name().map_or_else(|| path.to_string(), |n| n.to_string_lossy().into_owned())
}

#[tauri::command]
pub async fn jira_find_users(
    state: State<'_, AppState>,
    query: String,
    field: String,
    issue_key: Option<String>,
    project_key: Option<String>,
) -> Result<Vec<UserRef>> {
    state.jira()?.find_users(&query, &field, issue_key.as_deref(), project_key.as_deref()).await
}

#[tauri::command]
pub async fn jira_suggest_labels(state: State<'_, AppState>, query: String) -> Result<Vec<String>> {
    state.jira()?.suggest_labels(&query).await
}

#[tauri::command]
pub async fn jira_search_epics(
    state: State<'_, AppState>,
    query: String,
    project_key: String,
) -> Result<Vec<IssueRef>> {
    state.jira()?.search_epics(&query, &project_key).await
}

#[tauri::command]
pub async fn jira_pick_issues(
    state: State<'_, AppState>,
    query: String,
    project_key: Option<String>,
    standard_only: bool,
) -> Result<Vec<IssueSummary>> {
    state.jira()?.pick_issues(&query, project_key.as_deref(), standard_only).await
}

#[tauri::command]
pub async fn jira_link_types(state: State<'_, AppState>) -> Result<Vec<LinkType>> {
    state.jira()?.link_types().await
}

#[tauri::command]
pub async fn jira_add_link(
    state: State<'_, AppState>,
    key: String,
    type_id: String,
    other: String,
    outward: bool,
) -> Result<IssueDetail> {
    let jira = state.jira()?;
    jira.add_link(&key, &type_id, &other, outward).await?;
    load_issue(&state, &jira, &key).await
}

#[tauri::command]
pub async fn jira_delete_link(
    state: State<'_, AppState>,
    key: String,
    link_id: String,
) -> Result<IssueDetail> {
    let jira = state.jira()?;
    jira.delete_link(&link_id).await?;
    load_issue(&state, &jira, &key).await
}

#[tauri::command]
pub async fn jira_worklogs(state: State<'_, AppState>, key: String) -> Result<Vec<Worklog>> {
    state.jira()?.worklogs(&key).await
}

/// 新增（`id` 为空）或修改工作日志，返回最新的工作日志列表。
#[tauri::command]
pub async fn jira_save_worklog(
    state: State<'_, AppState>,
    key: String,
    id: Option<String>,
    input: WorklogInput,
) -> Result<Vec<Worklog>> {
    let jira = state.jira()?;
    match id {
        Some(id) => jira.update_worklog(&key, &id, &input).await?,
        None => jira.add_worklog(&key, &input).await?,
    }
    jira.worklogs(&key).await
}

#[tauri::command]
pub async fn jira_delete_worklog(
    state: State<'_, AppState>,
    key: String,
    id: String,
) -> Result<Vec<Worklog>> {
    let jira = state.jira()?;
    jira.delete_worklog(&key, &id).await?;
    jira.worklogs(&key).await
}

#[tauri::command]
pub async fn jira_history(state: State<'_, AppState>, key: String) -> Result<Vec<HistoryEntry>> {
    state.jira()?.history(&key).await
}

#[tauri::command]
pub async fn jira_render_wiki(
    state: State<'_, AppState>,
    markup: String,
    issue_key: Option<String>,
) -> Result<String> {
    state.jira()?.render_wiki(&markup, issue_key.as_deref()).await
}

/// 保存编辑器中粘贴的图片（`data` 为 base64 编码的图片），返回本地路径。
/// 图片在保存问题、发送评论时才作为附件上传，取消编辑不会在 Jira 留下多余附件。
#[tauri::command]
pub fn jira_save_pasted_image(app: AppHandle, data: String, filename: String) -> Result<String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data.as_bytes())
        .map_err(|_| nextworkzone_core::Error::Other("图片数据格式不正确".into()))?;
    let name: String = filename
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
        .collect();
    let dir = app.path().app_cache_dir().map_err(std::io::Error::other)?.join("pasted");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(if name.is_empty() { "image.png".into() } else { name });
    std::fs::write(&path, bytes)?;
    Ok(path.to_string_lossy().into_owned())
}

/// 下载附件到“下载”目录并用系统默认程序打开，返回保存路径。
#[tauri::command]
pub async fn jira_open_attachment(
    app: AppHandle,
    state: State<'_, AppState>,
    url: String,
    filename: String,
    service: Option<Service>,
) -> Result<String> {
    // 附件也可能来自 Wiki 页面
    let service = service.unwrap_or(Service::Jira);
    let url = state.resolve_url(service, &url)?;
    let (bytes, _) = state.fetch_web(service, &url).await?;
    let dir = app.path().download_dir().map_err(std::io::Error::other)?;
    let path = unique_path(&dir, &filename);
    std::fs::write(&path, bytes)?;
    app.opener().open_path(path.to_string_lossy(), None::<&str>).map_err(std::io::Error::other)?;
    Ok(path.to_string_lossy().into_owned())
}

/// 在应用内预览附件：表格、Word 文档、文本文件转换为可显示的内容。
#[tauri::command]
pub async fn jira_preview_attachment(state: State<'_, AppState>, url: String, filename: String, mime: String, service: Option<Service>) -> Result<nextworkzone_preview::Preview> {
    let service = service.unwrap_or(Service::Jira);
    let url = state.resolve_url(service, &url)?;
    let (bytes, _) = state.fetch_web(service, &url).await?;
    tauri::async_runtime::spawn_blocking(move || nextworkzone_preview::preview(&filename, &mime, &bytes))
        .await
        .map_err(|e| nextworkzone_core::Error::Other(e.to_string()))
}

/// 文件已存在时依次尝试 `name (1).ext`、`name (2).ext`……
fn unique_path(dir: &Path, filename: &str) -> PathBuf {
    let name = Path::new(filename).file_name().map(|n| n.to_string_lossy().into_owned());
    let name = name.filter(|n| !n.is_empty()).unwrap_or_else(|| "attachment".into());
    let candidate = dir.join(&name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => (stem.to_string(), format!(".{ext}")),
        _ => (name.clone(), String::new()),
    };
    (1..)
        .map(|i| dir.join(format!("{stem} ({i}){ext}")))
        .find(|p| !p.exists())
        .expect("无限序列中总能找到未占用的文件名")
}
