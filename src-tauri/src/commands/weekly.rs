use std::collections::{BTreeMap, HashMap};

use chrono::{Duration, Local, NaiveDate};
use nextworkzone_confluence::weekly::{self, OutlineItem};
use nextworkzone_confluence::{SaveResult, WeeklyView};
use nextworkzone_core::{Error, Result};
use serde::{Deserialize, Serialize};
use tauri::State;

use crate::state::AppState;

fn page_id(state: &AppState) -> Result<String> {
    let id = state.config().weekly.page_id;
    if id.is_empty() {
        return Err(Error::Other("请先在设置中填写周报页面地址".into()));
    }
    Ok(id)
}

async fn person_name(state: &AppState) -> Result<String> {
    let configured = state.config().weekly.person_name;
    state.confluence()?.resolve_person_name(&configured).await
}

fn today() -> NaiveDate {
    Local::now().date_naive()
}

#[tauri::command]
pub async fn weekly_load(state: State<'_, AppState>, section: Option<String>) -> Result<WeeklyView> {
    let page_id = page_id(&state)?;
    let name = person_name(&state).await?;
    state.confluence()?.weekly_load(&page_id, &name, section.as_deref(), today()).await
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveInput {
    section: String,
    content_raw: String,
    risk_raw: String,
    content: Vec<OutlineItem>,
    risk: Vec<OutlineItem>,
}

#[tauri::command]
pub async fn weekly_save(state: State<'_, AppState>, input: SaveInput) -> Result<SaveResult> {
    let page_id = page_id(&state)?;
    let name = person_name(&state).await?;
    state
        .confluence()?
        .weekly_save(
            &page_id,
            &name,
            &input.section,
            (&input.content_raw, &input.risk_raw),
            &input.content,
            &input.risk,
        )
        .await
}

/// 新建本周小节后返回新小节的内容。
#[tauri::command]
pub async fn weekly_create_week(state: State<'_, AppState>) -> Result<WeeklyView> {
    let page_id = page_id(&state)?;
    let name = person_name(&state).await?;
    let confluence = state.confluence()?;
    let title = confluence.weekly_create_week(&page_id, today()).await?;
    confluence.weekly_load(&page_id, &name, Some(&title), today()).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftGroup {
    title: String,
    source: &'static str,
    items: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Draft {
    from: String,
    to: String,
    groups: Vec<DraftGroup>,
    /// 某个数据源不可用时的提示。
    notes: Vec<String>,
}

/// 根据该周内经手的 Jira 问题和 GitLab 推送生成周报草稿。
#[tauri::command]
pub async fn weekly_draft(state: State<'_, AppState>, section: Option<String>) -> Result<Draft> {
    let today = today();
    let (from, to) = section
        .as_deref()
        .and_then(|s| weekly::parse_range(s, today))
        .unwrap_or_else(|| {
            let monday = today - Duration::days(chrono::Datelike::weekday(&today).num_days_from_monday() as i64);
            (monday, monday + Duration::days(6))
        });

    let (jira, worklogs, gitlab, wiki) =
        tokio::join!(jira_draft(&state, from, to), worklog_draft(&state, from, to), gitlab_draft(&state, from, to), wiki_draft(&state, from, to));
    let mut groups = Vec::new();
    let mut notes = Vec::new();
    match jira {
        Ok(g) => groups.extend(g),
        Err(e) => notes.push(format!("Jira：{e}")),
    }
    match worklogs {
        Ok(g) => groups.extend(g),
        Err(e) => notes.push(format!("工作日志：{e}")),
    }
    match gitlab {
        Ok(g) => groups.extend(g),
        Err(e) => notes.push(format!("GitLab：{e}")),
    }
    match wiki {
        Ok(g) => groups.extend(g),
        Err(e) => notes.push(format!("Wiki：{e}")),
    }
    match workspace_draft(&state, from, to) {
        Ok(g) => groups.extend(g),
        Err(e) => notes.push(format!("工作空间：{e}")),
    }
    Ok(Draft { from: from.to_string(), to: to.to_string(), groups, notes })
}

async fn jira_draft(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<Vec<DraftGroup>> {
    let end = to + Duration::days(1);
    let jql = format!(
        "((assignee = currentUser() AND updated >= \"{from}\" AND updated < \"{end}\") \
         OR status CHANGED BY currentUser() DURING (\"{from}\", \"{end}\")) ORDER BY project, updated DESC"
    );
    let result = state.jira()?.search(&jql, 0, 100).await?;
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for issue in result.issues {
        let progress = if issue.status.category == "done" { "100%".to_string() } else { issue.status.name.clone() };
        groups.entry(issue.project.name.clone()).or_default().push(format!("{} --{progress}", issue.summary));
    }
    Ok(groups.into_iter().map(|(title, items)| DraftGroup { title, source: "jira", items }).collect())
}

/// 这一周登记的工作日志：每个问题一条，带耗时合计和日志说明。
async fn worklog_draft(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<Vec<DraftGroup>> {
    let me = state.jira_username().await?;
    let logs = state.jira()?.my_worklogs(&me, &from.to_string(), &to.to_string()).await?;
    if logs.is_empty() {
        return Ok(Vec::new());
    }
    let mut total = 0;
    let items = logs
        .into_iter()
        .map(|(issue, logs)| {
            let seconds: u64 = logs.iter().map(|w| w.time_spent_seconds).sum();
            total += seconds;
            let mut comments: Vec<&str> = logs.iter().map(|w| w.comment.trim()).filter(|c| !c.is_empty()).collect();
            comments.dedup();
            let detail = if comments.is_empty() { String::new() } else { format!("：{}", comments.join("；")) };
            format!("{}（{}）{detail}", issue.summary, format_duration(seconds))
        })
        .collect();
    Ok(vec![DraftGroup { title: format!("工作日志 · 合计 {}", format_duration(total)), source: "worklog", items }])
}

/// 时长，例如 3h 30m。
fn format_duration(seconds: u64) -> String {
    let minutes = seconds.div_ceil(60);
    match (minutes / 60, minutes % 60) {
        (0, m) => format!("{m}m"),
        (h, 0) => format!("{h}h"),
        (h, m) => format!("{h}h {m}m"),
    }
}

/// 这一周创建、修改过的 Wiki 页面（周报页面本身除外）。
async fn wiki_draft(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<Vec<DraftGroup>> {
    let Ok(confluence) = state.confluence() else { return Ok(Vec::new()) };
    let weekly_page = state.config().weekly.page_id;
    let work = confluence.my_work(&from.to_string(), &(to + Duration::days(1)).to_string()).await?;
    let mut items: Vec<String> = Vec::new();
    for w in work.into_iter().filter(|w| w.kind != "comment" && w.page_id != weekly_page) {
        let line = if w.kind == "create" { format!("新建 Wiki 页面：{}", w.title) } else { format!("更新 Wiki 页面：{}", w.title) };
        if !items.iter().any(|i| i.ends_with(&format!("：{}", w.title))) {
            items.push(line);
        }
    }
    Ok(if items.is_empty() { Vec::new() } else { vec![DraftGroup { title: "Wiki".into(), source: "wiki", items }] })
}

/// 工作空间：这一周手动完成的待办（Jira 问题已在上面列出），以及日记中的内容。
fn workspace_draft(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<Vec<DraftGroup>> {
    let ws = &state.workspace;
    let start = from.and_hms_opt(0, 0, 0).and_then(|t| t.and_local_timezone(Local).single()).map(|t| t.timestamp_millis());
    let end = (to + Duration::days(1)).and_hms_opt(0, 0, 0).and_then(|t| t.and_local_timezone(Local).single()).map(|t| t.timestamp_millis());
    let mut groups = Vec::new();
    if let (Some(start), Some(end)) = (start, end) {
        let todos: Vec<String> = ws
            .todos()?
            .into_iter()
            .filter(|t| t.done && !t.auto_done && t.source.as_deref() != Some("jira"))
            .filter(|t| t.completed_at.is_some_and(|at| at >= start && at < end))
            .map(|t| t.title)
            .filter(|t| !t.trim().is_empty())
            .collect();
        if !todos.is_empty() {
            groups.push(DraftGroup { title: "完成的待办".into(), source: "todo", items: todos });
        }
    }
    let mut lines: Vec<String> = Vec::new();
    let mut day = from;
    while day <= to {
        let doc = ws.daily(&day.to_string())?;
        for line in nextworkzone_workspace::plain_text(&doc.content).lines() {
            // 去掉列表、任务框标记
            let text = line.trim_start_matches(['-', '*', '+', ' ']).trim_start_matches("[ ]").trim_start_matches("[x]").trim();
            if !text.is_empty() && !lines.iter().any(|l| l == text) {
                lines.push(text.to_string());
            }
        }
        day += Duration::days(1);
    }
    if !lines.is_empty() {
        groups.push(DraftGroup { title: "日记".into(), source: "daily", items: lines });
    }
    Ok(groups)
}

async fn gitlab_draft(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<Vec<DraftGroup>> {
    let gitlab = state.gitlab()?;
    // GitLab 的 after 参数不含当天
    let pushes = gitlab.my_pushes(&(from - Duration::days(1)).to_string()).await?;
    let end = (to + Duration::days(1)).to_string();
    let mut by_project: BTreeMap<u64, Vec<String>> = BTreeMap::new();
    for push in pushes.into_iter().filter(|p| p.created_at.as_str() < end.as_str()) {
        let title = push.commit_title.trim().to_string();
        if title.is_empty() || title.starts_with("Merge branch") || title.starts_with("Merge remote") {
            continue;
        }
        let items = by_project.entry(push.project_id).or_default();
        if !items.contains(&title) {
            items.push(title);
        }
    }
    let mut names: HashMap<u64, String> = HashMap::new();
    for id in by_project.keys() {
        let name = gitlab.project(*id).await.map(|p| p.name).unwrap_or_else(|_| format!("项目 {id}"));
        names.insert(*id, name);
    }
    Ok(by_project
        .into_iter()
        .map(|(id, items)| DraftGroup { title: names.remove(&id).unwrap_or_default(), source: "gitlab", items })
        .collect())
}
