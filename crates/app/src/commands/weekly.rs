//! 周报尚未迁移的 GitLab 数据来源，汇总与编辑已由 Swift 处理。
use chrono::{DateTime, Duration, FixedOffset, Local, NaiveDate};
use nextworkzone_core::{Error, Result};
use nextworkzone_gitlab::links;
use serde::Serialize;
use crate::state::AppState;

pub async fn bridge_weekly_gitlab(state: &AppState, from: String, to: String) -> Result<Vec<CodeWork>> {
    let from = NaiveDate::parse_from_str(&from, "%Y-%m-%d").map_err(|_| Error::Other("日期无效".into()))?;
    let to = NaiveDate::parse_from_str(&to, "%Y-%m-%d").map_err(|_| Error::Other("日期无效".into()))?;
    gitlab_work(state, from, to).await
}

fn local_start(day: NaiveDate) -> Result<DateTime<FixedOffset>> {
    day.and_hms_opt(0, 0, 0)
        .and_then(|t| t.and_local_timezone(Local).single())
        .map(|t| t.fixed_offset())
        .ok_or_else(|| Error::Other("日期无效".into()))
}

#[derive(Serialize)]
pub struct CodeWork {
    /// `push` / `mr_open` / `mr_merge` / `mr_approve` / `comment`
    kind: String,
    keys: Vec<String>,
    project: String,
    evidence: String,
    standalone: Option<String>,
}

async fn gitlab_work(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<Vec<CodeWork>> {
    let Ok(gitlab) = state.gitlab() else { return Ok(Vec::new()) };
    // GitLab 按 UTC 日期过滤，前后各多查一天，再按本地时间筛选
    let events = gitlab.my_events(&(from - Duration::days(2)).to_string(), &(to + Duration::days(2)).to_string()).await?;
    let (start, end) = (local_start(from)?, local_start(to + Duration::days(1))?);
    let events: Vec<_> = events
        .into_iter()
        .filter(|e| DateTime::parse_from_rfc3339(&e.at).is_ok_and(|t| t >= start && t < end))
        .collect();
    let names = super::worklog::project_names(&gitlab, events.iter().map(|e| e.project_id)).await;
    let is_merge = |t: &str| t.starts_with("Merge branch") || t.starts_with("Merge remote");
    Ok(events
        .into_iter()
        .filter_map(|e| {
            let project = names.get(&e.project_id).cloned().unwrap_or_default();
            let keys = links::issue_keys(&format!("{} {}", e.title, e.detail));
            let mr = e.iid.map(|i| format!("!{i}")).unwrap_or_default();
            let (evidence, standalone) = match e.kind.as_str() {
                "push" => (
                    format!("推送 {} 个提交到 {}", e.commit_count.max(1), e.title),
                    Some(e.detail.trim().to_string()).filter(|t| !t.is_empty() && !is_merge(t)),
                ),
                "mr_open" => (format!("发起合并请求 {mr}"), Some(format!("发起合并请求：{}", e.title))),
                "mr_merge" => (format!("合并 {mr}"), Some(format!("合并：{}", e.title))),
                "mr_approve" => (format!("批准 {mr}"), Some(format!("审核合并请求：{}", e.title))),
                "comment" => (format!("在 {mr} 中评论"), None),
                _ => return None,
            };
            Some(CodeWork { kind: e.kind, keys, project, evidence, standalone })
        })
        .collect())
}
