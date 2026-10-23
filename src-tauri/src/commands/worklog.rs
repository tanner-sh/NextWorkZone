//! 工作记录：某一天我在各处做过的事，按时间排成一条线——Jira 上的创建、流转、评论，
//! GitLab 上的推送、合并请求，Wiki 上的页面和评论，完成的待办，以及计时。
//! 用于日记中的“工作记录”和一键生成日报；外部系统的数据按日期实时查询，计时记录保存在本机。

use std::collections::HashMap;
use std::sync::Mutex;

use chrono::{DateTime, Duration, FixedOffset, Local, NaiveDate, TimeZone};
use nextworkzone_core::{Error, Result};
use nextworkzone_workspace::TimeEntry;
use serde::{Deserialize, Serialize};
use tauri::State;

use crate::state::AppState;

/// GitLab 项目名称缓存（工作记录中按项目显示）。
static PROJECT_NAMES: Mutex<Option<HashMap<u64, String>>> = Mutex::new(None);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkEvent {
    /// 时间（毫秒）。
    at: i64,
    /// `jira` / `gitlab` / `wiki` / `todo` / `timer`
    system: &'static str,
    /// 各系统中的动作，例如 `transition`、`push`、`mr_merge`、`edit`、`done`。
    kind: String,
    /// 对象：问题概要、项目名称、页面标题、待办标题。
    title: String,
    /// 问题键、合并请求编号 `!12`、页面 id。
    key: Option<String>,
    detail: String,
    /// GitLab 项目 id（打开合并请求用）。
    project_id: Option<u64>,
    duration_ms: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkLog {
    day: String,
    events: Vec<WorkEvent>,
    /// 某个来源获取失败时的提示。
    notes: Vec<String>,
}

fn local_ms(day: NaiveDate) -> Result<i64> {
    let start = day.and_hms_opt(0, 0, 0).ok_or_else(|| Error::Other("日期无效".into()))?;
    Local.from_local_datetime(&start).single().map(|t| t.timestamp_millis()).ok_or_else(|| Error::Other("日期无效".into()))
}

fn ms_of(s: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(s).ok().or_else(|| nextworkzone_jira::parse_time(s)).map(|t| t.timestamp_millis())
}

/// 某一天（`YYYY-MM-DD`）的工作记录。
#[tauri::command]
pub async fn ws_worklog(state: State<'_, AppState>, day: String) -> Result<WorkLog> {
    let date = NaiveDate::parse_from_str(&day, "%Y-%m-%d").map_err(|_| Error::Other(format!("日期无效：{day}")))?;
    let (start, end) = (local_ms(date)?, local_ms(date + Duration::days(1))?);
    let within = |at: i64| at >= start && at < end;
    let mut events: Vec<WorkEvent> = Vec::new();
    let mut notes = Vec::new();

    let (jira, gitlab, wiki) = tokio::join!(jira_events(&state, date), gitlab_events(&state, date), wiki_events(&state, date));
    for (label, result) in [("Jira", jira), ("GitLab", gitlab), ("Wiki", wiki)] {
        match result {
            Ok(found) => events.extend(found.into_iter().filter(|e| within(e.at))),
            Err(e) => notes.push(format!("{label}：{e}")),
        }
    }

    // 手动完成的待办（问题解决后自动完成的不算）
    for todo in state.workspace.todos()?.into_iter().filter(|t| t.done && !t.auto_done) {
        if let Some(at) = todo.completed_at.filter(|at| within(*at)) {
            events.push(WorkEvent {
                at,
                system: "todo",
                kind: "done".into(),
                title: todo.title,
                key: todo.ref_key.filter(|_| todo.ref_system.as_deref() == Some("jira")),
                detail: String::new(),
                project_id: None,
                duration_ms: None,
            });
        }
    }
    for entry in state.workspace.time_entries(start, end)? {
        events.push(WorkEvent {
            at: entry.started_at,
            system: "timer",
            kind: "timer".into(),
            title: entry.title,
            key: entry.issue_key,
            detail: String::new(),
            project_id: None,
            duration_ms: Some(entry.duration_ms),
        });
    }
    events.sort_by_key(|e| e.at);
    Ok(WorkLog { day, events, notes })
}

async fn jira_events(state: &AppState, date: NaiveDate) -> Result<Vec<WorkEvent>> {
    let Ok(jira) = state.jira() else { return Ok(Vec::new()) };
    let me = state.jira_username().await?;
    let zone = |d: NaiveDate| -> Result<DateTime<FixedOffset>> {
        Ok(Local.timestamp_millis_opt(local_ms(d)?).single().ok_or_else(|| Error::Other("日期无效".into()))?.fixed_offset())
    };
    let next = date + Duration::days(1);
    let actions = jira.my_actions(&me, &date.to_string(), &next.to_string(), zone(date)?, zone(next)?).await?;
    Ok(actions
        .into_iter()
        .filter_map(|a| {
            Some(WorkEvent { at: ms_of(&a.at)?, system: "jira", kind: a.kind, title: a.summary, key: Some(a.key), detail: a.detail, project_id: None, duration_ms: None })
        })
        .collect())
}

async fn gitlab_events(state: &AppState, date: NaiveDate) -> Result<Vec<WorkEvent>> {
    let Ok(gitlab) = state.gitlab() else { return Ok(Vec::new()) };
    // GitLab 按 UTC 日期过滤，前后各多查一天，再按本地时间筛选
    let found = gitlab.my_events(&(date - Duration::days(2)).to_string(), &(date + Duration::days(2)).to_string()).await?;
    let mut names = PROJECT_NAMES.lock().unwrap().clone().unwrap_or_default();
    for id in found.iter().map(|e| e.project_id) {
        if let std::collections::hash_map::Entry::Vacant(slot) = names.entry(id) {
            slot.insert(gitlab.project(id).await.map(|p| p.name).unwrap_or_else(|_| format!("项目 {id}")));
        }
    }
    *PROJECT_NAMES.lock().unwrap() = Some(names.clone());
    Ok(found
        .into_iter()
        .filter_map(|e| {
            let project = names.get(&e.project_id).cloned().unwrap_or_default();
            let (title, key, detail) = match e.kind.as_str() {
                "push" => (project, None, if e.commit_count > 1 { format!("{}（{} 个提交，{}）", e.detail, e.commit_count, e.title) } else { format!("{}（{}）", e.detail, e.title) }),
                _ => (project, e.iid.map(|i| format!("!{i}")), if e.kind == "comment" { format!("{}：{}", e.title, e.detail) } else { e.title.clone() }),
            };
            Some(WorkEvent { at: ms_of(&e.at)?, system: "gitlab", kind: e.kind, title, key, detail, project_id: Some(e.project_id), duration_ms: None })
        })
        .collect())
}

async fn wiki_events(state: &AppState, date: NaiveDate) -> Result<Vec<WorkEvent>> {
    let Ok(confluence) = state.confluence() else { return Ok(Vec::new()) };
    let found = confluence.my_work(&date.to_string(), &(date + Duration::days(1)).to_string()).await?;
    Ok(found
        .into_iter()
        .filter_map(|w| Some(WorkEvent { at: ms_of(&w.at)?, system: "wiki", kind: w.kind, title: w.title, key: Some(w.page_id), detail: w.detail, project_id: None, duration_ms: None }))
        .collect())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeEntryInput {
    title: String,
    issue_key: Option<String>,
    todo_id: Option<String>,
    started_at: i64,
    duration_ms: i64,
}

/// 计时结束时记下这段时间（无论是否登记到 Jira）。
#[tauri::command]
pub async fn ws_add_time_entry(state: State<'_, AppState>, input: TimeEntryInput) -> Result<()> {
    // 不足一分钟的计时（误点开始又马上停止）不记
    if input.duration_ms < 60_000 {
        return Ok(());
    }
    let entry = TimeEntry {
        id: uuid::Uuid::new_v4().to_string(),
        title: input.title,
        issue_key: input.issue_key,
        todo_id: input.todo_id,
        started_at: input.started_at,
        ended_at: chrono::Utc::now().timestamp_millis(),
        duration_ms: input.duration_ms,
    };
    state.workspace.add_time_entry(&entry)
}
