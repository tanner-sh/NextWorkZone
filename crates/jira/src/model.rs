use nextworkzone_core::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::fields::{display_fields, value_text};

// ---------- 对外（序列化给前端）的数据结构 ----------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub total: u32,
    pub issues: Vec<IssueSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueSummary {
    pub key: String,
    pub summary: String,
    pub status: Status,
    pub issue_type: Named,
    pub priority: Option<Named>,
    pub project: Named,
    pub assignee: Option<String>,
    /// 经办人的用户名（分配、判断是否分配给自己时使用）。
    #[serde(default)]
    pub assignee_name: Option<String>,
    pub reporter: Option<String>,
    /// 报告人的用户名（模板中提及报告人时使用）。
    #[serde(default)]
    pub reporter_name: Option<String>,
    /// 当前用户在 Jira 网页上最近一次查看的时间。
    #[serde(default)]
    pub last_viewed: Option<String>,
    /// 解决结果；未解决时为空。
    #[serde(default)]
    pub resolution: Option<String>,
    pub created: String,
    pub updated: String,
    pub due_date: Option<String>,
    /// 列表中额外显示的字段：字段 id → 文本。
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub extra: std::collections::BTreeMap<String, String>,
}

/// 可在列表中显示的字段。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldInfo {
    pub id: String,
    pub name: String,
    pub custom: bool,
    /// 字段类型，例如 `date`、`datetime`、`array`、`user`。
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub name: String,
    /// `new` / `indeterminate` / `done`，用于前端配色。
    pub category: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Named {
    pub name: String,
    pub icon_url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueDetail {
    /// 问题的数字 id（网页表单使用）。
    pub id: String,
    #[serde(flatten)]
    pub summary: IssueSummary,
    pub description_html: Option<String>,
    /// 其余有值的字段，按“系统字段在前、自定义字段按名称排序”的顺序。
    pub fields: Vec<DisplayField>,
    pub time_tracking: Option<TimeTracking>,
    pub parent: Option<IssueRef>,
    pub subtasks: Vec<IssueRef>,
    pub links: Vec<IssueLink>,
    pub attachments: Vec<Attachment>,
    pub comments: Vec<Comment>,
}

/// 详情中引用的其他问题（父任务、子任务、链接的问题）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueRef {
    pub key: String,
    pub summary: String,
    pub status: Option<Status>,
    pub issue_type: Option<Named>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeTracking {
    /// Jira 格式化后的时长，例如“2d 4h”。
    pub original_estimate: Option<String>,
    pub remaining_estimate: Option<String>,
    pub time_spent: Option<String>,
    pub original_estimate_seconds: Option<u64>,
    pub remaining_estimate_seconds: Option<u64>,
    pub time_spent_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayField {
    pub id: String,
    pub name: String,
    pub text: String,
    /// 多行文本字段渲染后的 HTML。
    pub html: Option<String>,
    /// 值是另一个问题（例如 Epic 链接）时为该问题的键，前端显示为链接。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub issue_key: Option<String>,
    /// 不在问题界面上的字段（网页上不显示，多为隐藏字段的默认值），默认收起。
    pub hidden: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueLink {
    /// 链接 id，删除链接时使用。
    pub id: String,
    /// 从当前问题看过去的关系描述，例如“阻塞”“被阻塞”。
    pub relation: String,
    #[serde(flatten)]
    pub issue: IssueRef,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkType {
    pub id: String,
    pub name: String,
    pub inward: String,
    pub outward: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Worklog {
    pub id: String,
    pub author: String,
    /// 是否当前用户记录的（只有自己的工作日志可以修改、删除）。
    pub mine: bool,
    pub started: String,
    pub time_spent: String,
    pub time_spent_seconds: u64,
    pub comment: String,
}

/// 新增或修改工作日志时提交的内容。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorklogInput {
    /// Jira 格式：`2026-10-22T09:00:00.000+0800`
    pub started: String,
    /// Jira 时长格式，例如“3h 30m”“1d”。
    pub time_spent: String,
    #[serde(default)]
    pub comment: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: String,
    pub author: String,
    /// 作者的用户名。
    pub author_name: String,
    pub created: String,
    pub items: Vec<HistoryItem>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryItem {
    /// 字段 id（系统字段如 `status`），用于识别状态变化等。
    pub field_id: String,
    pub field: String,
    pub from: Option<String>,
    pub to: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserRef {
    pub name: String,
    pub display_name: String,
}

/// 当前用户可以创建问题的项目及其问题类型。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateProject {
    pub id: String,
    pub key: String,
    pub name: String,
    pub issue_types: Vec<CreateIssueType>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateIssueType {
    pub id: String,
    pub name: String,
    pub icon_url: Option<String>,
    pub subtask: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub id: String,
    pub filename: String,
    pub size: u64,
    pub mime_type: String,
    pub content_url: String,
    pub thumbnail_url: Option<String>,
    pub author: String,
    pub created: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Comment {
    pub id: String,
    pub author: String,
    /// 作者的用户名。
    pub author_name: String,
    /// 是否当前用户写的（只有自己的评论可以修改、删除），由调用方根据当前用户设置。
    pub mine: bool,
    pub created: String,
    pub updated: String,
    /// wiki 标记原文，用于编辑、引用。
    pub body: String,
    /// 仅部分用户可见时的范围（项目角色、用户组）。
    pub visibility: Option<CommentVisibility>,
    pub body_html: String,
}

impl Comment {
    pub fn mark_mine(&mut self, me: &str) {
        self.mine = !me.is_empty() && self.author_name == me;
    }
}

/// 评论的可见范围，例如 `{ "type": "role", "value": "Developers" }`。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommentVisibility {
    /// `role` / `group`
    #[serde(rename = "type")]
    pub kind: String,
    pub value: String,
}

/// 评论时可选的可见范围。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommentLevel {
    pub visibility: CommentVisibility,
    pub label: String,
}

/// 问题的关注情况。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Watchers {
    pub watching: bool,
    pub count: u32,
}

/// Jira 中保存的过滤器。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Filter {
    pub id: String,
    pub name: String,
    pub jql: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Priority {
    pub id: String,
    pub name: String,
    pub icon_url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Transition {
    pub id: String,
    pub name: String,
    pub to: Status,
    pub fields: Vec<FieldMeta>,
}

/// 可编辑字段（编辑、创建、流转界面）的元数据。取值形式见 `meta` 模块说明。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldMeta {
    pub key: String,
    pub name: String,
    pub required: bool,
    /// `text` / `textarea` / `number` / `date` / `datetime` / `select` / `multiselect` / `cascading` /
    /// `user` / `multiuser` / `labels` / `timetracking` / `epic` / `parent` / `unsupported`
    pub kind: String,
    pub options: Vec<FieldOption>,
    /// 编辑时为当前值，创建时为默认值；没有值时为 `null`。
    pub value: Value,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldOption {
    pub id: String,
    pub name: String,
    /// 级联选择字段的子选项。
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<FieldOption>,
    pub disabled: bool,
}

// ---------- Jira 原始响应 ----------

#[derive(Debug, Deserialize)]
pub(crate) struct RawIssue {
    pub key: String,
    pub fields: RawFields,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RawFields {
    #[serde(default)]
    pub summary: String,
    pub status: Option<RawStatus>,
    pub issuetype: Option<RawNamed>,
    pub priority: Option<RawNamed>,
    pub project: Option<RawNamed>,
    pub assignee: Option<RawUser>,
    pub reporter: Option<RawUser>,
    pub resolution: Option<RawNamed>,
    #[serde(default)]
    pub created: String,
    #[serde(default)]
    pub updated: String,
    pub duedate: Option<String>,
    pub last_viewed: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RawStatus {
    pub name: String,
    pub status_category: Option<RawCategory>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct RawCategory {
    pub key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RawNamed {
    pub name: String,
    pub icon_url: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RawUser {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub display_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RawComment {
    pub id: String,
    pub author: Option<RawUser>,
    #[serde(default)]
    pub created: String,
    #[serde(default)]
    pub updated: String,
    #[serde(default)]
    pub body: String,
    pub rendered_body: Option<String>,
    pub visibility: Option<CommentVisibility>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RawAttachment {
    pub id: String,
    pub filename: String,
    #[serde(default)]
    pub size: u64,
    #[serde(default)]
    pub mime_type: String,
    pub content: String,
    pub thumbnail: Option<String>,
    pub author: Option<RawUser>,
    #[serde(default)]
    pub created: String,
}

impl Status {
    pub(crate) fn from_raw(raw: Option<RawStatus>) -> Self {
        match raw {
            Some(s) => Status {
                name: s.name,
                category: s.status_category.map(|c| c.key).unwrap_or_else(|| "new".into()),
            },
            None => Status { name: String::new(), category: "new".into() },
        }
    }
}

impl Named {
    fn from_raw(raw: Option<RawNamed>) -> Self {
        raw.map(|n| Named { name: n.name, icon_url: n.icon_url })
            .unwrap_or(Named { name: String::new(), icon_url: None })
    }
}

impl IssueSummary {
    pub(crate) fn from_raw(raw: RawIssue) -> Self {
        let f = raw.fields;
        IssueSummary {
            key: raw.key,
            summary: f.summary,
            status: Status::from_raw(f.status),
            issue_type: Named::from_raw(f.issuetype),
            priority: f.priority.map(|p| Named { name: p.name, icon_url: p.icon_url }),
            project: Named::from_raw(f.project),
            assignee_name: f.assignee.as_ref().map(|u| u.name.clone()),
            assignee: f.assignee.map(|u| u.display_name),
            reporter_name: f.reporter.as_ref().map(|u| u.name.clone()),
            reporter: f.reporter.map(|u| u.display_name),
            last_viewed: f.last_viewed,
            resolution: f.resolution.map(|r| r.name),
            created: f.created,
            updated: f.updated,
            due_date: f.duedate,
            extra: Default::default(),
        }
    }
}

impl Comment {
    pub(crate) fn from_raw(raw: RawComment, rendered: Option<&Value>) -> Self {
        let body_html = rendered
            .and_then(Value::as_str)
            .map(str::to_string)
            .or(raw.rendered_body)
            .unwrap_or_else(|| escape_html(&raw.body));
        let (author, author_name) = raw.author.map(|a| (a.display_name, a.name)).unwrap_or_default();
        Comment { id: raw.id, author, author_name, mine: false, created: raw.created, updated: raw.updated, body: raw.body, body_html, visibility: raw.visibility }
    }
}

impl Attachment {
    pub(crate) fn from_raw(raw: RawAttachment) -> Self {
        Attachment {
            id: raw.id,
            filename: raw.filename,
            size: raw.size,
            mime_type: raw.mime_type,
            content_url: raw.content,
            thumbnail_url: raw.thumbnail,
            author: raw.author.map(|a| a.display_name).unwrap_or_default(),
            created: raw.created,
        }
    }
}

impl IssueDetail {
    pub(crate) fn from_raw(raw: Value) -> Result<Self> {
        let key = raw["key"].as_str().unwrap_or_default().to_string();
        let fields = &raw["fields"];
        let rendered = &raw["renderedFields"];

        let summary = IssueSummary::from_raw(RawIssue {
            key,
            fields: serde_json::from_value(fields.clone())?,
        });

        let attachments = match fields.get("attachment") {
            Some(v) if v.is_array() => serde_json::from_value::<Vec<RawAttachment>>(v.clone())?
                .into_iter()
                .map(Attachment::from_raw)
                .collect(),
            _ => Vec::new(),
        };

        let raw_comments: Vec<RawComment> = match fields["comment"].get("comments") {
            Some(v) => serde_json::from_value(v.clone())?,
            None => Vec::new(),
        };
        let rendered_comments = rendered["comment"]["comments"].as_array();
        let comments = raw_comments
            .into_iter()
            .enumerate()
            .map(|(i, c)| {
                let html = rendered_comments.and_then(|list| list.get(i)).map(|c| &c["body"]);
                Comment::from_raw(c, html)
            })
            .collect();

        Ok(IssueDetail {
            id: value_text(&raw["id"]),
            summary,
            description_html: rendered["description"]
                .as_str()
                .filter(|s| !s.trim().is_empty())
                .map(str::to_string),
            fields: display_fields(fields, rendered, &raw["names"], &raw["schema"], &screen_fields(&raw["editmeta"])),
            time_tracking: TimeTracking::from_raw(&fields["timetracking"]),
            parent: fields.get("parent").filter(|p| p.is_object()).map(IssueRef::from_raw),
            subtasks: fields["subtasks"].as_array().into_iter().flatten().map(IssueRef::from_raw).collect(),
            links: parse_links(fields),
            attachments,
            comments,
        })
    }
}

/// 问题界面上的字段 id，按界面顺序；没有编辑权限时 Jira 不返回，结果为空。
fn screen_fields(editmeta: &Value) -> Vec<String> {
    editmeta["fields"].as_object().map(|m| m.keys().cloned().collect()).unwrap_or_default()
}

fn parse_links(fields: &Value) -> Vec<IssueLink> {
    fields["issuelinks"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|link| {
            let (relation, issue) = match (link.get("outwardIssue"), link.get("inwardIssue")) {
                (Some(issue), _) => (&link["type"]["outward"], issue),
                (None, Some(issue)) => (&link["type"]["inward"], issue),
                (None, None) => return None,
            };
            Some(IssueLink { id: value_text(&link["id"]), relation: value_text(relation), issue: IssueRef::from_raw(issue) })
        })
        .collect()
}

impl IssueRef {
    pub(crate) fn from_raw(issue: &Value) -> Self {
        let f = &issue["fields"];
        IssueRef {
            key: value_text(&issue["key"]),
            summary: value_text(&f["summary"]),
            status: serde_json::from_value::<RawStatus>(f["status"].clone()).ok().map(|s| Status::from_raw(Some(s))),
            issue_type: serde_json::from_value::<RawNamed>(f["issuetype"].clone()).ok().map(|t| Named { name: t.name, icon_url: t.icon_url }),
        }
    }
}

impl TimeTracking {
    fn from_raw(raw: &Value) -> Option<Self> {
        let text = |k: &str| raw[k].as_str().map(str::to_string);
        let secs = |k: &str| raw[k].as_u64();
        let tt = TimeTracking {
            original_estimate: text("originalEstimate"),
            remaining_estimate: text("remainingEstimate"),
            time_spent: text("timeSpent"),
            original_estimate_seconds: secs("originalEstimateSeconds"),
            remaining_estimate_seconds: secs("remainingEstimateSeconds"),
            time_spent_seconds: secs("timeSpentSeconds"),
        };
        (tt.original_estimate.is_some() || tt.remaining_estimate.is_some() || tt.time_spent.is_some()).then_some(tt)
    }
}

impl Worklog {
    pub(crate) fn from_raw(raw: &Value, me: &str) -> Self {
        Worklog {
            id: value_text(&raw["id"]),
            author: value_text(&raw["author"]),
            mine: raw["author"]["name"].as_str() == Some(me),
            started: value_text(&raw["started"]),
            time_spent: value_text(&raw["timeSpent"]),
            time_spent_seconds: raw["timeSpentSeconds"].as_u64().unwrap_or_default(),
            comment: value_text(&raw["comment"]),
        }
    }
}

impl HistoryEntry {
    pub(crate) fn from_raw(raw: &Value, names: &Value) -> Self {
        // 优先使用可读的 fromString / toString，没有时退回原始 id
        let side = |item: &Value, text: &str, id: &str| {
            item[text].as_str().or(item[id].as_str()).filter(|s| !s.is_empty()).map(str::to_string)
        };
        HistoryEntry {
            id: value_text(&raw["id"]),
            author: value_text(&raw["author"]),
            author_name: value_text(&raw["author"]["name"]),
            created: value_text(&raw["created"]),
            items: raw["items"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|item| HistoryItem {
                    field_id: item["fieldId"].as_str().map_or_else(|| value_text(&item["field"]).to_lowercase(), str::to_string),
                    field: history_field_name(item, names),
                    from: side(item, "fromString", "from"),
                    to: side(item, "toString", "to"),
                })
                .collect(),
        }
    }
}

/// 变更记录中的字段名：自定义字段已是显示名称，系统字段只有 id，需查 names 映射。
fn history_field_name(item: &Value, names: &Value) -> String {
    let field = value_text(&item["field"]);
    if item["fieldtype"].as_str() != Some("jira") {
        return field;
    }
    let id = match (item["fieldId"].as_str(), field.as_str()) {
        (Some(id), _) => id.to_string(),
        // 这几个系统字段在变更记录里用的是单数的英文名
        (None, "Component") => "components".into(),
        (None, "Version") => "versions".into(),
        (None, "Fix Version") => "fixVersions".into(),
        (None, other) => other.to_lowercase(),
    };
    if let Some(name) = names[id.as_str()].as_str() {
        return name.to_string();
    }
    // 不对应任何字段的系统记录
    match field.as_str() {
        "Link" | "RemoteIssueLink" => "链接".into(),
        "WorklogId" => "工作日志".into(),
        "Parent" | "Parent Issue" => "父任务".into(),
        "Workflow" => "工作流".into(),
        "timespent" => "耗费时间".into(),
        "timeestimate" => "剩余估算".into(),
        "timeoriginalestimate" => "初始估算".into(),
        _ => field,
    }
}

pub(crate) fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('\n', "<br/>")
}
