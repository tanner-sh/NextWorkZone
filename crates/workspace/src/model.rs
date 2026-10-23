use serde::{Deserialize, Serialize};

/// 待办。整行即同步单位，字段与数据库列一一对应。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Todo {
    pub id: String,
    pub title: String,
    /// 备注（Markdown）。
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub done: bool,
    pub completed_at: Option<i64>,
    /// 截止日期 `YYYY-MM-DD`。
    pub due: Option<String>,
    /// 0 无、1 低、2 中、3 高。
    #[serde(default)]
    pub priority: i64,
    #[serde(default)]
    pub sort: f64,
    /// 关联的外部条目，例如 (`jira`, `ABC-123`, 问题概要)。
    pub ref_system: Option<String>,
    pub ref_key: Option<String>,
    pub ref_title: Option<String>,
    /// 自动创建的来源，例如 `jira`（分配给我的问题）。
    pub source: Option<String>,
    /// 由来源同步自动完成（问题已解决或不再分配给我）。
    #[serde(default)]
    pub auto_done: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub updated_by: String,
    #[serde(default)]
    pub deleted: bool,
    /// 提醒时间（毫秒时间戳），到时发系统通知。
    #[serde(default)]
    pub remind_at: Option<i64>,
    /// 重复规则：`daily` 每天、`weekdays` 工作日、`weekly` 每周、`monthly` 每月。完成后生成下一次。
    #[serde(default)]
    pub repeat: Option<String>,
    /// 检查项（子任务）。
    #[serde(default)]
    pub checklist: Vec<ChecklistItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChecklistItem {
    pub id: String,
    pub text: String,
    #[serde(default)]
    pub done: bool,
}

/// 新建或修改待办时由界面提交的内容。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TodoInput {
    pub id: Option<String>,
    pub title: String,
    pub notes: String,
    pub done: bool,
    pub due: Option<String>,
    pub priority: i64,
    pub ref_system: Option<String>,
    pub ref_key: Option<String>,
    pub ref_title: Option<String>,
    pub remind_at: Option<i64>,
    pub repeat: Option<String>,
    pub checklist: Vec<ChecklistItem>,
}

/// 收件箱中的一条记录。整行即同步单位。
/// - `capture`：旧版本随手记下的内容，现在会转为待办（见 `Workspace::captures_to_todos`）；
/// - `state`：外部条目（动态、到期问题、合并请求等）的处理状态，id 为条目 id，
///   条目本身每次从各系统实时汇总，这里只记录“已处理”“稍后提醒”。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxEntry {
    pub id: String,
    pub kind: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub body: String,
    pub url: Option<String>,
    /// 处理（完成、忽略、转为待办）的时间；外部条目在此之后有新变化时重新出现。
    pub handled_at: Option<i64>,
    /// 稍后提醒：在此之前不显示，到时发通知。
    pub snooze_until: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
    pub updated_by: String,
    #[serde(default)]
    pub deleted: bool,
}

/// 到时间需要发出的提醒。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DueAlert {
    /// `todo` 或 `inbox`
    pub item_type: String,
    pub id: String,
    pub title: String,
}

/// 文档：笔记、日记、知识库页面共用一种结构。整行即同步单位。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Doc {
    pub id: String,
    /// `note` 笔记、`daily` 日记、`page` 知识库页面。
    pub kind: String,
    #[serde(default)]
    pub title: String,
    /// 正文（Markdown）。
    #[serde(default)]
    pub content: String,
    /// 知识库页面的上级页面。
    pub parent_id: Option<String>,
    #[serde(default)]
    pub sort: f64,
    #[serde(default)]
    pub tags: Vec<String>,
    /// 日记对应的日期 `YYYY-MM-DD`。
    pub day: Option<String>,
    #[serde(default)]
    pub pinned: bool,
    /// 从外部沉淀、剪藏而来时的来源，例如 (`jira`, `ABC-123`, 地址)。
    pub source_system: Option<String>,
    pub source_key: Option<String>,
    pub source_url: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub updated_by: String,
    /// 本版本是在哪个版本（其 `updated_at`）的基础上修改的，用于识别两台设备各自修改的冲突。
    #[serde(default)]
    pub base_at: i64,
    #[serde(default)]
    pub deleted: bool,
    /// 知识库页面发布到的 Wiki 页面地址（带页面 id 和发布时的版本 `pageVersion`），用于再次发布时更新该页面。
    #[serde(default)]
    pub published_url: Option<String>,
}

/// 列表中展示的文档摘要（不含完整正文）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocSummary {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub excerpt: String,
    pub parent_id: Option<String>,
    pub sort: f64,
    pub tags: Vec<String>,
    pub day: Option<String>,
    pub pinned: bool,
    pub source_system: Option<String>,
    pub source_key: Option<String>,
    pub published_url: Option<String>,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DocInput {
    pub id: Option<String>,
    pub kind: String,
    pub title: String,
    pub content: String,
    pub parent_id: Option<String>,
    pub tags: Vec<String>,
    pub pinned: bool,
    pub source_system: Option<String>,
    pub source_key: Option<String>,
    pub source_url: Option<String>,
    pub published_url: Option<String>,
}

/// 引用某个条目的本地内容（反向链接）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Backlink {
    /// `todo` 或 `doc`
    pub item_type: String,
    pub id: String,
    /// 文档类型（`note` / `daily` / `page`），待办为 `todo`。
    pub kind: String,
    pub title: String,
    pub done: bool,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub item_type: String,
    pub id: String,
    pub kind: String,
    pub title: String,
    pub snippet: String,
    pub done: bool,
}

/// 粘贴进笔记的图片等二进制内容。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetMeta {
    pub id: String,
    pub mime: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncReport {
    pub exported: usize,
    pub imported: usize,
    pub conflicts: usize,
    /// 其他设备的数量。
    pub devices: usize,
    pub finished_at: i64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JiraTodoSync {
    pub added: usize,
    pub completed: usize,
    pub reopened: usize,
}

/// 从 Jira 同步待办时需要的问题信息。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssignedIssue {
    pub key: String,
    pub summary: String,
    pub due: Option<String>,
}

/// 从 Wiki 同步待办时需要的页面任务信息。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssignedWikiTask {
    pub page_id: String,
    pub page_title: String,
    pub task_id: String,
    pub text: String,
    pub due: Option<String>,
}
