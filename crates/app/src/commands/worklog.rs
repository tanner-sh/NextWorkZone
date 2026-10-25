//! 工作记录：某一天我在各处做过的事，按时间排成一条线——Jira 上的创建、流转、评论，
//! GitLab 上的推送、合并请求，Wiki 上的页面和评论，以及完成的待办。
//! 用于日记中的“工作记录”和一键生成日报；外部系统的数据按日期实时查询。

use std::collections::HashMap;
use std::sync::Mutex;

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone};
use nextworkzone_core::{Error, Result};
use serde::Serialize;

use crate::state::AppState;

/// GitLab 项目名称缓存（工作记录中按项目显示）。
static PROJECT_NAMES: Mutex<Option<HashMap<u64, String>>> = Mutex::new(None);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkEvent {
    /// 时间（毫秒）。
    at: i64,
    /// `jira` / `gitlab` / `wiki` / `todo`
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
pub async fn bridge_work_events(state: &AppState, day: String) -> Result<WorkLog> {
    let date = NaiveDate::parse_from_str(&day, "%Y-%m-%d").map_err(|_| Error::Other(format!("日期无效：{day}")))?;
    let (start, end) = (local_ms(date)?, local_ms(date + Duration::days(1))?);
    let within = |at: i64| at >= start && at < end;
    let mut events: Vec<WorkEvent> = Vec::new();
    let mut notes = Vec::new();

    for (label, result) in [("GitLab", gitlab_events(state, date).await)] {
        match result {
            Ok(found) => events.extend(found.into_iter().filter(|e| within(e.at))),
            Err(e) => notes.push(format!("{label}：{e}")),
        }
    }

    events.sort_by_key(|e| e.at);
    Ok(WorkLog { day, events, notes })
}

async fn gitlab_events(state: &AppState, date: NaiveDate) -> Result<Vec<WorkEvent>> {
    let Ok(gitlab) = state.gitlab() else { return Ok(Vec::new()) };
    // GitLab 按 UTC 日期过滤，前后各多查一天，再按本地时间筛选
    let found = gitlab.my_events(&(date - Duration::days(2)).to_string(), &(date + Duration::days(2)).to_string()).await?;
    let names = project_names(&gitlab, found.iter().map(|e| e.project_id)).await;
    Ok(found
        .into_iter()
        .filter_map(|e| {
            let project = names.get(&e.project_id).cloned().unwrap_or_default();
            let (title, key, detail) = match e.kind.as_str() {
                "push" => (project, None, if e.commit_count > 1 { format!("{}（{} 个提交，{}）", e.detail, e.commit_count, e.title) } else { format!("{}（{}）", e.detail, e.title) }),
                _ => (project, e.iid.map(|i| format!("!{i}")), if e.kind == "comment" { format!("{}：{}", e.title, e.detail) } else { e.title.clone() }),
            };
            Some(WorkEvent { at: ms_of(&e.at)?, system: "gitlab", kind: e.kind, title, key, detail, project_id: Some(e.project_id) })
        })
        .collect())
}

/// GitLab 项目 id 对应的名称（查过的缓存起来）。
pub(crate) async fn project_names(gitlab: &nextworkzone_gitlab::GitlabClient, ids: impl Iterator<Item = u64>) -> HashMap<u64, String> {
    let mut names = PROJECT_NAMES.lock().unwrap().clone().unwrap_or_default();
    for id in ids {
        if let std::collections::hash_map::Entry::Vacant(slot) = names.entry(id) {
            slot.insert(gitlab.project(id).await.map(|p| p.name).unwrap_or_else(|_| format!("项目 {id}")));
        }
    }
    *PROJECT_NAMES.lock().unwrap() = Some(names.clone());
    names
}
