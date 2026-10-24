use std::collections::BTreeSet;

use chrono::{DateTime, Duration, FixedOffset, Local, NaiveDate};
use nextworkzone_confluence::report::{self, PastItem};
use nextworkzone_confluence::weekly::{self, OutlineItem};
use nextworkzone_gitlab::links;
use nextworkzone_confluence::{SaveResult, WeeklyView};
use nextworkzone_core::{Error, Result};
use serde::{Deserialize, Serialize};

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

pub async fn weekly_load(state: &AppState, section: Option<String>) -> Result<WeeklyView> {
    let page_id = page_id(state)?;
    let name = person_name(state).await?;
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

pub async fn weekly_save(state: &AppState, input: SaveInput) -> Result<SaveResult> {
    let page_id = page_id(state)?;
    let name = person_name(state).await?;
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
pub async fn weekly_create_week(state: &AppState) -> Result<WeeklyView> {
    let page_id = page_id(state)?;
    let name = person_name(state).await?;
    let confluence = state.confluence()?;
    let title = confluence.weekly_create_week(&page_id, today()).await?;
    confluence.weekly_load(&page_id, &name, Some(&title), today()).await
}


// ---------- 草稿 ----------
//
// 以“一件事”为单位：一个 Jira 问题是一条，这一周在 GitLab 上的推送、合并请求，完成的待办只要提到了这个问题，
// 都作为它的依据显示，不再单独成条。条目按往周的分组和进度写法组织，并与上周对比。

/// 学习分组标题、进度写法时参考的往周数。
const HISTORY_WEEKS: usize = 4;
/// 没有问题键的提交说明与问题概要的相似度至少为这个值，且明显高于第二相近的问题时，作为该问题的依据（推测）。
const GUESS_COMMIT: f64 = 0.2;
const GUESS_MARGIN: f64 = 1.5;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftItem {
    /// 插入周报的文字，例如“修复导入 --100%”。
    text: String,
    /// 对应的 Jira 问题。
    key: Option<String>,
    /// 依据：流转、评论、推送、合并请求、完成的待办等。
    evidence: Vec<String>,
    /// 上周周报中同一件事的进度。
    last_week: Option<String>,
}

impl DraftItem {
    fn plain(text: String) -> Self {
        DraftItem { text, key: None, evidence: Vec::new(), last_week: None }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftGroup {
    title: String,
    /// `jira` / `worklog` / `gitlab` / `wiki` / `todo` / `daily`
    source: &'static str,
    items: Vec<DraftItem>,
}

/// 上周没有完成的条目。
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CarryOver {
    group: String,
    text: String,
    progress: Option<String>,
    /// 本周草稿中对应的条目；为空表示这一周没有找到相关记录。
    this_week: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Draft {
    from: String,
    to: String,
    groups: Vec<DraftGroup>,
    carry_over: Vec<CarryOver>,
    /// 上周周报所在的小节。
    last_week_title: Option<String>,
    /// 往周使用的进度写法，例如 ` --`。
    separator: String,
    /// 某个数据源不可用时的提示。
    notes: Vec<String>,
}

/// 往周周报：上周的条目、近几周的分组标题和进度写法。
#[derive(Default)]
struct History {
    last_title: Option<String>,
    last: Vec<PastItem>,
    all: Vec<PastItem>,
    groups: Vec<String>,
    separator: String,
}

async fn history(state: &AppState, section: &str) -> Result<History> {
    let page_id = page_id(state)?;
    let name = person_name(state).await?;
    let weeks = state.confluence()?.weekly_history(&page_id, &name, section, today(), HISTORY_WEEKS).await?;
    let contents: Vec<Vec<OutlineItem>> = weeks.iter().map(|w| w.content.clone()).collect();
    Ok(History {
        last_title: weeks.first().map(|w| w.section_title.clone()),
        last: weeks.first().map(|w| report::past_items(&w.content)).unwrap_or_default(),
        all: contents.iter().flat_map(|c| report::past_items(c)).collect(),
        groups: report::past_groups(&contents),
        separator: report::past_separator(&contents),
    })
}

/// 根据这一周经手的 Jira 问题、GitLab 上的操作、Wiki 页面、完成的待办和日记生成周报草稿。
pub async fn weekly_draft(state: &AppState, section: Option<String>) -> Result<Draft> {
    let today = today();
    let (from, to) = section
        .as_deref()
        .and_then(|s| weekly::parse_range(s, today))
        .unwrap_or_else(|| {
            let monday = today - Duration::days(chrono::Datelike::weekday(&today).num_days_from_monday() as i64);
            (monday, monday + Duration::days(6))
        });
    let mut notes = Vec::new();
    let (past, jira, worklogs, gitlab, wiki) = tokio::join!(
        async {
            match &section {
                Some(s) => history(state, s).await,
                None => Ok(History::default()),
            }
        },
        jira_work(state, from, to),
        worklog_draft(state, from, to),
        gitlab_work(state, from, to),
        wiki_draft(state, from, to)
    );
    let mut past = past.unwrap_or_else(|e| {
        notes.push(format!("往周周报：{e}"));
        History::default()
    });
    if past.separator.is_empty() {
        past.separator = report::DEFAULT_SEPARATOR.into();
    }
    let mut issues = jira.unwrap_or_else(|e| {
        notes.push(format!("Jira：{e}"));
        Vec::new()
    });
    let gitlab = gitlab.unwrap_or_else(|e| {
        notes.push(format!("GitLab：{e}"));
        Vec::new()
    });

    // GitLab 上提到问题键的操作并入对应的问题；没有问题键的提交按内容并入最相近的问题（注明是推测）
    let mut code: Vec<(String, String)> = Vec::new();
    for event in gitlab {
        if let Some(issue) = issues.iter_mut().find(|i| event.keys.contains(&i.key)) {
            push_unique(&mut issue.evidence, event.evidence);
            continue;
        }
        let Some(text) = event.standalone else { continue };
        let guess = if event.kind == "push" { guess_issue(&text, &issues) } else { None };
        match guess {
            Some(i) => push_unique(&mut issues[i].evidence, format!("提交（按内容推测）：{text}")),
            None => code.push((event.project, text)),
        }
    }

    // 完成的待办：关联了问题的并入问题
    let (todo_done, daily) = match workspace_work(state, from, to) {
        Ok(found) => found,
        Err(e) => {
            notes.push(format!("工作空间：{e}"));
            (Vec::new(), Vec::new())
        }
    };
    let mut todos: Vec<String> = Vec::new();
    for (title, key) in todo_done {
        match key.and_then(|k| issues.iter_mut().find(|i| i.key == k)) {
            Some(issue) => push_unique(&mut issue.evidence, format!("完成待办：{title}")),
            None => todos.push(title),
        }
    }

    // Jira 问题按往周的分组归类，没有对应分组的按项目
    let mut groups: Vec<DraftGroup> = Vec::new();
    for issue in issues.drain(..) {
        let group = report::guess_group(&issue.summary, &past.all, &past.groups).unwrap_or_else(|| issue.project.clone());
        let last_week = report::find_same(&issue.summary, &past.last).and_then(|p| p.progress.clone());
        let item = DraftItem { text: format!("{}{}{}", issue.summary, past.separator, issue.progress), key: Some(issue.key), evidence: issue.evidence, last_week };
        add_item(&mut groups, &group, "jira", item);
    }
    // 往周用过的分组排在前面，按往周的顺序
    groups.sort_by_key(|g| past.groups.iter().position(|t| *t == g.title).unwrap_or(usize::MAX));

    match worklogs {
        Ok(g) => groups.extend(g),
        Err(e) => notes.push(format!("工作日志：{e}")),
    }
    for (project, text) in code {
        add_item(&mut groups, &project, "gitlab", DraftItem::plain(text));
    }
    match wiki {
        Ok(g) => groups.extend(g),
        Err(e) => notes.push(format!("Wiki：{e}")),
    }
    if !todos.is_empty() {
        groups.push(DraftGroup { title: "完成的待办".into(), source: "todo", items: todos.into_iter().map(DraftItem::plain).collect() });
    }
    if !daily.is_empty() {
        groups.push(DraftGroup { title: "日记".into(), source: "daily", items: daily.into_iter().map(DraftItem::plain).collect() });
    }

    // 上周没完成的事，这一周有没有进展
    let this_week: Vec<PastItem> = groups
        .iter()
        .filter(|g| g.source == "jira")
        .flat_map(|g| g.items.iter())
        .map(|i| {
            let (text, progress) = report::split_progress(&i.text);
            PastItem { group: String::new(), text: text.to_string(), progress: progress.map(str::to_string) }
        })
        .collect();
    let carry_over = past
        .last
        .iter()
        .filter(|p| !report::is_finished(p.progress.as_deref()))
        .map(|p| CarryOver {
            group: p.group.clone(),
            text: p.text.clone(),
            progress: p.progress.clone(),
            this_week: report::find_same(&p.text, &this_week).map(|i| match &i.progress {
                Some(progress) => format!("{}{}{progress}", i.text, past.separator),
                None => i.text.clone(),
            }),
        })
        .collect();

    Ok(Draft { from: from.to_string(), to: to.to_string(), groups, carry_over, last_week_title: past.last_title, separator: past.separator, notes })
}

/// 与提交说明最相近的问题：相似度足够高，并且明显高于第二相近的问题。
fn guess_issue(text: &str, issues: &[IssueWork]) -> Option<usize> {
    let mut scores: Vec<(f64, usize)> = issues.iter().enumerate().map(|(i, issue)| (report::similarity(text, &issue.summary), i)).collect();
    scores.sort_by(|a, b| b.0.total_cmp(&a.0));
    let (best, index) = *scores.first()?;
    let second = scores.get(1).map_or(0.0, |s| s.0);
    (best >= GUESS_COMMIT && best >= second * GUESS_MARGIN).then_some(index)
}

fn push_unique(list: &mut Vec<String>, text: String) {
    if !list.contains(&text) {
        list.push(text);
    }
}

fn add_item(groups: &mut Vec<DraftGroup>, title: &str, source: &'static str, item: DraftItem) {
    match groups.iter_mut().find(|g| g.title == title && g.source == source) {
        Some(g) => {
            if !g.items.iter().any(|i| i.text == item.text) {
                g.items.push(item);
            }
        }
        None => groups.push(DraftGroup { title: title.to_string(), source, items: vec![item] }),
    }
}

/// 这一周经手的一个 Jira 问题。
struct IssueWork {
    key: String,
    summary: String,
    project: String,
    /// 已完成的为 100%，否则为状态名称。
    progress: String,
    evidence: Vec<String>,
}

fn local_start(day: NaiveDate) -> Result<DateTime<FixedOffset>> {
    day.and_hms_opt(0, 0, 0)
        .and_then(|t| t.and_local_timezone(Local).single())
        .map(|t| t.fixed_offset())
        .ok_or_else(|| Error::Other("日期无效".into()))
}

/// 这一周分配给我且有更新、或由我操作过（创建、流转、评论）的问题，附带我的操作。
async fn jira_work(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<Vec<IssueWork>> {
    let Ok(jira) = state.jira() else { return Ok(Vec::new()) };
    let me = state.jira_username().await?;
    let end = to + Duration::days(1);
    let jql = format!(
        "((assignee = currentUser() AND updated >= \"{from}\" AND updated < \"{end}\") \
         OR status CHANGED BY currentUser() DURING (\"{from}\", \"{end}\")) ORDER BY project, updated DESC"
    );
    let (from_day, end_day) = (from.to_string(), end.to_string());
    let (found, actions) = tokio::join!(jira.search(&jql, 0, 100), jira.my_actions(&me, &from_day, &end_day, local_start(from)?, local_start(end)?));
    let mut issues = found?.issues;
    let actions = actions.unwrap_or_default();

    // 只在操作记录中出现的问题（例如评论了别人的问题）补查状态
    let missing: Vec<String> = actions.iter().map(|a| a.key.clone()).filter(|k| !issues.iter().any(|i| &i.key == k)).collect::<BTreeSet<_>>().into_iter().collect();
    if !missing.is_empty()
        && let Ok(more) = jira.search(&format!("key in ({}) ORDER BY project, updated DESC", missing.join(",")), 0, 100).await
    {
        issues.extend(more.issues);
    }

    Ok(issues
        .into_iter()
        .map(|issue| {
            let mine: Vec<_> = actions.iter().filter(|a| a.key == issue.key).collect();
            let mut evidence = Vec::new();
            if mine.iter().any(|a| a.kind == "create") {
                evidence.push("创建".to_string());
            }
            // 连续的流转连成一条：A → B → C
            let mut chain: Vec<String> = Vec::new();
            for a in mine.iter().filter(|a| a.kind == "transition") {
                let mut parts = a.detail.split(" → ");
                let (Some(from), Some(to)) = (parts.next(), parts.next()) else { continue };
                if chain.last().map(String::as_str) != Some(from) {
                    if !chain.is_empty() {
                        evidence.push(format!("流转：{}", chain.join(" → ")));
                    }
                    chain = vec![from.to_string()];
                }
                chain.push(to.to_string());
            }
            if chain.len() > 1 {
                evidence.push(format!("流转：{}", chain.join(" → ")));
            }
            let comments = mine.iter().filter(|a| a.kind == "comment").count();
            if comments > 0 {
                evidence.push(format!("评论 {comments} 条"));
            }
            IssueWork {
                progress: if issue.status.category == "done" { "100%".to_string() } else { issue.status.name.clone() },
                key: issue.key,
                summary: issue.summary.trim().to_string(),
                project: issue.project.name,
                evidence,
            }
        })
        .collect())
}

/// GitLab 上的一次操作：提到的问题键、作为问题依据时的说明，以及没有对应问题时单独列出的文字。
struct CodeWork {
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

/// 这一周登记的工作日志：每个问题一条，带耗时合计和日志说明。
async fn worklog_draft(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<Vec<DraftGroup>> {
    let Ok(jira) = state.jira() else { return Ok(Vec::new()) };
    let me = state.jira_username().await?;
    let logs = jira.my_worklogs(&me, &from.to_string(), &to.to_string()).await?;
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
            DraftItem { key: Some(issue.key.clone()), ..DraftItem::plain(format!("{}（{}）{detail}", issue.summary, format_duration(seconds))) }
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
    let mut items: Vec<DraftItem> = Vec::new();
    for w in work.into_iter().filter(|w| w.kind != "comment" && w.page_id != weekly_page) {
        let line = if w.kind == "create" { format!("新建 Wiki 页面：{}", w.title) } else { format!("更新 Wiki 页面：{}", w.title) };
        if !items.iter().any(|i| i.text.ends_with(&format!("：{}", w.title))) {
            items.push(DraftItem::plain(line));
        }
    }
    Ok(if items.is_empty() { Vec::new() } else { vec![DraftGroup { title: "Wiki".into(), source: "wiki", items }] })
}

/// 完成的待办：标题和关联的问题键。
type DoneTodo = (String, Option<String>);

/// 工作空间：这一周手动完成的待办（Jira 同步来的待办除外），以及日记中的内容。
fn workspace_work(state: &AppState, from: NaiveDate, to: NaiveDate) -> Result<(Vec<DoneTodo>, Vec<String>)> {
    let ws = &state.workspace;
    let start = local_start(from)?.timestamp_millis();
    let end = local_start(to + Duration::days(1))?.timestamp_millis();
    let todos = ws
        .todos()?
        .into_iter()
        .filter(|t| t.done && !t.auto_done && t.source.as_deref() != Some("jira"))
        .filter(|t| t.completed_at.is_some_and(|at| at >= start && at < end))
        .filter(|t| !t.title.trim().is_empty())
        .map(|t| (t.title, t.ref_key.filter(|_| t.ref_system.as_deref() == Some("jira"))))
        .collect();
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
    Ok((todos, lines))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn issue(summary: &str) -> IssueWork {
        IssueWork { key: String::new(), summary: summary.into(), project: String::new(), progress: String::new(), evidence: Vec::new() }
    }

    #[test]
    fn guesses_issue_of_commit_only_when_clear() {
        let issues = vec![issue("客户甲新增订单类型-线上团购订单"), issue("库存月报需将冻结库存与可用库存合并统计"), issue("用户导出报错")];
        assert_eq!(guess_issue("新增线上团购订单类型并设置结算方向", &issues), Some(0));
        assert_eq!(guess_issue("修复库存月报冻结库存解冻后数量计算", &issues), Some(1));
        assert_eq!(guess_issue("忽略编辑器配置目录", &issues), None);
        // 两个问题同样相近时不猜
        let twins = vec![issue("定时任务执行器报错"), issue("定时任务执行器并发执行")];
        assert_eq!(guess_issue("定时任务执行器", &twins), None);
    }
}
