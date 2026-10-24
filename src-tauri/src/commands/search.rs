//! 统一搜索：一次搜遍工作空间（待办、笔记、知识库）、Jira 问题、Wiki 页面、GitLab 项目和合并请求、剪贴板历史。
//!
//! 分两步：`local` 只查本机数据（工作空间、本机问题库、本机 Wiki 库、剪贴板），不经过网络；
//! `remote` 查服务器（GitLab，以及本机库不可用时的 Jira、Wiki）。界面先显示本机结果，再补上服务器结果。

use nextworkzone_clipboard::{ClipItem, ListQuery};
use nextworkzone_confluence::SearchHit;
use nextworkzone_confluence::index::WikiQuery;
use nextworkzone_core::Result;
use nextworkzone_gitlab::{MergeRequest, Project};
use nextworkzone_jira::index::{IndexQuery, IssueHit};
use nextworkzone_workspace::SearchHit as WorkspaceHit;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager, State};

use crate::clipboard::Clip;
use crate::state::AppState;

/// 每类结果的默认条数（⌘K）；搜索页会传更大的值。
const LIMIT: usize = 8;
const MAX_LIMIT: usize = 100;

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SearchOptions {
    /// `local` / `remote`；为空时两步都做。
    phase: Option<String>,
    /// 每类结果的条数。
    limit: Option<usize>,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SearchResults {
    issues: Vec<IssueHit>,
    /// 问题来自 `local`（本机问题库）还是 `jira`（服务器搜索）；没有搜索时为空。
    issues_source: Option<&'static str>,
    projects: Vec<Project>,
    merge_requests: Vec<MergeRequest>,
    pages: Vec<SearchHit>,
    /// 本地的待办、笔记、知识库
    workspace: Vec<WorkspaceHit>,
    clips: Vec<ClipItem>,
    /// 某个系统搜索失败时的提示（未配置的系统直接跳过）。
    errors: Vec<String>,
}

#[tauri::command]
pub async fn global_search(app: AppHandle, state: State<'_, AppState>, query: String, options: Option<SearchOptions>) -> Result<SearchResults> {
    let query = query.trim().to_string();
    let mut results = SearchResults::default();
    if query.is_empty() {
        return Ok(results);
    }
    let options = options.unwrap_or_default();
    let limit = options.limit.unwrap_or(LIMIT).clamp(1, MAX_LIMIT);
    let (local, remote) = match options.phase.as_deref() {
        Some("local") => (true, false),
        Some("remote") => (false, true),
        _ => (true, true),
    };

    // 本机问题库、Wiki 库是否可用：可用时由本机这一步负责，否则由服务器这一步负责
    let jira_local = state.jira().is_ok() && state.config().jira_tools.index_enabled && !index_empty(&state).await;
    let wiki_local = state.confluence().is_ok() && state.config().wiki_tools.index_enabled && !wiki_index_empty(&state).await;

    if local {
        // 四个库互不相关，同时查，用时取决于最慢的一个
        let (workspace, issues, pages, clips) = tokio::join!(
            async {
                let ws = state.workspace.clone();
                let q = query.clone();
                tauri::async_runtime::spawn_blocking(move || ws.search(&q, limit)).await.ok().and_then(|r| r.ok())
            },
            async {
                if !jira_local {
                    return None;
                }
                let index = state.issue_index.clone();
                let q = IndexQuery { text: query.clone(), limit: limit as u32, ..Default::default() };
                tauri::async_runtime::spawn_blocking(move || index.search(&q, "")).await.ok().and_then(|r| r.ok())
            },
            async { if wiki_local { search_wiki_local(&state, &query, limit).await.and_then(|r| r.ok()) } else { None } },
            async {
                let store = app.try_state::<Clip>()?.store.clone();
                let q = ListQuery { text: query.clone(), limit: Some(limit), ..Default::default() };
                tauri::async_runtime::spawn_blocking(move || store.list(&q)).await.ok().and_then(|r| r.ok())
            },
        );
        if let Some(hits) = workspace {
            results.workspace = hits;
        }
        if let Some(hits) = issues {
            results.issues = hits;
            results.issues_source = Some("local");
        }
        if let Some(hits) = pages {
            results.pages = hits;
        }
        if let Some(items) = clips {
            results.clips = items;
        }
    }

    if remote {
        // 问题键在本机问题库中找不到时，仍向服务器查这个键
        let key_missing = is_issue_key(&query) && {
            let (index, key) = (state.issue_index.clone(), query.to_uppercase());
            !tauri::async_runtime::spawn_blocking(move || index.by_keys(&[key])).await.ok().and_then(|r| r.ok()).is_some_and(|hits| !hits.is_empty())
        };
        let (issues, pages, projects, mrs) = tokio::join!(
            async {
                if !jira_local || key_missing {
                    search_issues(&state, &query, limit).await
                } else {
                    None
                }
            },
            async { if wiki_local { None } else { search_wiki_remote(&state, &query, limit).await } },
            async {
                match state.gitlab() {
                    Ok(gitlab) => Some(gitlab.projects(Some(&query), limit).await),
                    Err(_) => None,
                }
            },
            async {
                match state.gitlab() {
                    Ok(gitlab) => Some(gitlab.search_merge_requests(&query, limit).await),
                    Err(_) => None,
                }
            },
        );
        match issues {
            Some(Ok(list)) => {
                if jira_local {
                    // 只补上问题键对应的那一个，放在最前
                    if let Some(hit) = list.into_iter().find(|i| i.issue.key.eq_ignore_ascii_case(&query)) {
                        results.issues.insert(0, hit);
                    }
                    results.issues_source = Some("local");
                } else {
                    results.issues = list;
                    results.issues_source = Some("jira");
                }
            }
            Some(Err(e)) => results.errors.push(format!("Jira：{e}")),
            None => {}
        }
        match pages {
            Some(Ok(list)) => results.pages = list,
            Some(Err(e)) => results.errors.push(format!("Wiki：{e}")),
            None => {}
        }
        match projects {
            Some(Ok(list)) => results.projects = list,
            Some(Err(e)) => results.errors.push(format!("GitLab：{e}")),
            None => {}
        }
        match mrs {
            Some(Ok(list)) => results.merge_requests = list,
            Some(Err(e)) => results.errors.push(format!("GitLab 合并请求：{e}")),
            None => {}
        }
    }
    Ok(results)
}

async fn index_empty(state: &AppState) -> bool {
    let index = state.issue_index.clone();
    tauri::async_runtime::spawn_blocking(move || index.is_empty()).await.ok().and_then(|r| r.ok()).unwrap_or(true)
}

async fn wiki_index_empty(state: &AppState) -> bool {
    let index = state.wiki_index.clone();
    tauri::async_runtime::spawn_blocking(move || index.is_empty()).await.ok().and_then(|r| r.ok()).unwrap_or(true)
}

/// Wiki 页面：本机 Wiki 库（快，且能匹配两个字的中文词）。
async fn search_wiki_local(state: &AppState, query: &str, limit: usize) -> Option<Result<Vec<SearchHit>>> {
    let confluence = state.confluence().ok()?;
    let index = state.wiki_index.clone();
    let q = WikiQuery { text: query.to_string(), limit: limit as u32, ..Default::default() };
    let hits = tauri::async_runtime::spawn_blocking(move || index.search(&q, "")).await.ok()?;
    Some(hits.map(|hits| {
        hits.into_iter().map(|h| SearchHit { url: confluence.page_url(&h.id), id: h.id, title: h.title, space: h.space_name, excerpt: h.snippet }).collect()
    }))
}

async fn search_wiki_remote(state: &AppState, query: &str, limit: usize) -> Option<Result<Vec<SearchHit>>> {
    let confluence = state.confluence().ok()?;
    Some(confluence.search(query, limit as u32).await)
}

async fn search_issues(state: &AppState, query: &str, limit: usize) -> Option<Result<Vec<IssueHit>>> {
    let jira = state.jira().ok()?;
    let escaped = query.replace('\\', "\\\\").replace('"', "\\\"");
    let jql = if is_issue_key(query) {
        format!("key = \"{}\" OR text ~ \"{escaped}\" ORDER BY updated DESC", query.to_uppercase())
    } else {
        format!("text ~ \"{escaped}\" ORDER BY updated DESC")
    };
    let result = match jira.search(&jql, 0, limit as u32).await {
        // 问题编号不存在时 Jira 会报错，此时退回全文搜索
        Err(_) if is_issue_key(query) => jira.search(&format!("text ~ \"{escaped}\" ORDER BY updated DESC"), 0, limit as u32).await,
        other => other,
    };
    Some(result.map(|r| {
        r.issues
            .into_iter()
            .map(|issue| IssueHit { issue, resolved: None, comment_count: 0, snippet: None, last_comments: Vec::new() })
            .collect()
    }))
}

/// 形如 `ABC-123` 的问题编号。
fn is_issue_key(text: &str) -> bool {
    let Some((project, number)) = text.split_once('-') else { return false };
    !project.is_empty()
        && project.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && project.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !number.is_empty()
        && number.chars().all(|c| c.is_ascii_digit())
}
