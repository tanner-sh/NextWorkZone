//! 动态：与我有关的问题上，别人新加的评论、状态变化、分配、字段修改，以及提到我的评论。
//! Jira Server 没有通知接口，做法是查询最近更新过的问题，再从评论和变更记录中找出检查时间之后的变化。

use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::fields::value_text;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ActivityEvent {
    /// 问题键 + 来源（评论 id、变更记录 id），用于去重。
    pub id: String,
    pub issue_key: String,
    pub issue_summary: String,
    pub issue_type_icon: Option<String>,
    /// `comment` / `mention` / `status` / `assigned` / `field` / `created`；
    /// Wiki 的动态另有 `edit` / `share` / `task` / `like` / `other`。
    pub kind: String,
    /// 操作人（显示名）。
    pub actor: String,
    pub at: String,
    /// 评论摘要、状态变化“A → B”、修改的字段等。
    pub text: String,
    #[serde(default)]
    pub read: bool,
    /// `jira` / `wiki`。Wiki 动态的 `issue_key` 是页面 id，`issue_summary` 是页面标题。
    #[serde(default = "jira_system")]
    pub system: String,
}

fn jira_system() -> String {
    "jira".into()
}

/// 只看与我有关的问题：经办、报告、关注，或在评论中提到我。
pub fn activity_jql(me: &str, since: &str) -> String {
    let me = crate::jql_escape(me);
    format!(
        "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser() OR text ~ \"{me}\") AND updated >= \"{since}\" ORDER BY updated DESC"
    )
}

/// 解析 Jira 时间，例如 `2026-10-22T17:32:09.000+0800`。
pub fn parse_time(s: &str) -> Option<DateTime<FixedOffset>> {
    DateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f%z").ok()
}

const EXCERPT_CHARS: usize = 160;

/// 从一个问题（带 `comment` 字段和 `changelog`）中找出 `since` 之后别人造成的变化。
pub fn events_from_issue(issue: &Value, me: &str, since: DateTime<FixedOffset>) -> Vec<ActivityEvent> {
    let key = value_text(&issue["key"]);
    let fields = &issue["fields"];
    let summary = value_text(&fields["summary"]);
    let icon = fields["issuetype"]["iconUrl"].as_str().map(str::to_string);
    let after = |at: &str| parse_time(at).is_some_and(|t| t > since);
    let event = |id: String, kind: &str, actor: &Value, at: &str, text: String| ActivityEvent {
        id,
        issue_key: key.clone(),
        issue_summary: summary.clone(),
        issue_type_icon: icon.clone(),
        kind: kind.to_string(),
        actor: value_text(&actor["displayName"]),
        at: at.to_string(),
        text,
        read: false,
        system: jira_system(),
    };
    let by_me = |user: &Value| user["name"].as_str() == Some(me);
    let mut events = Vec::new();

    let created = value_text(&fields["created"]);
    if after(&created) && !by_me(&fields["reporter"]) {
        let text = if fields["assignee"]["name"].as_str() == Some(me) { "创建了问题，并分配给你".to_string() } else { "创建了问题".to_string() };
        events.push(event(format!("{key}:created"), "created", &fields["reporter"], &created, text));
    }

    for c in fields["comment"]["comments"].as_array().into_iter().flatten() {
        let at = value_text(&c["created"]);
        if !after(&at) || by_me(&c["author"]) {
            continue;
        }
        let body = value_text(&c["body"]);
        let kind = if body.contains(&format!("[~{me}]")) { "mention" } else { "comment" };
        events.push(event(format!("{key}:c:{}", value_text(&c["id"])), kind, &c["author"], &at, excerpt(&body)));
    }

    for h in issue["changelog"]["histories"].as_array().into_iter().flatten() {
        let at = value_text(&h["created"]);
        if !after(&at) || by_me(&h["author"]) {
            continue;
        }
        let id = format!("{key}:h:{}", value_text(&h["id"]));
        let items: Vec<&Value> = h["items"].as_array().into_iter().flatten().collect();
        let change = |it: &Value| format!("{} → {}", text_or(&it["fromString"], "无"), text_or(&it["toString"], "无"));
        if let Some(status) = items.iter().find(|it| it["field"] == "status") {
            events.push(event(id, "status", &h["author"], &at, change(status)));
        } else if let Some(assignee) = items.iter().find(|it| it["field"] == "assignee") {
            let to_me = assignee["to"].as_str() == Some(me);
            let text = if to_me { "分配给你".to_string() } else { format!("经办人：{}", change(assignee)) };
            events.push(event(id, if to_me { "assigned" } else { "field" }, &h["author"], &at, text));
        } else if !items.is_empty() {
            let text = items.iter().map(|it| format!("{}：{}", value_text(&it["field"]), change(it))).collect::<Vec<_>>().join("；");
            events.push(event(id, "field", &h["author"], &at, text));
        }
    }
    events
}

fn text_or(v: &Value, fallback: &str) -> String {
    let s = value_text(v);
    if s.trim().is_empty() { fallback.to_string() } else { s }
}

