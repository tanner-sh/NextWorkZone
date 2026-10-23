use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::{Error, Result, Service};

/// 持久化到磁盘的应用配置。Token 不在这里，它们存放在系统钥匙串中（见 [`crate::secrets`]）。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppConfig {
    /// 形如 `http://127.0.0.1:7890` 或 `socks5://...`；为空时使用系统代理设置。
    pub proxy: Option<String>,
    pub jira: Endpoint,
    pub confluence: Endpoint,
    pub gitlab: Endpoint,
    pub weekly: WeeklyConfig,
    pub workspace: WorkspaceConfig,
    pub jira_tools: JiraToolsConfig,
    pub wiki_tools: WikiToolsConfig,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Endpoint {
    pub base_url: String,
}

/// 周报所在的 Confluence 页面，以及周报表格中“人员名称”一列里自己的名字。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WeeklyConfig {
    pub page_id: String,
    /// 为空时使用 Confluence 账号的显示名。
    pub person_name: String,
}

/// 工作空间（待办、笔记、知识库）的本机设置，不参与同步。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorkspaceConfig {
    /// 同步文件夹（iCloud Drive、坚果云等）；为空表示不同步。
    pub sync_dir: String,
    /// 自动把分配给我的未解决 Jira 问题加入待办。
    pub jira_todos: bool,
    /// 在任何应用中打开“快速记录”的全局快捷键，例如 `Alt+Space`；为空表示不使用。
    pub capture_shortcut: String,
}

/// 快速记录的默认快捷键（macOS 上为 ⌥Space）。
pub const DEFAULT_CAPTURE_SHORTCUT: &str = "Alt+Space";

impl Default for WorkspaceConfig {
    fn default() -> Self {
        Self { sync_dir: String::new(), jira_todos: true, capture_shortcut: DEFAULT_CAPTURE_SHORTCUT.into() }
    }
}

/// Jira 的本机增强功能：本机问题库、到期提醒。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct JiraToolsConfig {
    /// 把问题同步到本机，用于离线搜索和相似问题。
    pub index_enabled: bool,
    /// 问题库的范围；为空时自动选择“我经办过或报告过问题的项目”。
    pub index_jql: String,
    /// 只同步最近多少天内创建的问题；0 表示不限。
    pub index_days: u32,
    /// 到期时间所在的字段 id；为空时自动识别（`duedate` 或名称像到期时间的日期字段）。
    pub due_field: String,
    /// 提前多少天提醒即将到期。
    pub due_soon_days: u32,
    /// 多少天没有更新算作停滞；0 表示不提醒。
    pub stale_days: u32,
    /// 每天发一次到期提醒的系统通知。
    pub remind: bool,
}

impl Default for JiraToolsConfig {
    fn default() -> Self {
        Self {
            index_enabled: true,
            index_jql: String::new(),
            index_days: 730,
            due_field: String::new(),
            due_soon_days: 2,
            stale_days: 7,
            remind: true,
        }
    }
}

/// Wiki 的本机增强功能：本机 Wiki 库、页面任务同步为待办、动态。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WikiToolsConfig {
    /// 把页面同步到本机，用于快速全文搜索、查找引用问题的页面和分配给我的任务。
    pub index_enabled: bool,
    /// 同步的空间 key；为空时同步全部可见的空间。
    pub index_spaces: Vec<String>,
    /// 把页面中分配给我的未完成任务加入待办。
    pub task_todos: bool,
    /// 在动态中显示 Wiki 上的评论、提到、分享，以及关注页面的修改。
    pub activity: bool,
    /// 不提示修改的页面 id（例如多人每天都在改的汇总页面）。周报页面始终不提示。
    pub muted_pages: Vec<String>,
}

impl Default for WikiToolsConfig {
    fn default() -> Self {
        Self { index_enabled: true, index_spaces: Vec::new(), task_todos: true, activity: true, muted_pages: Vec::new() }
    }
}

impl AppConfig {
    /// 读取配置；文件不存在时返回默认配置。
    pub fn load(path: &Path) -> Result<Self> {
        match fs::read_to_string(path) {
            Ok(text) => Ok(serde_json::from_str(&text)?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e.into()),
        }
    }

