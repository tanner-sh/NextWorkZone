//! GitLab 适配器（REST API v4，PRIVATE-TOKEN 认证）。

use base64::Engine;
use nextworkzone_core::http::check;
use nextworkzone_core::{ConnectionInfo, Error, Result, Service};
use reqwest::{Client, Method, RequestBuilder, Url};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

pub mod links;
mod mr;
pub use mr::*;

#[derive(Clone)]
pub struct GitlabClient {
    http: Client,
    base_url: String,
    token: String,
}

/// 超过这个大小的文件不在工作台内展示。
const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;
/// 目录树最多读取的条目数（分页拉取）。
const MAX_TREE_ENTRIES: usize = 2000;

#[derive(Debug, Deserialize)]
struct Version {
    version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct User {
    pub id: u64,
    pub username: String,
    pub name: String,
}

#[derive(Debug, Deserialize)]
struct RawUser {
    id: u64,
    username: String,
    name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub id: u64,
    pub name: String,
    pub path_with_namespace: String,
    pub description: Option<String>,
    pub default_branch: Option<String>,
    pub web_url: String,
    pub last_activity_at: String,
    /// 合并后是否默认删除源分支（列表接口不返回，为空）。
    pub remove_source_branch_after_merge: Option<bool>,
    /// `never` / `always` / `default_on` / `default_off`（列表接口不返回，为空）。
    pub squash_option: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawProject {
    id: u64,
    name: String,
    path_with_namespace: String,
    description: Option<String>,
    default_branch: Option<String>,
    web_url: String,
    #[serde(default)]
    last_activity_at: String,
    remove_source_branch_after_merge: Option<bool>,
    squash_option: Option<String>,
}

impl From<RawProject> for Project {
    fn from(p: RawProject) -> Self {
        Project {
            id: p.id,
            name: p.name,
            path_with_namespace: p.path_with_namespace,
            description: p.description.filter(|d| !d.trim().is_empty()),
            default_branch: p.default_branch,
            web_url: p.web_url,
            last_activity_at: p.last_activity_at,
            remove_source_branch_after_merge: p.remove_source_branch_after_merge,
            squash_option: p.squash_option,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Branch {
    pub name: String,
    pub default: bool,
    pub protected: bool,
    pub merged: bool,
    pub commit: Commit,
}

#[derive(Debug, Deserialize)]
struct RawBranch {
    name: String,
    #[serde(default)]
    default: bool,
    #[serde(default)]
    protected: bool,
    #[serde(default)]
    merged: bool,
    commit: RawCommit,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Commit {
    pub id: String,
    pub short_id: String,
    pub title: String,
    pub message: String,
    pub author_name: String,
    pub authored_date: String,
    pub web_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawCommit {
    id: String,
    short_id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    message: String,
    #[serde(default)]
    author_name: String,
    #[serde(default)]
    authored_date: String,
    web_url: Option<String>,
}

impl From<RawCommit> for Commit {
    fn from(c: RawCommit) -> Self {
        Commit {
            id: c.id,
            short_id: c.short_id,
            title: c.title,
            message: c.message,
            author_name: c.author_name,
            authored_date: c.authored_date,
            web_url: c.web_url,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeEntry {
    pub name: String,
    pub path: String,
    /// `tree`（目录）/ `blob`（文件）/ `commit`（子模块）
    pub kind: String,
}

#[derive(Debug, Deserialize)]
struct RawTreeEntry {
    name: String,
    path: String,
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileContent {
    pub path: String,
    pub size: u64,
    /// 文本文件的内容；二进制、过大或图片时为空。
    pub text: Option<String>,
    /// 图片以 data URL 返回，便于直接显示。
    pub image_data_url: Option<String>,
    pub too_large: bool,
    pub binary: bool,
}

#[derive(Debug, Deserialize)]
struct RawFile {
    #[serde(default)]
    size: u64,
    #[serde(default)]
    content: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileDiff {
    pub old_path: String,
    pub new_path: String,
    pub diff: String,
    pub new_file: bool,
    pub deleted_file: bool,
    pub renamed_file: bool,
}

#[derive(Debug, Deserialize)]
struct RawDiff {
    old_path: String,
    new_path: String,
    #[serde(default)]
    diff: String,
    #[serde(default)]
    new_file: bool,
    #[serde(default)]
    deleted_file: bool,
    #[serde(default)]
    renamed_file: bool,
}

impl From<RawDiff> for FileDiff {
    fn from(d: RawDiff) -> Self {
        FileDiff {
            old_path: d.old_path,
            new_path: d.new_path,
            diff: d.diff,
            new_file: d.new_file,
            deleted_file: d.deleted_file,
            renamed_file: d.renamed_file,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitDetail {
    pub commit: Commit,
    pub diffs: Vec<FileDiff>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Comparison {
    pub commits: Vec<Commit>,
    pub diffs: Vec<FileDiff>,
}

#[derive(Debug, Deserialize)]
struct RawCompare {
    #[serde(default)]
    commits: Vec<RawCommit>,
    #[serde(default)]
    diffs: Vec<RawDiff>,
}

/// 自己的一次推送。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PushEvent {
    pub project_id: u64,
    pub branch: String,
    pub commit_title: String,
    pub commit_count: u64,
    pub created_at: String,
}

/// 自己在 GitLab 上的一次操作（工作记录用）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MyEvent {
    pub at: String,
    /// `push` 推送 / `mr_open` 发起合并请求 / `mr_merge` 合并 / `mr_approve` 批准 / `mr_close` 关闭 / `comment` 评论
    pub kind: String,
    pub project_id: u64,
    /// 合并请求标题或分支名。
    pub title: String,
    /// 提交说明、评论摘要等。
    pub detail: String,
    /// 合并请求编号（项目内的 !iid）。
    pub iid: Option<u64>,
    pub commit_count: u64,
}

/// 把 GitLab 事件转换为工作记录；与工作无关的事件（加入项目、删除分支等）返回 `None`。
pub fn my_event(e: &serde_json::Value) -> Option<MyEvent> {
    let text = |v: &serde_json::Value| v.as_str().unwrap_or_default().to_string();
    let action = e["action_name"].as_str().unwrap_or_default();
    let target = e["target_type"].as_str().unwrap_or_default();
    let mut event = MyEvent {
        at: text(&e["created_at"]),
        kind: String::new(),
        project_id: e["project_id"].as_u64()?,
        title: text(&e["target_title"]),
        detail: String::new(),
        iid: e["target_iid"].as_u64(),
        commit_count: 0,
    };
    match (action, target) {
        ("pushed to" | "pushed new", _) => {
            let push = &e["push_data"];
            event.kind = "push".into();
            event.title = text(&push["ref"]);
            event.detail = text(&push["commit_title"]);
            event.commit_count = push["commit_count"].as_u64().unwrap_or(0);
            if event.commit_count == 0 {
                return None;
            }
        }
        ("opened", "MergeRequest") => event.kind = "mr_open".into(),
        ("accepted", "MergeRequest") => event.kind = "mr_merge".into(),
        ("approved", "MergeRequest") => event.kind = "mr_approve".into(),
        ("closed", "MergeRequest") => event.kind = "mr_close".into(),
        ("commented on", _) => {
            let note = &e["note"];
            event.kind = "comment".into();
            event.detail = text(&note["body"]).split_whitespace().collect::<Vec<_>>().join(" ").chars().take(120).collect();
            if note["noteable_type"] == "MergeRequest" {
                event.iid = note["noteable_iid"].as_u64();
            }
        }
        _ => return None,
    }
    Some(event)
}

impl GitlabClient {
    pub fn new(http: Client, base_url: impl Into<String>, token: impl Into<String>) -> Self {
        Self { http, base_url: base_url.into(), token: token.into() }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// 组装 API 地址；每个段单独编码，因此项目路径、文件路径中的 `/` 会被转义为 `%2F`。
    fn api_url(&self, segments: &[&str]) -> Result<Url> {
        let mut url = Url::parse(&self.base_url).map_err(|_| Error::InvalidUrl(self.base_url.clone()))?;
        url.path_segments_mut()
            .map_err(|_| Error::InvalidUrl(self.base_url.clone()))?
            .pop_if_empty()
            .extend(["api", "v4"])
            .extend(segments);
        Ok(url)
    }

    fn request(&self, method: Method, segments: &[&str]) -> Result<RequestBuilder> {
        Ok(self.http.request(method, self.api_url(segments)?).header("PRIVATE-TOKEN", &self.token))
    }

    fn get(&self, segments: &[&str]) -> Result<RequestBuilder> {
        self.request(Method::GET, segments)
    }

    async fn json<T: DeserializeOwned>(&self, request: RequestBuilder) -> Result<T> {
        Ok(check(request.send().await?).await?.json().await?)
    }

    /// 按 `X-Next-Page` 分页拉取，最多 `limit` 条。
    async fn all_pages<T: DeserializeOwned>(&self, segments: &[&str], query: &[(&str, &str)], limit: usize) -> Result<Vec<T>> {
        let mut items = Vec::new();
        let mut page = "1".to_string();
        let per_page = limit.clamp(1, 100).to_string();
        loop {
            let response = check(
                self.get(segments)?.query(query).query(&[("per_page", per_page.as_str()), ("page", page.as_str())]).send().await?,
            )
            .await?;
            let next = response
                .headers()
                .get("x-next-page")
                .and_then(|v| v.to_str().ok())
                .filter(|v| !v.is_empty())
                .map(str::to_string);
            items.extend(response.json::<Vec<T>>().await?);
            match next {
                Some(n) if items.len() < limit => page = n,
                _ => break,
            }
        }
        items.truncate(limit);
        Ok(items)
    }

    pub async fn connection_info(&self) -> Result<ConnectionInfo> {
        let me = self.current_user().await?;
        let version: Version = self.json(self.get(&["version"])?).await?;
        Ok(ConnectionInfo {
            service: Service::Gitlab,
            username: me.username,
            display_name: me.name,
            server_version: Some(version.version),
        })
    }

    pub async fn current_user(&self) -> Result<User> {
        let u: RawUser = self.json(self.get(&["user"])?).await?;
        Ok(User { id: u.id, username: u.username, name: u.name })
    }

    /// 自己参与的项目，按最近活动排序；`search` 用于按名称过滤。
    pub async fn projects(&self, search: Option<&str>, limit: usize) -> Result<Vec<Project>> {
        let mut query = vec![("membership", "true"), ("simple", "true"), ("order_by", "last_activity_at")];
        if let Some(s) = search.filter(|s| !s.trim().is_empty()) {
            query.push(("search", s));
        }
        let raw: Vec<RawProject> = self.all_pages(&["projects"], &query, limit).await?;
        Ok(raw.into_iter().map(Project::from).collect())
    }

    pub async fn project(&self, id: u64) -> Result<Project> {
        let raw: RawProject = self.json(self.get(&["projects", &id.to_string()])?).await?;
        Ok(raw.into())
    }

    /// 按路径（`group/project`）取项目。
    pub async fn project_by_path(&self, path: &str) -> Result<Project> {
        let raw: RawProject = self.json(self.get(&["projects", path])?).await?;
        Ok(raw.into())
    }

    /// 一个分支；不存在时返回 `None`。
    pub async fn branch(&self, project: u64, name: &str) -> Result<Option<Branch>> {
        let id = project.to_string();
        let response = self.get(&["projects", &id, "repository", "branches", name])?.send().await?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let b: RawBranch = check(response).await?.json().await?;
        Ok(Some(Branch { name: b.name, default: b.default, protected: b.protected, merged: b.merged, commit: b.commit.into() }))
    }

    pub async fn branches(&self, project: u64, search: Option<&str>) -> Result<Vec<Branch>> {
        let id = project.to_string();
        let mut query = Vec::new();
        if let Some(s) = search.filter(|s| !s.trim().is_empty()) {
            query.push(("search", s));
        }
        let raw: Vec<RawBranch> = self.all_pages(&["projects", &id, "repository", "branches"], &query, 500).await?;
        let mut branches: Vec<Branch> = raw
            .into_iter()
            .map(|b| Branch { name: b.name, default: b.default, protected: b.protected, merged: b.merged, commit: b.commit.into() })
            .collect();
        // 默认分支在前，其余按最近提交时间倒序
        branches.sort_by(|a, b| b.default.cmp(&a.default).then_with(|| b.commit.authored_date.cmp(&a.commit.authored_date)));
        Ok(branches)
    }

    /// 目录内容：目录在前、文件在后，各自按名称排序。
    pub async fn tree(&self, project: u64, git_ref: &str, path: &str) -> Result<Vec<TreeEntry>> {
        let id = project.to_string();
        let mut query = vec![("ref", git_ref)];
        if !path.is_empty() {
            query.push(("path", path));
        }
        let raw: Vec<RawTreeEntry> =
            self.all_pages(&["projects", &id, "repository", "tree"], &query, MAX_TREE_ENTRIES).await?;
        let mut entries: Vec<TreeEntry> =
            raw.into_iter().map(|e| TreeEntry { name: e.name, path: e.path, kind: e.kind }).collect();
        entries.sort_by(|a, b| (a.kind != "tree").cmp(&(b.kind != "tree")).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
        Ok(entries)
    }

    pub async fn file(&self, project: u64, git_ref: &str, path: &str) -> Result<FileContent> {
        let id = project.to_string();
        // 先只取元数据判断大小，避免下载超大文件
        let head = check(
            self.http
                .head(self.api_url(&["projects", &id, "repository", "files", path])?)
                .header("PRIVATE-TOKEN", &self.token)
                .query(&[("ref", git_ref)])
                .send()
                .await?,
        )
        .await?;
        let size = head
            .headers()
            .get("x-gitlab-size")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
        let mut file = FileContent { path: path.to_string(), size, text: None, image_data_url: None, too_large: false, binary: false };
        if size > MAX_FILE_BYTES {
            file.too_large = true;
            return Ok(file);
        }

        let raw: RawFile =
            self.json(self.get(&["projects", &id, "repository", "files", path])?.query(&[("ref", git_ref)])).await?;
        file.size = raw.size;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(raw.content.replace('\n', ""))
            .map_err(|e| Error::Other(format!("文件内容解码失败：{e}")))?;
        if let Some(mime) = image_mime(path) {
            let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
            file.image_data_url = Some(format!("data:{mime};base64,{data}"));
        } else if bytes.contains(&0) {
            file.binary = true;
        } else {
            match String::from_utf8(bytes) {
                Ok(text) => file.text = Some(text),
                Err(_) => file.binary = true,
            }
        }
        Ok(file)
    }

    pub async fn commits(&self, project: u64, git_ref: &str, path: Option<&str>, page: u32) -> Result<Vec<Commit>> {
        let id = project.to_string();
        let page = page.to_string();
        let mut query = vec![("ref_name", git_ref), ("per_page", "50"), ("page", page.as_str())];
        if let Some(p) = path.filter(|p| !p.is_empty()) {
            query.push(("path", p));
        }
        let raw: Vec<RawCommit> = self.json(self.get(&["projects", &id, "repository", "commits"])?.query(&query)).await?;
        Ok(raw.into_iter().map(Commit::from).collect())
    }

    /// 分支在一段时间内（`since`、`until` 为 ISO 8601）的提交，新的在前。
    pub async fn commits_between(&self, project: u64, git_ref: &str, since: &str, until: &str, limit: usize) -> Result<Vec<Commit>> {
        let id = project.to_string();
        let raw: Vec<RawCommit> = self
            .all_pages(&["projects", &id, "repository", "commits"], &[("ref_name", git_ref), ("since", since), ("until", until)], limit)
            .await?;
        Ok(raw.into_iter().map(Commit::from).collect())
    }

    /// 一个提交（不含改动）。
    pub async fn commit_info(&self, project: u64, sha: &str) -> Result<Commit> {
        let id = project.to_string();
        let raw: RawCommit = self.json(self.get(&["projects", &id, "repository", "commits", sha])?).await?;
        Ok(raw.into())
    }

    /// 在项目中按提交说明搜索（GitLab 只搜索默认分支）。
    pub async fn search_commits(&self, project: u64, text: &str, limit: usize) -> Result<Vec<Commit>> {
        let id = project.to_string();
        let raw: Vec<RawCommit> = self.all_pages(&["projects", &id, "search"], &[("scope", "commits"), ("search", text)], limit).await?;
        Ok(raw.into_iter().map(Commit::from).collect())
    }

    pub async fn commit(&self, project: u64, sha: &str) -> Result<CommitDetail> {
        let id = project.to_string();
        let commit: RawCommit = self.json(self.get(&["projects", &id, "repository", "commits", sha])?).await?;
        let diffs: Vec<RawDiff> =
            self.all_pages(&["projects", &id, "repository", "commits", sha, "diff"], &[], 500).await?;
        Ok(CommitDetail { commit: commit.into(), diffs: diffs.into_iter().map(FileDiff::from).collect() })
    }

    pub async fn compare(&self, project: u64, from: &str, to: &str) -> Result<Comparison> {
        let id = project.to_string();
        let raw: RawCompare = self
            .json(self.get(&["projects", &id, "repository", "compare"])?.query(&[("from", from), ("to", to)]))
            .await?;
        Ok(Comparison {
            commits: raw.commits.into_iter().rev().map(Commit::from).collect(),
            diffs: raw.diffs.into_iter().map(FileDiff::from).collect(),
        })
    }

    /// 自己在 `after`（YYYY-MM-DD，不含当天）之后的推送记录。
    /// 自己在 `(after, before)` 两个日期之间（都不含）的操作，按时间先后排列。
    pub async fn my_events(&self, after: &str, before: &str) -> Result<Vec<MyEvent>> {
        let raw: Vec<serde_json::Value> = self.all_pages(&["events"], &[("after", after), ("before", before)], 500).await?;
        let mut events: Vec<MyEvent> = raw.iter().filter_map(my_event).collect();
        events.sort_by(|a, b| a.at.cmp(&b.at));
        Ok(events)
    }

    pub async fn my_pushes(&self, after: &str) -> Result<Vec<PushEvent>> {
        let raw: Vec<serde_json::Value> =
            self.all_pages(&["events"], &[("action", "pushed"), ("after", after)], 500).await?;
        Ok(raw
            .into_iter()
            .filter_map(|e| {
                let push = &e["push_data"];
                Some(PushEvent {
                    project_id: e["project_id"].as_u64()?,
                    branch: push["ref"].as_str().unwrap_or_default().to_string(),
                    commit_title: push["commit_title"].as_str().unwrap_or_default().to_string(),
                    commit_count: push["commit_count"].as_u64().unwrap_or(0),
                    created_at: e["created_at"].as_str().unwrap_or_default().to_string(),
                })
            })
            .collect())
    }
}

fn image_mime(path: &str) -> Option<&'static str> {
    let ext = path.rsplit('.').next()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "bmp" => "image/bmp",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn converts_events_to_work_records() {
        let push = json!({ "action_name": "pushed to", "project_id": 7, "created_at": "2026-10-22T03:00:00.000Z",
            "push_data": { "ref": "feature-x", "commit_title": "修复导入", "commit_count": 2 } });
        let e = my_event(&push).unwrap();
        assert_eq!((e.kind.as_str(), e.title.as_str(), e.detail.as_str(), e.commit_count), ("push", "feature-x", "修复导入", 2));

        let merged = json!({ "action_name": "accepted", "target_type": "MergeRequest", "target_iid": 12, "target_title": "jira=ABC-1 修复", "project_id": 7, "created_at": "x" });
        let e = my_event(&merged).unwrap();
        assert_eq!((e.kind.as_str(), e.iid), ("mr_merge", Some(12)));

        let note = json!({ "action_name": "commented on", "target_type": "Note", "target_title": "jira=ABC-1 修复", "project_id": 7, "created_at": "x",
            "note": { "body": "看起来\n没问题", "noteable_type": "MergeRequest", "noteable_iid": 12 } });
        let e = my_event(&note).unwrap();
        assert_eq!((e.kind.as_str(), e.detail.as_str(), e.iid), ("comment", "看起来 没问题", Some(12)));

        assert!(my_event(&json!({ "action_name": "joined", "project_id": 7 })).is_none());
        assert!(my_event(&json!({ "action_name": "deleted", "project_id": 7, "push_data": { "commit_count": 0 } })).is_none());
    }
}
