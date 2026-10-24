//! 本机问题库：后台同步、本机搜索、相似问题，以及问题的查看记录。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nextworkzone_core::{Error, Result};
use nextworkzone_jira::index::{IndexQuery, IndexScope, IndexStats, IssueHit, IssueIndex, SyncProgress, sync};
use nextworkzone_jira::{parse_time, similar_jql};
use serde::Serialize;
use tokio::sync::Notify;

use crate::state::AppState;

/// 问题库有变化（同步进度、同步完成）时发给前端的事件。
pub const INDEX_EVENT: &str = "jira-index-changed";
const SYNC_INTERVAL: Duration = Duration::from_secs(10 * 60);
/// 启动后稍等片刻再同步，不和界面首屏的请求抢网络。
const STARTUP_DELAY: Duration = Duration::from_secs(15);
const SIMILAR_LIMIT: u32 = 10;

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncState {
    running: bool,
    progress: Option<SyncProgress>,
    error: Option<String>,
}

static SYNC_STATE: Mutex<SyncState> = Mutex::new(SyncState { running: false, progress: None, error: None });
/// 唤醒后台同步（设置修改、手动同步、重建）。
static WAKE: Notify = Notify::const_new();

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexStatus {
    enabled: bool,
    #[serde(flatten)]
    stats: IndexStats,
    #[serde(flatten)]
    sync: SyncState,
}

/// 数据库操作放到阻塞线程中执行。
pub(crate) async fn blocking<T: Send + 'static>(index: &Arc<IssueIndex>, f: impl FnOnce(&IssueIndex) -> Result<T> + Send + 'static) -> Result<T> {
    let index = index.clone();
    tokio::task::spawn_blocking(move || f(&index)).await.map_err(|e| Error::Other(e.to_string()))?
}

pub fn wake() {
    WAKE.notify_one();
}

pub async fn jira_index_status(state: &AppState) -> Result<IndexStatus> {
    let stats = blocking(&state.issue_index, |i| i.stats()).await?;
    Ok(IndexStatus { enabled: state.config().jira_tools.index_enabled, stats, sync: SYNC_STATE.lock().unwrap().clone() })
}

/// 立即开始一次增量同步（在后台进行）。
pub async fn jira_index_sync() {
    wake();
}

/// 清空问题库并重新同步。
pub async fn jira_index_rebuild(state: &AppState) -> Result<IndexStatus> {
    blocking(&state.issue_index, |i| i.clear()).await?;
    wake();
    jira_index_status(state).await
}

pub async fn jira_index_search(state: &AppState, query: IndexQuery) -> Result<Vec<IssueHit>> {
    let me = if query.mine { state.jira_username().await? } else { String::new() };
    blocking(&state.issue_index, move |i| i.search(&query, &me)).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SimilarIssues {
    /// 对应的 Jira 查询，用于在列表中查看更多。
    jql: Option<String>,
    /// `local`：来自本机问题库；`jira`：本机没有该项目的数据，直接查询 Jira。
    source: &'static str,
    issues: Vec<IssueHit>,
}

/// 相似问题：优先用本机问题库（同时考虑描述，并附带最后几条评论），没有该项目的数据时查询 Jira。
pub async fn jira_similar_issues(state: &AppState, key: String, summary: String, resolved_only: bool) -> Result<SimilarIssues> {
    let jql = similar_jql(&key, &summary, resolved_only);
    if state.config().jira_tools.index_enabled {
        let (k, s) = (key.clone(), summary.clone());
        if let Some(issues) = blocking(&state.issue_index, move |i| i.similar(&k, &s, resolved_only, SIMILAR_LIMIT)).await? {
            return Ok(SimilarIssues { jql, source: "local", issues });
        }
    }
    let issues = match &jql {
        Some(q) => state.jira()?.similar_hits(q, SIMILAR_LIMIT).await?.1,
        None => Vec::new(),
    };
    Ok(SimilarIssues { jql, source: "jira", issues })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Viewed {
    /// 问题键 → 上次在本应用中查看的时间（毫秒）。
    viewed: HashMap<String, i64>,
    /// 开始记录的时间：没有查看记录的问题，以此之后的更新算作新变化。
    baseline: i64,
}

pub async fn jira_viewed(state: &AppState, keys: Vec<String>) -> Result<Viewed> {
    let (viewed, baseline) = blocking(&state.issue_index, move |i| i.viewed(&keys)).await?;
    Ok(Viewed { viewed, baseline })
}

/// 记录查看了问题，返回上一次的查看时间。`updated` 为问题当前的更新时间：
/// 查看时间不早于它，避免本机与服务器的时钟差让刚看过的问题仍显示为有新变化。
pub async fn jira_mark_viewed(state: &AppState, key: String, updated: Option<String>) -> Result<Option<i64>> {
    let now = chrono::Utc::now().timestamp_millis();
    let at = updated.as_deref().and_then(parse_time).map_or(now, |t| now.max(t.timestamp_millis()));
    blocking(&state.issue_index, move |i| i.mark_viewed(&key, at)).await
}

/// 后台定期增量同步问题库。
pub async fn sync_loop(state: Arc<AppState>) {
    tokio::time::sleep(STARTUP_DELAY).await;
    loop {
        sync_once(&state).await;
        let _ = tokio::time::timeout(SYNC_INTERVAL, WAKE.notified()).await;
    }
}

async fn sync_once(state: &AppState) {
    let config = state.config().jira_tools;
    let Ok(client) = state.jira() else { return };
    if !config.index_enabled {
        return;
    }
    *SYNC_STATE.lock().unwrap() = SyncState { running: true, progress: None, error: None };
    state.emit(INDEX_EVENT, ());
    let scope = IndexScope { jql: config.index_jql, days: config.index_days };
    let result = sync(&client, &state.issue_index, &scope, |p| {
        SYNC_STATE.lock().unwrap().progress = Some(p);
        state.emit(INDEX_EVENT, ());
    })
    .await;
    *SYNC_STATE.lock().unwrap() = SyncState { running: false, progress: None, error: result.err().map(|e| e.to_string()) };
    state.emit(INDEX_EVENT, ());
}
