//! 动态：定期查询 Jira 和 Wiki 上与我有关的变化，保存在本机缓存中，记录已读状态。
//!
//! Wiki 的动态有两个来源：Confluence 工作箱中的通知（评论、提到、分享、任务），
//! 以及我关注或创建的页面被别人修改（周报页面和设置中屏蔽的页面除外）。

use chrono::{DateTime, Duration, FixedOffset, Local};
use nextworkzone_core::Result;
use nextworkzone_jira::{ActivityEvent, parse_time};
use serde::{Deserialize, Serialize};
use tauri::State;
use tokio::sync::Mutex;

use crate::state::AppState;

const STORE_KEY: &str = "jira:activity";
/// 最多保留的动态条数。
const KEEP: usize = 300;
/// 第一次检查时回看的天数（这些动态直接标为已读，不发通知）。
const FIRST_LOOKBACK_DAYS: i64 = 3;
/// Jira 建索引有延迟，每次检查都多看几分钟，重复的按 id 去掉。
const OVERLAP_MINUTES: i64 = 5;

/// 同一时间只做一次检查，避免两次检查互相覆盖已读状态。
static POLLING: Mutex<()> = Mutex::const_new(());

#[derive(Debug, Default, Serialize, Deserialize)]
struct Store {
    last_check: Option<String>,
    /// Wiki 单独记录检查时间：Wiki 晚于 Jira 配置时，第一次检查同样只回看几天并标为已读。
    #[serde(default)]
    wiki_last_check: Option<String>,
    events: Vec<ActivityEvent>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityFeed {
    events: Vec<ActivityEvent>,
    unread: usize,
    last_check: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityPoll {
    feed: ActivityFeed,
    /// 本次新发现的动态（用于发通知）；第一次检查时为空。
    fresh: Vec<ActivityEvent>,
}

impl Store {
    fn load(state: &AppState) -> Self {
        state.cache.get(STORE_KEY).unwrap_or_default()
    }

    fn save(&self, state: &AppState) {
        state.cache.put(STORE_KEY, self);
    }

    fn feed(&self) -> ActivityFeed {
        ActivityFeed {
            events: self.events.clone(),
            unread: self.events.iter().filter(|e| !e.read).count(),
            last_check: self.last_check.clone(),
        }
    }
}

fn time_of(e: &ActivityEvent) -> Option<DateTime<FixedOffset>> {
    parse_time(&e.at).or_else(|| DateTime::parse_from_rfc3339(&e.at).ok())
}

/// 已保存的动态（收件箱据此汇总需要处理的条目）。
pub(crate) fn stored_events(state: &AppState) -> Vec<ActivityEvent> {
    Store::load(state).events
}

/// 动态发生的时间（毫秒）。
pub(crate) fn event_ms(e: &ActivityEvent) -> i64 {
    time_of(e).map_or(0, |t| t.timestamp_millis())
}

#[tauri::command]
pub fn jira_activity(state: State<'_, AppState>) -> ActivityFeed {
    Store::load(&state).feed()
}

#[tauri::command]
pub async fn jira_activity_poll(state: State<'_, AppState>) -> Result<ActivityPoll> {
    let _guard = POLLING.lock().await;
    let mut store = Store::load(&state);
    let now = Local::now().fixed_offset();
    let mut fresh: Vec<ActivityEvent> = Vec::new();
    let mut errors: Vec<String> = Vec::new();
    let mut succeeded = 0;

    if state.jira().is_ok() {
        match jira_events(&state, store.last_check.as_deref(), now).await {
            Ok(found) => {
                fresh.extend(found);
                store.last_check = Some(now.to_rfc3339());
                succeeded += 1;
            }
            Err(e) => errors.push(format!("Jira：{e}")),
        }
    }
    if state.confluence().is_ok() && state.config().wiki_tools.activity {
        match wiki_events(&state, store.wiki_last_check.as_deref(), now).await {
            Ok(found) => {
                fresh.extend(found);
                store.wiki_last_check = Some(now.to_rfc3339());
                succeeded += 1;
            }
            Err(e) => errors.push(format!("Wiki：{e}")),
        }
    }
    // 只有一个系统失败时照常显示另一个的动态
    if succeeded == 0 && !errors.is_empty() {
        return Err(nextworkzone_core::Error::Other(errors.join("；")));
    }

    let fresh: Vec<ActivityEvent> = fresh.into_iter().filter(|e| !store.events.iter().any(|x| x.id == e.id)).collect();
    store.events.extend(fresh.iter().cloned());
    store.events.sort_by_key(|e| std::cmp::Reverse(time_of(e)));
    store.events.truncate(KEEP);
    store.save(&state);
    Ok(ActivityPoll { feed: store.feed(), fresh: fresh.into_iter().filter(|e| !e.read).collect() })
}

/// 起始时间：上次检查之前几分钟；第一次检查时回看几天。
fn cutoff(last: Option<&str>, now: DateTime<FixedOffset>) -> (DateTime<FixedOffset>, bool) {
    match last.and_then(|s| DateTime::parse_from_rfc3339(s).ok()) {
        Some(t) => (t - Duration::minutes(OVERLAP_MINUTES), false),
        None => (now - Duration::days(FIRST_LOOKBACK_DAYS), true),
    }
}

async fn jira_events(state: &AppState, last: Option<&str>, now: DateTime<FixedOffset>) -> Result<Vec<ActivityEvent>> {
    let me = state.jira_username().await?;
    let (cutoff, first) = cutoff(last, now);
    // JQL 的时间只精确到分钟，按 Jira 用户的时区解释（通常与本机一致）
    let since = cutoff.with_timezone(&Local).format("%Y/%m/%d %H:%M").to_string();
    let mut found = state.jira()?.activity(&me, &since, cutoff).await?;
    // 第一次检查时找到的动态直接标为已读，不发通知
    if first {
        found.iter_mut().for_each(|e| e.read = true);
    }
    Ok(found)
}

async fn wiki_events(state: &AppState, last: Option<&str>, now: DateTime<FixedOffset>) -> Result<Vec<ActivityEvent>> {
    let confluence = state.confluence()?;
    let (me, _) = state.wiki_me().await?;
    let (cutoff, first) = cutoff(last, now);
    let config = state.config();
    let muted: Vec<String> = config.wiki_tools.muted_pages.iter().cloned().chain(Some(config.weekly.page_id.clone()).filter(|p| !p.is_empty())).collect();
    let mut found = Vec::new();

    for n in confluence.notifications().await? {
        if n.updated <= cutoff.timestamp_millis() {
            continue;
        }
        let at = chrono::DateTime::from_timestamp_millis(n.updated).map(|t| t.with_timezone(&Local).fixed_offset().to_rfc3339()).unwrap_or_default();
        let kind = match n.action.as_str() {
            "mention" | "comment" | "share" | "task" | "like" => n.action.clone(),
            _ => "other".into(),
        };
        found.push(ActivityEvent {
            id: format!("wiki:n:{}", n.id),
            issue_key: n.page_id.clone().unwrap_or_default(),
            issue_summary: if n.page_title.is_empty() { n.title.clone() } else { n.page_title.clone() },
            issue_type_icon: None,
            kind,
            actor: n.actor.clone(),
            at,
            text: if n.text.is_empty() { n.title.clone() } else { n.text.clone() },
            read: first,
            system: "wiki".into(),
        });
    }

    let minutes = (now - cutoff).num_minutes().max(1);
    for change in confluence.watched_changes(minutes).await? {
        if change.by_key == me || muted.contains(&change.id) {
            continue;
        }
        if parse_time_any(&change.when).is_some_and(|t| t <= cutoff) {
            continue;
        }
        found.push(ActivityEvent {
            id: format!("wiki:{}:v{}", change.id, change.version),
            issue_key: change.id.clone(),
            issue_summary: change.title.clone(),
            issue_type_icon: None,
            kind: "edit".into(),
            actor: change.by.clone(),
            at: change.when.clone(),
            text: if change.message.is_empty() { format!("第 {} 版", change.version) } else { format!("第 {} 版：{}", change.version, change.message) },
            read: first,
            system: "wiki".into(),
        });
    }
    Ok(found)
}

fn parse_time_any(s: &str) -> Option<DateTime<FixedOffset>> {
    DateTime::parse_from_rfc3339(s).ok().or_else(|| parse_time(s))
}

/// 标为已读；`ids` 为空时全部标为已读。
#[tauri::command]
pub async fn jira_activity_read(state: State<'_, AppState>, ids: Option<Vec<String>>) -> Result<ActivityFeed> {
    let _guard = POLLING.lock().await;
    let mut store = Store::load(&state);
    for e in &mut store.events {
        if ids.as_ref().is_none_or(|ids| ids.contains(&e.id)) {
            e.read = true;
        }
    }
    store.save(&state);
    Ok(store.feed())
}