/// 评论摘要：去掉引用、图片等 wiki 标记，`[~用户名]` 显示为 @用户名。
fn excerpt(body: &str) -> String {
    let mut text = String::new();
    let mut in_quote = false;
    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("{quote}") || trimmed.ends_with("{quote}") {
            // 单行的 {quote}xxx{quote} 也跳过
            if !(trimmed.len() > 14 && trimmed.starts_with("{quote}") && trimmed.ends_with("{quote}")) {
                in_quote = !in_quote;
            }
            continue;
        }
        if in_quote || trimmed.starts_with("bq.") {
            continue;
        }
        if !text.is_empty() {
            text.push(' ');
        }
        text.push_str(trimmed);
    }
    let text = strip_markup(&text);
    let mut chars = text.chars();
    let short: String = chars.by_ref().take(EXCERPT_CHARS).collect();
    if chars.next().is_some() { format!("{short}…") } else { short }
}

fn strip_markup(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find(['[', '!']) {
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        let close = if tail.starts_with('[') { ']' } else { '!' };
        match tail[1..].find(close) {
            // 图片 !xxx.png! 去掉；[~user] → @user；[文字|链接] → 文字
            Some(end) if !tail[1..1 + end].contains(' ') || close == ']' => {
                let inner = &tail[1..1 + end];
                if close == ']' {
                    if let Some(user) = inner.strip_prefix('~') {
                        out.push('@');
                        out.push_str(user);
                    } else {
                        out.push_str(inner.split('|').next().unwrap_or(inner));
                    }
                }
                rest = &tail[end + 2..];
            }
            _ => {
                out.push_str(&tail[..1]);
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out.replace(['*', '{', '}'], "").split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn since() -> DateTime<FixedOffset> {
        parse_time("2026-10-22T10:00:00.000+0800").unwrap()
    }

    fn user(name: &str) -> Value {
        json!({ "name": name, "displayName": name.to_uppercase() })
    }

    #[test]
    fn finds_changes_by_others_after_since() {
        let issue = json!({
            "key": "A-1",
            "fields": {
                "summary": "概要", "issuetype": { "iconUrl": "i.png" },
                "created": "2026-10-01T09:00:00.000+0800", "reporter": user("bob"), "assignee": user("me"),
                "comment": { "comments": [
                    { "id": "1", "author": user("bob"), "created": "2026-10-21T09:00:00.000+0800", "body": "旧评论" },
                    { "id": "2", "author": user("bob"), "created": "2026-10-22T11:00:00.000+0800", "body": "请看 [~me] 这个 !image.png!" },
                    { "id": "3", "author": user("me"), "created": "2026-10-22T12:00:00.000+0800", "body": "我自己的" },
                    { "id": "4", "author": user("amy"), "created": "2026-10-22T12:30:00.000+0800", "body": "{quote}\n原文\n{quote}\n同意" }
                ]}
            },
            "changelog": { "histories": [
                { "id": "10", "author": user("bob"), "created": "2026-10-22T13:00:00.000+0800", "items": [
                    { "field": "status", "fromString": "处理中", "toString": "已解决" },
                    { "field": "resolution", "fromString": null, "toString": "已修复" }
                ]},
                { "id": "11", "author": user("bob"), "created": "2026-10-22T13:01:00.000+0800", "items": [
                    { "field": "assignee", "fromString": "BOB", "toString": "ME", "to": "me" }
                ]},
                { "id": "12", "author": user("amy"), "created": "2026-10-22T13:02:00.000+0800", "items": [
                    { "field": "截止日期", "fromString": "2026-10-21", "toString": "2026-10-27" }
                ]},
                { "id": "13", "author": user("me"), "created": "2026-10-22T13:03:00.000+0800", "items": [
                    { "field": "status", "fromString": "已解决", "toString": "关闭" }
                ]}
            ]}
        });
        let events = events_from_issue(&issue, "me", since());
        let summary: Vec<(&str, &str, &str)> = events.iter().map(|e| (e.id.as_str(), e.kind.as_str(), e.text.as_str())).collect();
        assert_eq!(
            summary,
            vec![
                ("A-1:c:2", "mention", "请看 @me 这个"),
                ("A-1:c:4", "comment", "同意"),
                ("A-1:h:10", "status", "处理中 → 已解决"),
                ("A-1:h:11", "assigned", "分配给你"),
                ("A-1:h:12", "field", "截止日期：2026-10-21 → 2026-10-27"),
            ]
        );
        assert_eq!(events[0].actor, "BOB");
    }

    #[test]
    fn reports_new_issue_assigned_to_me() {
        let issue = json!({
            "key": "A-2",
            "fields": { "summary": "新问题", "created": "2026-10-22T11:00:00.000+0800", "reporter": user("bob"), "assignee": user("me"), "comment": { "comments": [] } },
            "changelog": { "histories": [] }
        });
        let events = events_from_issue(&issue, "me", since());
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].text, "创建了问题，并分配给你");
    }

    #[test]
    fn excerpts_are_short_and_plain() {
        assert_eq!(excerpt("*重要* 见 [文档|http://x] 和 [~bob]"), "重要 见 文档 和 @bob");
        assert!(excerpt(&"字".repeat(300)).ends_with('…'));
    }
}
