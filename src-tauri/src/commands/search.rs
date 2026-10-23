use nextworkzone_confluence::SearchHit;
use nextworkzone_confluence::index::WikiQuery;
use nextworkzone_core::Result;
use nextworkzone_gitlab::Project;
use nextworkzone_jira::IssueSummary;
use nextworkzone_workspace::SearchHit as WorkspaceHit;
use serde::Serialize;
use tauri::State;

use crate::state::AppState;

const LIMIT: usize = 8;

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SearchResults {
    issues: Vec<IssueSummary>,
    projects: Vec<Project>,
    pages: Vec<SearchHit>,
    /// 本地的待办、笔记、知识库
    workspace: Vec<WorkspaceHit>,
    /// 某个系统搜索失败时的提示（未配置的系统直接跳过）。
    errors: Vec<String>,
}

/// 全局搜索：同时检索本地的待办和文档、Jira 问题、GitLab 项目和 Wiki 页面。
#[tauri::command]
pub async fn global_search(state: State<'_, AppState>, query: String) -> Result<SearchResults> {
    let query = query.trim().to_string();
    if query.is_empty() {
        return Ok(SearchResults::default());
    }
    let (issues, projects, pages) = tokio::join!(
        search_issues(&state, &query),
        async {
            match state.gitlab() {
                Ok(gitlab) => Some(gitlab.projects(Some(&query), LIMIT).await),
                Err(_) => None,
            }
        },
        search_wiki(&state, &query),
    );

    let mut results = SearchResults::default();
    let ws = state.workspace.clone();
    let local_query = query.clone();
    if let Ok(Ok(hits)) = tauri::async_runtime::spawn_blocking(move || ws.search(&local_query, LIMIT)).await {
        results.workspace = hits;
    }
    match issues {
        Some(Ok(list)) => results.issues = list,
        Some(Err(e)) => results.errors.push(format!("Jira：{e}")),
        None => {}
    }
    match projects {
        Some(Ok(list)) => results.projects = list,
        Some(Err(e)) => results.errors.push(format!("GitLab：{e}")),
        None => {}
    }
    match pages {
        Some(Ok(list)) => results.pages = list,
        Some(Err(e)) => results.errors.push(format!("Wiki：{e}")),
        None => {}
    }
    Ok(results)
}

/// Wiki 页面：本机 Wiki 库有数据时在本机搜索（快，且能匹配两个字的中文词），否则用 Confluence 搜索。
async fn search_wiki(state: &AppState, query: &str) -> Option<Result<Vec<SearchHit>>> {
    let confluence = state.confluence().ok()?;
    let index = state.wiki_index.clone();
    if state.config().wiki_tools.index_enabled {
        let q = WikiQuery { text: query.to_string(), limit: LIMIT as u32, ..Default::default() };
        let local = tauri::async_runtime::spawn_blocking(move || if index.is_empty()? { Ok(None) } else { index.search(&q, "").map(Some) }).await;
        if let Ok(Ok(Some(hits))) = local {
            return Some(Ok(hits
                .into_iter()
                .map(|h| SearchHit { url: confluence.page_url(&h.id), id: h.id, title: h.title, space: h.space_name, excerpt: h.snippet })
                .collect()));
        }
    }
    Some(confluence.search(query, LIMIT as u32).await)
}

async fn search_issues(state: &AppState, query: &str) -> Option<Result<Vec<IssueSummary>>> {
    let jira = state.jira().ok()?;
    let escaped = query.replace('\\', "\\\\").replace('"', "\\\"");
    let jql = if is_issue_key(query) {
        format!("key = \"{}\" OR text ~ \"{escaped}\" ORDER BY updated DESC", query.to_uppercase())
    } else {
        format!("text ~ \"{escaped}\" ORDER BY updated DESC")
    };
    let result = match jira.search(&jql, 0, LIMIT as u32).await {
        // 问题编号不存在时 Jira 会报错，此时退回全文搜索
        Err(_) if is_issue_key(query) => jira.search(&format!("text ~ \"{escaped}\" ORDER BY updated DESC"), 0, LIMIT as u32).await,
        other => other,
    };
    Some(result.map(|r| r.issues))
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
