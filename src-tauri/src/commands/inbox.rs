//! 收件箱：把需要我处理的事汇总到一处——随手记下的内容、动态（提到我、分配给我、评论等）、
//! 逾期或今天到期的问题、请我审核或指派给我的合并请求。
//!
//! 外部条目每次实时汇总，工作空间中只记录“已处理”“稍后提醒”的状态（随工作空间同步）：
//! 动态在处理之后有新的动态、合并请求在处理之后有更新、到期问题到了第二天仍未解决时，条目重新出现。
//! 另有后台循环在提醒时间到达时发送系统通知（待办的提醒时间、收件箱的稍后提醒）。

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{Local, TimeZone};
use nextworkzone_core::Result;
use nextworkzone_gitlab::{MergeRequest, MrQuery, MrScope};
use nextworkzone_jira::ActivityEvent;
use nextworkzone_workspace::{InboxEntry, Workspace};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_notification::NotificationExt;

use crate::commands::{activity, jira_tools};
use crate::state::AppState;

/// 收件箱有变化（提醒到时、其他窗口记下内容）时发给前端的事件。
pub const INBOX_EVENT: &str = "inbox-changed";
/// 需要处理的动态类型；字段修改、Wiki 页面修改、点赞等只在动态页中查看。
const ACTION_KINDS: &[&str] = &["mention", "assigned", "comment", "status", "created", "share", "task"];
/// 合并请求列表的缓存时间，收件箱计数会定期刷新，不必每次都请求 GitLab。
const MR_CACHE: Duration = Duration::from_secs(120);
const ALERT_INTERVAL: Duration = Duration::from_secs(20);

