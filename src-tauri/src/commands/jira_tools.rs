//! Jira 本机增强功能的设置，以及“我的问题”的到期、停滞提醒。

use chrono::{Local, NaiveDate};
use nextworkzone_core::Result;
use nextworkzone_core::config::JiraToolsConfig;
use nextworkzone_jira::{FieldInfo, IssueSummary, parse_time};
use serde::Serialize;
use tauri::State;

use crate::commands::{jira, jira_index};
use crate::state::AppState;

const MY_UNRESOLVED_JQL: &str = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC";
/// 自动识别到期字段时，名称中含有这些词的日期字段视为到期时间。
const DUE_WORDS: &[&str] = &["到期", "截止", "期望完成", "计划完成", "完成日期", "due", "deadline"];
const MAX_DUE_CANDIDATES: usize = 5;

#[tauri::command]
pub fn jira_tools_settings(state: State<'_, AppState>) -> JiraToolsConfig {
    state.config().jira_tools
}

#[tauri::command]
pub async fn jira_save_tools_settings(state: State<'_, AppState>, settings: JiraToolsConfig) -> Result<JiraToolsConfig> {
    let mut config = state.config();
    let old = config.jira_tools.clone();
    let settings = JiraToolsConfig { index_jql: settings.index_jql.trim().to_string(), due_field: settings.due_field.trim().to_string(), ..settings };
    config.jira_tools = settings.clone();
    state.update_config(config)?;
    // 范围变化后旧数据可能不在新范围内，增加天数时更早的问题也需要补上，因此重建
    if old.index_jql != settings.index_jql || old.index_days != settings.index_days {
        let index = state.issue_index.clone();
        tauri::async_runtime::spawn_blocking(move || index.clear()).await.map_err(|e| nextworkzone_core::Error::Other(e.to_string()))??;
    }
    if settings.index_enabled {
        jira_index::wake();
    }
    Ok(settings)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DueField {
    id: String,
    name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reminder {
    #[serde(flatten)]
    pub(crate) issue: IssueSummary,
    /// `overdue` / `today` / `soon` / `stale`
    pub(crate) kind: &'static str,
    /// 到期日期 `YYYY-MM-DD`。
    due: Option<String>,
    /// 到期：距今天数（逾期为负）；停滞：多少天没有更新。
    pub(crate) days: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reminders {
    /// 使用的到期字段；识别不到时为空（只有停滞提醒）。
    due_field: Option<DueField>,
    pub(crate) items: Vec<Reminder>,
    /// 所有未解决问题的到期日期：问题键 → `YYYY-MM-DD`（列表中显示）。
    due_dates: std::collections::BTreeMap<String, String>,
    remind: bool,
}

/// 我的未解决问题中逾期、今天到期、即将到期以及长时间没有更新的问题。
#[tauri::command]
pub async fn jira_reminders(state: State<'_, AppState>) -> Result<Reminders> {
    let config = state.config().jira_tools;
    let fields = jira::fields(&state, false).await.unwrap_or_default();
    let candidates = due_candidates(&config.due_field, &fields);
    let extra: Vec<String> = candidates.iter().filter(|f| f.id != "duedate").map(|f| f.id.clone()).collect();
    let issues = state.jira()?.search_with_fields(MY_UNRESOLVED_JQL, 0, 500, &extra).await?.issues;

    let due_of = |field: &FieldInfo, issue: &IssueSummary| -> Option<String> {
        let value = if field.id == "duedate" { issue.due_date.clone() } else { issue.extra.get(&field.id).cloned() };
        value.and_then(|v| v.get(..10).map(str::to_string)).filter(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").is_ok())
    };
    // 指定了字段就用它；自动识别时选第一个在我的问题上有值的
    let field = if config.due_field.is_empty() {
        candidates.iter().find(|f| issues.iter().any(|i| due_of(f, i).is_some()))
    } else {
        candidates.first()
    };

    let today = Local::now().date_naive();
    let mut items = Vec::new();
    let mut due_dates = std::collections::BTreeMap::new();
    for issue in issues {
        let due = field.and_then(|f| due_of(f, &issue));
        if let Some(d) = &due {
            due_dates.insert(issue.key.clone(), d.clone());
        }
        let due_days = due.as_deref().and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok()).map(|d| (d - today).num_days());
        let idle_days = parse_time(&issue.updated).map(|t| (today - t.with_timezone(&Local).date_naive()).num_days());
        let (kind, days) = match (due_days, idle_days) {
            (Some(d), _) if d < 0 => ("overdue", d),
            (Some(0), _) => ("today", 0),
            (Some(d), _) if d <= config.due_soon_days as i64 => ("soon", d),
            (_, Some(idle)) if config.stale_days > 0 && idle >= config.stale_days as i64 => ("stale", idle),
            _ => continue,
        };
        items.push(Reminder { issue, kind, due, days });
    }
    let rank = |r: &Reminder| match r.kind {
        "overdue" => (0, r.days),
        "today" => (1, 0),
        "soon" => (2, r.days),
        _ => (3, -r.days),
    };
    items.sort_by_key(rank);
    Ok(Reminders {
        due_field: field.map(|f| DueField { id: f.id.clone(), name: f.name.clone() }),
        items,
        due_dates,
        remind: config.remind,
    })
}

/// 可能表示到期时间的字段，按优先顺序。
fn due_candidates(configured: &str, fields: &[FieldInfo]) -> Vec<FieldInfo> {
    let named = |id: &str| fields.iter().find(|f| f.id == id).cloned().unwrap_or_else(|| FieldInfo { id: id.into(), name: id.into(), custom: false, kind: "date".into() });
    if !configured.is_empty() {
        return vec![named(configured)];
    }
    let mut list = vec![FieldInfo { name: fields.iter().find(|f| f.id == "duedate").map_or("到期日".into(), |f| f.name.clone()), ..named("duedate") }];
    list.extend(
        fields
            .iter()
            .filter(|f| f.custom && matches!(f.kind.as_str(), "date" | "datetime"))
            .filter(|f| {
                let name = f.name.to_lowercase();
                DUE_WORDS.iter().any(|w| name.contains(w))
            })
            .take(MAX_DUE_CANDIDATES)
            .cloned(),
    );
    list
}
