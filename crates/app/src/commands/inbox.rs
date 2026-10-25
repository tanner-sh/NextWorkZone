//! 需要处理的事（今天页的“需要处理”，内部仍沿用“收件箱”的名字）：动态（提到我、分配给我、评论等）、
//! 逾期或今天到期的问题、请我审核或指派给我的合并请求。随手记下的内容直接成为待办，不在这里。
//!
//! 外部条目每次实时汇总，工作空间中只记录“已处理”“稍后提醒”的状态（随工作空间同步）：
//! 动态在处理之后有新的动态、合并请求在处理之后有更新、到期问题到了第二天仍未解决时，条目重新出现。
//! 另有后台循环在提醒时间到达时发送系统通知（待办的提醒时间、收件箱的稍后提醒）。

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use nextworkzone_core::Result;
use nextworkzone_gitlab::{MergeRequest, MrQuery, MrScope};
use nextworkzone_jira::ActivityEvent;
use nextworkzone_workspace::InboxEntry;
use serde::{Deserialize, Serialize};

use crate::state::AppState;

/// 收件箱有变化（提醒到时、其他窗口记下内容）时发给前端的事件。
/// 需要处理的动态类型；字段修改、Wiki 页面修改、点赞等只在动态页中查看。
/// 合并请求列表的缓存时间，收件箱计数会定期刷新，不必每次都请求 GitLab。
const MR_CACHE: Duration = Duration::from_secs(120);

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
    /// `activity` 动态 / `due` 到期问题 / `mr` 合并请求
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

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

pub async fn bridge_inbox_sources(state: &AppState) -> Result<InboxView> {
    let entries: BTreeMap<String, InboxEntry> = BTreeMap::new();
    let mut items: Vec<InboxItem> = Vec::new();
    let mut notes = Vec::new();

    let mrs = mr_items(&state, &entries).await;
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
/// 请我审核、指派给我的未合并的合并请求（我自己发起的除外）；处理后有更新时再次出现。
async fn mr_items(state: &&AppState, entries: &BTreeMap<String, InboxEntry>) -> Result<Vec<InboxItem>> {
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
