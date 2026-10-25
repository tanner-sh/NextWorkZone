//! Wiki 动态的临时只读桥，已读状态由 Swift 的新数据库管理。
use chrono::{DateTime, FixedOffset, Local};
use nextworkzone_core::Result;
use nextworkzone_jira::{ActivityEvent, parse_time};
use crate::state::AppState;

pub async fn bridge_wiki_activity(state: &AppState, since: String, first: bool) -> Result<Vec<ActivityEvent>> {
    let cutoff = DateTime::parse_from_rfc3339(&since).map_err(|e| nextworkzone_core::Error::Other(e.to_string()))?;
    wiki_events_since(state, cutoff, first, Local::now().fixed_offset()).await
}

async fn wiki_events_since(state: &AppState, cutoff: DateTime<FixedOffset>, first: bool, now: DateTime<FixedOffset>) -> Result<Vec<ActivityEvent>> {
    let confluence = state.confluence()?;
    let (me, _) = state.wiki_me().await?;
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