    /// 先写临时文件再重命名，避免写到一半时崩溃导致配置损坏。
    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_string_pretty(self)?)?;
        fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn endpoint(&self, service: Service) -> &Endpoint {
        match service {
            Service::Jira => &self.jira,
            Service::Confluence => &self.confluence,
            Service::Gitlab => &self.gitlab,
        }
    }

    pub fn endpoint_mut(&mut self, service: Service) -> &mut Endpoint {
        match service {
            Service::Jira => &mut self.jira,
            Service::Confluence => &mut self.confluence,
            Service::Gitlab => &mut self.gitlab,
        }
    }

    /// 已配置的基础地址；未配置时返回 [`Error::NotConfigured`]。
    pub fn base_url(&self, service: Service) -> Result<&str> {
        let url = self.endpoint(service).base_url.as_str();
        if url.is_empty() {
            Err(Error::NotConfigured(service))
        } else {
            Ok(url)
        }
    }
}

/// 从页面地址（`...viewpage.action?pageId=123`、`.../pages/123/标题`）或纯数字中提取页面 ID。
pub fn parse_page_id(input: &str) -> Option<String> {
    let input = input.trim();
    if !input.is_empty() && input.chars().all(|c| c.is_ascii_digit()) {
        return Some(input.to_string());
    }
    let url = url::Url::parse(input).ok()?;
    if let Some((_, id)) = url.query_pairs().find(|(k, _)| k == "pageId") {
        return Some(id.into_owned());
    }
    let segments: Vec<_> = url.path_segments()?.collect();
    segments
        .windows(2)
        .find(|w| w[0] == "pages" && w[1].chars().all(|c| c.is_ascii_digit()) && !w[1].is_empty())
        .map(|w| w[1].to_string())
}

/// 页面路径的起始段。用户常常直接粘贴浏览器地址栏里的页面地址，
/// 例如 `https://jira.example.com/secure/Dashboard.jspa`，需要截掉这些段。
const UI_PATH_SEGMENTS: &[&str] = &[
    "secure", "browse", "projects", "issues", "login.jsp", "pages", "display", "spaces",
    "login.action", "index.action", "dashboard", "users", "-", "explore",
];

/// 把用户输入的地址规范化为系统根地址（不带末尾斜杠），保留可能存在的上下文路径。
pub fn normalize_base_url(input: &str) -> Result<String> {
    let input = input.trim();
    if input.is_empty() {
        return Ok(String::new());
    }
    let with_scheme = if input.contains("://") {
        input.to_string()
    } else {
        format!("https://{input}")
    };
    let url = url::Url::parse(&with_scheme).map_err(|_| Error::InvalidUrl(input.to_string()))?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err(Error::InvalidUrl(input.to_string()));
    }

    let mut context_path = Vec::new();
    for segment in url.path_segments().into_iter().flatten() {
        if segment.is_empty() || UI_PATH_SEGMENTS.contains(&segment) {
            break;
        }
        context_path.push(segment);
    }

    let mut base = url.origin().ascii_serialization();
    for segment in context_path {
        base.push('/');
        base.push_str(segment);
    }
    Ok(base)
}

#[cfg(test)]
mod tests {
    use super::normalize_base_url;

    #[test]
    fn strips_ui_pages_and_trailing_slash() {
        let cases = [
            ("https://jira.example.com/secure/Dashboard.jspa", "https://jira.example.com"),
            ("https://wiki.example.com/", "https://wiki.example.com"),
            (
                "https://wiki.example.com/pages/viewpage.action?pageId=1#x",
                "https://wiki.example.com",
            ),
            ("git.example.com", "https://git.example.com"),
            ("https://git.example.com/users/sign_in", "https://git.example.com"),
            ("https://host:8443/jira/browse/ABC-1", "https://host:8443/jira"),
            ("", ""),
        ];
        for (input, expected) in cases {
            assert_eq!(normalize_base_url(input).unwrap(), expected, "input: {input}");
        }
    }

    #[test]
    fn parses_page_id() {
        use super::parse_page_id;
        assert_eq!(
            parse_page_id("https://wiki.x.com/pages/viewpage.action?pageId=123456789#expand-").as_deref(),
            Some("123456789")
        );
        assert_eq!(parse_page_id("https://wiki.x.com/pages/123/Title").as_deref(), Some("123"));
        assert_eq!(parse_page_id(" 42 ").as_deref(), Some("42"));
        assert_eq!(parse_page_id("https://wiki.x.com/display/ABC/Title"), None);
    }

    #[test]
    fn rejects_invalid() {
        assert!(normalize_base_url("ftp://host").is_err());
        assert!(normalize_base_url("http://").is_err());
    }
}