/// 合并请求及进入收件箱的原因（请你审核 / 指派给你）。
type MrList = Vec<(MergeRequest, &'static str)>;
static MR_CACHE_DATA: Mutex<Option<(Instant, MrList)>> = Mutex::new(None);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MrRef {
    project_id: u64,
    iid: u64,
    reference: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxItem {
    id: String,
    /// `capture` 记下的内容 / `activity` 动态 / `due` 到期问题 / `mr` 合并请求
    source: &'static str,
    title: String,
    detail: String,
    /// 最近一次变化的时间（毫秒）。
    at: i64,
    /// `jira` / `wiki` / `gitlab`
    system: Option<String>,
    /// Jira 问题键或 Wiki 页面 id。
    key: Option<String>,
    url: Option<String>,
    mr: Option<MrRef>,
    /// 尚未处理的动态（最新的在前）。
    events: Vec<ActivityEvent>,
    /// 到期问题：`overdue` / `today`，以及距今天数。
    due_kind: Option<String>,
    due_days: Option<i64>,
    snooze_until: Option<i64>,
}

impl InboxItem {
    fn new(id: String, source: &'static str, title: String, at: i64) -> Self {
        Self {
            id,
            source,
            title,
            detail: String::new(),
            at,
            system: None,
            key: None,
            url: None,
            mr: None,
            events: Vec::new(),
            due_kind: None,
            due_days: None,
            snooze_until: None,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxView {
    items: Vec<InboxItem>,
    /// 稍后提醒、尚未到时间的条目。
    snoozed: Vec<InboxItem>,
    /// 某个来源获取失败时的提示。
    notes: Vec<String>,
}

fn start_of_today() -> i64 {
    let today = Local::now().date_naive().and_hms_opt(0, 0, 0).unwrap_or_default();
    Local.from_local_datetime(&today).single().map_or(0, |t| t.timestamp_millis())
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

#[tauri::command]
pub async fn ws_inbox(state: State<'_, AppState>) -> Result<InboxView> {
    let entries: BTreeMap<String, InboxEntry> = state.workspace.inbox()?.into_iter().map(|e| (e.id.clone(), e)).collect();
    let mut items: Vec<InboxItem> = Vec::new();
    let mut notes = Vec::new();

    for e in entries.values().filter(|e| e.kind == "capture" && e.handled_at.is_none()) {
        let mut item = InboxItem::new(e.id.clone(), "capture", e.title.clone(), e.created_at);
        item.detail = e.body.clone();
        item.url = e.url.clone();
        items.push(item);
    }

    // 动态按问题（页面）合并为一条
    let handled = |id: &str| entries.get(id).and_then(|e| e.handled_at).unwrap_or(0);
    let mut groups: BTreeMap<String, InboxItem> = BTreeMap::new();
    for event in activity::stored_events(&state) {
        if event.read || !ACTION_KINDS.contains(&event.kind.as_str()) || event.issue_key.is_empty() {
            continue;
        }
        let id = format!("activity:{}:{}", event.system, event.issue_key);
        let at = activity::event_ms(&event);
        if at <= handled(&id) {
            continue;
        }
        let item = groups.entry(id.clone()).or_insert_with(|| {
            let title = if event.system == "wiki" { event.issue_summary.clone() } else { format!("{} {}", event.issue_key, event.issue_summary) };
            let mut item = InboxItem::new(id, "activity", title, at);
            item.system = Some(event.system.clone());
            item.key = Some(event.issue_key.clone());
            item
        });
        item.at = item.at.max(at);
        item.events.push(event);
    }
    for mut item in groups.into_values() {
        item.events.sort_by_key(|e| std::cmp::Reverse(activity::event_ms(e)));
        items.push(item);
    }

    let (due, mrs) = tokio::join!(due_items(&state, &entries), mr_items(&state, &entries));
    match due {
        Ok(found) => items.extend(found),
        Err(e) => notes.push(format!("到期问题：{e}")),
    }
    match mrs {
        Ok(found) => items.extend(found),
        Err(e) => notes.push(format!("合并请求：{e}")),
    }

    // 稍后提醒：时间未到的放到另一组
    let now = now_ms();
    let mut snoozed = Vec::new();
    let mut ready = Vec::new();
    for mut item in items {
        item.snooze_until = entries.get(&item.id).and_then(|e| e.snooze_until);
        if item.snooze_until.is_some_and(|until| until > now) {
            snoozed.push(item);
        } else {
            ready.push(item);
        }
    }
    ready.sort_by_key(|i| std::cmp::Reverse(i.at));
    snoozed.sort_by_key(|i| i.snooze_until);
    Ok(InboxView { items: ready, snoozed, notes })
}

/// 逾期或今天到期的问题；处理后当天不再出现，第二天仍未解决时再次出现。
async fn due_items(state: &State<'_, AppState>, entries: &BTreeMap<String, InboxEntry>) -> Result<Vec<InboxItem>> {
    if state.jira().is_err() {
        return Ok(Vec::new());
    }
    let today = start_of_today();
    let reminders = jira_tools::jira_reminders(state.clone()).await?;
    Ok(reminders
        .items
        .into_iter()
        .filter(|r| r.kind == "overdue" || r.kind == "today")
        .filter_map(|r| {
            let id = format!("due:{}", r.issue.key);
            if entries.get(&id).and_then(|e| e.handled_at).is_some_and(|at| at >= today) {
                return None;
            }
            let mut item = InboxItem::new(id, "due", format!("{} {}", r.issue.key, r.issue.summary), today);
            item.system = Some("jira".into());
            item.key = Some(r.issue.key.clone());
            item.due_kind = Some(r.kind.to_string());
            item.due_days = Some(r.days);
            item.detail = r.issue.status.name.clone();
            Some(item)
        })
        .collect())
}

/// 请我审核、指派给我的未合并的合并请求（我自己发起的除外）；处理后有更新时再次出现。
async fn mr_items(state: &State<'_, AppState>, entries: &BTreeMap<String, InboxEntry>) -> Result<Vec<InboxItem>> {
    let Ok(gitlab) = state.gitlab() else { return Ok(Vec::new()) };
    let cached = MR_CACHE_DATA.lock().unwrap().as_ref().filter(|(at, _)| at.elapsed() < MR_CACHE).map(|(_, list)| list.clone());
    let list = match cached {
        Some(list) => list,
        None => {
            let me = gitlab.current_user().await?;
            let query = MrQuery { state: Some("opened".into()), search: None, source_branch: None, page: None };
            let (reviewing, assigned) = tokio::join!(gitlab.merge_requests(MrScope::Reviewer, &query), gitlab.merge_requests(MrScope::AssignedToMe, &query));
            let mut list: MrList = Vec::new();
            for (mr, reason) in reviewing?.into_iter().map(|m| (m, "请你审核")).chain(assigned?.into_iter().map(|m| (m, "指派给你"))) {
                if mr.author.id != me.id && !list.iter().any(|(m, _)| m.id == mr.id) {
                    list.push((mr, reason));
                }
            }
            *MR_CACHE_DATA.lock().unwrap() = Some((Instant::now(), list.clone()));
            list
        }
    };
    Ok(list
        .into_iter()
        .filter_map(|(mr, reason)| {
            let id = format!("mr:{}:{}", mr.project_id, mr.iid);
            let updated = chrono::DateTime::parse_from_rfc3339(&mr.updated_at).map_or(0, |t| t.timestamp_millis());
            if entries.get(&id).and_then(|e| e.handled_at).is_some_and(|at| at >= updated) {
                return None;
            }
            let mut item = InboxItem::new(id, "mr", mr.title.clone(), updated);
            item.system = Some("gitlab".into());
            item.detail = format!("{} · {} · {}", mr.reference, mr.author.name, reason);
            item.url = Some(mr.web_url.clone());
            item.mr = Some(MrRef { project_id: mr.project_id, iid: mr.iid, reference: mr.reference.clone() });
            Some(item)
        })
        .collect())
}

/// 记下一条待处理的内容（全局快速记录、收件箱页面中添加）。
#[tauri::command]
pub async fn ws_capture(app: AppHandle, state: State<'_, AppState>, title: String, body: String, url: Option<String>) -> Result<InboxEntry> {
    let ws = state.workspace.clone();
    let entry = run(&ws, move |ws| ws.capture(&title, &body, url.as_deref())).await?;
    let _ = app.emit(INBOX_EVENT, ());
    Ok(entry)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HandleInput {
    id: String,
    source: String,
    title: String,
    /// 动态条目：一并标为已读的动态。
    #[serde(default)]
    event_ids: Vec<String>,
}

/// 处理完一条（完成、忽略或已转为待办）：记下的内容直接删除，外部条目记下处理时间。
#[tauri::command]
pub async fn ws_inbox_handle(state: State<'_, AppState>, input: HandleInput) -> Result<()> {
    if !input.event_ids.is_empty() {
        activity::jira_activity_read(state.clone(), Some(input.event_ids.clone())).await?;
    }
    let ws = state.workspace.clone();
    run(&ws, move |ws| {
        if input.source == "capture" {
            ws.delete_inbox(&input.id)
        } else {
            ws.set_inbox_state(&input.id, &input.title, Some(now_ms()), None).map(|_| ())
        }
    })
    .await
}

/// 稍后提醒；`until` 为空时取消稍后提醒。
#[tauri::command]
pub async fn ws_inbox_snooze(state: State<'_, AppState>, id: String, title: String, until: Option<i64>) -> Result<()> {
    let ws = state.workspace.clone();
    run(&ws, move |ws| ws.set_inbox_state(&id, &title, None, until).map(|_| ())).await
}

async fn run<T: Send + 'static>(ws: &std::sync::Arc<Workspace>, f: impl FnOnce(&Workspace) -> Result<T> + Send + 'static) -> Result<T> {
    let ws = ws.clone();
    tauri::async_runtime::spawn_blocking(move || f(&ws)).await.map_err(|e| nextworkzone_core::Error::Other(e.to_string()))?
}

/// 后台检查提醒时间：到时发送系统通知，并通知前端刷新。不依赖窗口是否显示。
pub async fn alert_loop(app: AppHandle) {
    let mut interval = tokio::time::interval(ALERT_INTERVAL);
    loop {
        interval.tick().await;
        let ws = app.state::<AppState>().workspace.clone();
        let Ok(alerts) = run(&ws, |ws| ws.take_due_alerts(now_ms())).await else { continue };
        if alerts.is_empty() {
            continue;
        }
        let (title, body) = match alerts.as_slice() {
            [one] => (if one.item_type == "todo" { "待办提醒" } else { "稍后提醒" }.to_string(), one.title.clone()),
            many => (format!("{} 条提醒", many.len()), many.iter().take(4).map(|a| a.title.as_str()).collect::<Vec<_>>().join("\n")),
        };
        let _ = app.notification().builder().title(title).body(body).show();
        let _ = app.emit(INBOX_EVENT, ());
    }
}
