//! 合并请求（Merge Request）：列表、详情、改动、讨论、审批、合并与新建。
//!
//! 项目参数既可以是数字 id，也可以是 `group/project` 路径（GitLab 接受编码后的路径作为 id），
//! 这样从链接跳转过来时不必先查项目 id。

use nextworkzone_core::http::check;
use nextworkzone_core::Result;
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{Commit, FileDiff, GitlabClient, RawCommit, RawDiff, User};

/// 列表和详情共用：列表接口不返回的字段（`diff_refs`、`head_pipeline` 等）为空。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase"))]
pub struct MergeRequest {
    pub id: u64,
    pub iid: u64,
    pub project_id: u64,
    pub title: String,
    #[serde(default, deserialize_with = "null_as_default")]
    pub description: String,
    /// `opened` / `merged` / `closed` / `locked`
    pub state: String,
    #[serde(default)]
    pub draft: bool,
    pub author: User,
    #[serde(default)]
    pub assignees: Vec<User>,
    #[serde(default)]
    pub reviewers: Vec<User>,
    pub source_branch: String,
    pub target_branch: String,
    pub source_project_id: Option<u64>,
    pub created_at: String,
    pub updated_at: String,
    pub merged_at: Option<String>,
    pub merged_by: Option<User>,
    pub closed_at: Option<String>,
    pub closed_by: Option<User>,
    /// `can_be_merged` / `cannot_be_merged` / `unchecked` / `checking` / `cannot_be_merged_recheck`
    #[serde(default)]
    pub merge_status: String,
    #[serde(default)]
    pub has_conflicts: bool,
    #[serde(default)]
    pub user_notes_count: u64,
    #[serde(default)]
    pub upvotes: u64,
    #[serde(default)]
    pub labels: Vec<String>,
    pub web_url: String,
    #[serde(default, deserialize_with = "full_reference", rename(deserialize = "references"))]
    pub reference: String,
    pub changes_count: Option<String>,
    pub sha: Option<String>,
    pub diff_refs: Option<DiffRefs>,
    pub head_pipeline: Option<Pipeline>,
    #[serde(default)]
    pub squash: bool,
    pub force_remove_source_branch: Option<bool>,
    #[serde(default = "yes")]
    pub blocking_discussions_resolved: bool,
    pub merge_error: Option<String>,
    #[serde(default)]
    pub merge_when_pipeline_succeeds: bool,
    /// 当前用户能否合并（仅详情接口返回）。
    #[serde(default, deserialize_with = "can_merge", rename(deserialize = "user"))]
    pub can_merge: bool,
}

fn yes() -> bool {
    true
}

fn null_as_default<'de, D: serde::Deserializer<'de>, T: Default + Deserialize<'de>>(d: D) -> std::result::Result<T, D::Error> {
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

fn full_reference<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<String, D::Error> {
    let v = Value::deserialize(d)?;
    Ok(v["full"].as_str().unwrap_or_default().to_string())
}

fn can_merge<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<bool, D::Error> {
    let v = Value::deserialize(d)?;
    Ok(v["can_merge"].as_bool().unwrap_or(false))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase"))]
pub struct DiffRefs {
    pub base_sha: String,
    pub head_sha: String,
    pub start_sha: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase"))]
pub struct Pipeline {
    pub id: u64,
    /// `success` / `failed` / `running` / `pending` / `canceled` / `skipped` / `manual` / `created` …
    pub status: String,
    pub web_url: Option<String>,
}

/// 行内评论在改动中的位置。前端原样带回，用于在同一位置新建评论。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotePosition {
    #[serde(alias = "base_sha")]
    pub base_sha: String,
    #[serde(alias = "start_sha")]
    pub start_sha: String,
    #[serde(alias = "head_sha")]
    pub head_sha: String,
    #[serde(alias = "old_path")]
    pub old_path: String,
    #[serde(alias = "new_path")]
    pub new_path: String,
    #[serde(alias = "old_line")]
    pub old_line: Option<u32>,
    #[serde(alias = "new_line")]
    pub new_line: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase"))]
pub struct Note {
    pub id: u64,
    pub body: String,
    pub author: User,
    pub created_at: String,
    pub updated_at: Option<String>,
    /// 系统记录（“批准了”“推送了新提交”等）
    #[serde(default)]
    pub system: bool,
    #[serde(default)]
    pub resolvable: bool,
    #[serde(default)]
    pub resolved: bool,
    pub resolved_by: Option<User>,
    /// 只解析文本行上的位置；图片等其他位置为空。
    #[serde(default, deserialize_with = "text_position")]
    pub position: Option<NotePosition>,
}

fn text_position<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Option<NotePosition>, D::Error> {
    let v = Value::deserialize(d)?;
    if v["position_type"].as_str() != Some("text") {
        return Ok(None);
    }
    Ok(serde_json::from_value(v).ok())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase"))]
pub struct Discussion {
    pub id: String,
    #[serde(default)]
    pub individual_note: bool,
    pub notes: Vec<Note>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Approvals {
    pub approved: bool,
    pub user_has_approved: bool,
    pub user_can_approve: bool,
    pub approved_by: Vec<User>,
}

#[derive(Debug, Deserialize)]
struct RawApprovals {
    #[serde(default)]
    approved: bool,
    #[serde(default)]
    user_has_approved: bool,
    #[serde(default)]
    user_can_approve: bool,
    #[serde(default)]
    approved_by: Vec<RawApprover>,
}

#[derive(Debug, Deserialize)]
struct RawApprover {
    user: User,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MrChanges {
    pub diffs: Vec<FileDiff>,
    /// 改动过多，GitLab 只返回了一部分。
    pub overflow: bool,
}

#[derive(Debug, Deserialize)]
struct RawChanges {
    #[serde(default)]
    changes: Vec<RawDiff>,
    #[serde(default)]
    overflow: bool,
}

/// 跨项目列表的范围。
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MrScope {
    /// 我发起的
    CreatedByMe,
    /// 指派给我的
    AssignedToMe,
    /// 请我审核的
    Reviewer,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MrQuery {
    /// `opened` / `merged` / `closed` / `all`
    pub state: Option<String>,
    pub search: Option<String>,
    pub source_branch: Option<String>,
    pub page: Option<u32>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MergeOptions {
    pub squash: bool,
    pub remove_source_branch: bool,
    /// 只在 MR 仍是这个提交时合并，避免合并到刚推送、尚未看过的改动。
    pub sha: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MrUpdate {
    pub title: Option<String>,
    pub description: Option<String>,
    pub target_branch: Option<String>,
    /// `close` / `reopen`
    pub state_event: Option<String>,
    pub remove_source_branch: Option<bool>,
    pub squash: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewMergeRequest {
    pub source_branch: String,
    pub target_branch: String,
    pub title: String,
    pub description: String,
    pub remove_source_branch: bool,
    pub squash: bool,
}

/// 每页条数。
const MR_PAGE_SIZE: &str = "30";

impl GitlabClient {
    fn mr_query(query: &MrQuery) -> Vec<(&'static str, String)> {
        let mut q = vec![
            ("state", query.state.clone().unwrap_or_else(|| "opened".into())),
            ("order_by", "updated_at".into()),
            ("per_page", MR_PAGE_SIZE.into()),
            ("page", query.page.unwrap_or(1).to_string()),
        ];
        if let Some(s) = query.search.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            q.push(("search", s.to_string()));
        }
        if let Some(b) = query.source_branch.as_deref().filter(|b| !b.is_empty()) {
            q.push(("source_branch", b.to_string()));
        }
        q
    }

    /// 跨项目的合并请求：我发起的、指派给我的或请我审核的。
    pub async fn merge_requests(&self, scope: MrScope, query: &MrQuery) -> Result<Vec<MergeRequest>> {
        let mut q = Self::mr_query(query);
        match scope {
            MrScope::CreatedByMe => q.push(("scope", "created_by_me".into())),
            MrScope::AssignedToMe => q.push(("scope", "assigned_to_me".into())),
            MrScope::Reviewer => {
                let me = self.current_user().await?;
                q.push(("scope", "all".into()));
                q.push(("reviewer_id", me.id.to_string()));
            }
        }
        self.json(self.get(&["merge_requests"])?.query(&q)).await
    }

    pub async fn project_merge_requests(&self, project: &str, query: &MrQuery) -> Result<Vec<MergeRequest>> {
        self.json(self.get(&["projects", project, "merge_requests"])?.query(&Self::mr_query(query))).await
    }

    pub async fn merge_request(&self, project: &str, iid: u64) -> Result<MergeRequest> {
        let iid = iid.to_string();
        self.json(self.get(&["projects", project, "merge_requests", &iid])?).await
    }

    pub async fn mr_changes(&self, project: &str, iid: u64) -> Result<MrChanges> {
        let iid = iid.to_string();
        // access_raw_diffs：不受网页端折叠大文件的限制
        let raw: RawChanges = self
            .json(self.get(&["projects", project, "merge_requests", &iid, "changes"])?.query(&[("access_raw_diffs", "true")]))
            .await?;
        Ok(MrChanges { diffs: raw.changes.into_iter().map(FileDiff::from).collect(), overflow: raw.overflow })
    }

    pub async fn mr_commits(&self, project: &str, iid: u64) -> Result<Vec<Commit>> {
        let iid = iid.to_string();
        let raw: Vec<RawCommit> = self.all_pages(&["projects", project, "merge_requests", &iid, "commits"], &[], 500).await?;
        Ok(raw.into_iter().map(Commit::from).collect())
    }

    pub async fn mr_discussions(&self, project: &str, iid: u64) -> Result<Vec<Discussion>> {
        let iid = iid.to_string();
        self.all_pages(&["projects", project, "merge_requests", &iid, "discussions"], &[], 2000).await
    }

    pub async fn mr_approvals(&self, project: &str, iid: u64) -> Result<Approvals> {
        let iid = iid.to_string();
        let raw: RawApprovals = self.json(self.get(&["projects", project, "merge_requests", &iid, "approvals"])?).await?;
        Ok(Approvals {
            approved: raw.approved,
            user_has_approved: raw.user_has_approved,
            user_can_approve: raw.user_can_approve,
            approved_by: raw.approved_by.into_iter().map(|a| a.user).collect(),
        })
    }

    // ---------- 写操作 ----------

    async fn send_json<T: serde::de::DeserializeOwned>(&self, method: Method, segments: &[&str], body: &Value) -> Result<T> {
        self.json(self.request(method, segments)?.json(body)).await
    }

    /// 发表普通评论（不针对代码行）。
    pub async fn mr_add_note(&self, project: &str, iid: u64, body: &str) -> Result<Discussion> {
        let iid = iid.to_string();
        self.send_json(Method::POST, &["projects", project, "merge_requests", &iid, "discussions"], &json!({ "body": body })).await
    }

    /// 在改动的某一行发表评论。
    pub async fn mr_add_diff_note(&self, project: &str, iid: u64, body: &str, position: &NotePosition) -> Result<Discussion> {
        let iid = iid.to_string();
        let mut pos = json!({
            "position_type": "text",
            "base_sha": position.base_sha,
            "start_sha": position.start_sha,
            "head_sha": position.head_sha,
            "old_path": position.old_path,
            "new_path": position.new_path,
        });
        if let Some(line) = position.old_line {
            pos["old_line"] = json!(line);
        }
        if let Some(line) = position.new_line {
            pos["new_line"] = json!(line);
        }
        self.send_json(
            Method::POST,
            &["projects", project, "merge_requests", &iid, "discussions"],
            &json!({ "body": body, "position": pos }),
        )
        .await
    }

    pub async fn mr_reply(&self, project: &str, iid: u64, discussion: &str, body: &str) -> Result<Note> {
        let iid = iid.to_string();
        self.send_json(
            Method::POST,
            &["projects", project, "merge_requests", &iid, "discussions", discussion, "notes"],
            &json!({ "body": body }),
        )
        .await
    }

    pub async fn mr_edit_note(&self, project: &str, iid: u64, note: u64, body: &str) -> Result<Note> {
        let (iid, note) = (iid.to_string(), note.to_string());
        self.send_json(Method::PUT, &["projects", project, "merge_requests", &iid, "notes", &note], &json!({ "body": body })).await
    }

    pub async fn mr_delete_note(&self, project: &str, iid: u64, note: u64) -> Result<()> {
        let (iid, note) = (iid.to_string(), note.to_string());
        check(self.request(Method::DELETE, &["projects", project, "merge_requests", &iid, "notes", &note])?.send().await?).await?;
        Ok(())
    }

    pub async fn mr_resolve(&self, project: &str, iid: u64, discussion: &str, resolved: bool) -> Result<Discussion> {
        let iid = iid.to_string();
        self.json(
            self.request(Method::PUT, &["projects", project, "merge_requests", &iid, "discussions", discussion])?
                .query(&[("resolved", resolved)]),
        )
        .await
    }

    pub async fn mr_approve(&self, project: &str, iid: u64, approve: bool) -> Result<Approvals> {
        let path_iid = iid.to_string();
        let action = if approve { "approve" } else { "unapprove" };
        check(self.request(Method::POST, &["projects", project, "merge_requests", &path_iid, action])?.send().await?).await?;
        self.mr_approvals(project, iid).await
    }

    pub async fn mr_merge(&self, project: &str, iid: u64, options: &MergeOptions) -> Result<MergeRequest> {
        let iid = iid.to_string();
        let mut body = json!({
            "squash": options.squash,
            "should_remove_source_branch": options.remove_source_branch,
        });
        if let Some(sha) = &options.sha {
            body["sha"] = json!(sha);
        }
        self.send_json(Method::PUT, &["projects", project, "merge_requests", &iid, "merge"], &body).await
    }

    pub async fn mr_update(&self, project: &str, iid: u64, update: &MrUpdate) -> Result<MergeRequest> {
        let iid = iid.to_string();
        let mut body = json!({});
        if let Some(v) = &update.title {
            body["title"] = json!(v);
        }
        if let Some(v) = &update.description {
            body["description"] = json!(v);
        }
        if let Some(v) = &update.target_branch {
            body["target_branch"] = json!(v);
        }
        if let Some(v) = &update.state_event {
            body["state_event"] = json!(v);
        }
        if let Some(v) = update.remove_source_branch {
            body["remove_source_branch"] = json!(v);
        }
        if let Some(v) = update.squash {
            body["squash"] = json!(v);
        }
        self.send_json(Method::PUT, &["projects", project, "merge_requests", &iid], &body).await
    }

    pub async fn mr_create(&self, project: &str, mr: &NewMergeRequest) -> Result<MergeRequest> {
        self.send_json(
            Method::POST,
            &["projects", project, "merge_requests"],
            &json!({
                "source_branch": mr.source_branch,
                "target_branch": mr.target_branch,
                "title": mr.title,
                "description": mr.description,
                "remove_source_branch": mr.remove_source_branch,
                "squash": mr.squash,
            }),
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_list_and_detail_shapes() {
        let list: MergeRequest = serde_json::from_value(json!({
            "id": 1, "iid": 586, "project_id": 4478, "title": "t", "description": null, "state": "merged",
            "author": {"id": 1, "username": "u", "name": "U"}, "source_branch": "a", "target_branch": "dev",
            "created_at": "x", "updated_at": "y", "web_url": "w", "references": {"full": "g/p!586"},
            "merge_status": "can_be_merged"
        }))
        .unwrap();
        assert_eq!(list.reference, "g/p!586");
        assert_eq!(list.description, "");
        assert!(!list.can_merge);
        assert!(list.blocking_discussions_resolved);

        let detail: MergeRequest = serde_json::from_value(json!({
            "id": 1, "iid": 586, "project_id": 4478, "title": "t", "description": "d", "state": "opened",
            "author": {"id": 1, "username": "u", "name": "U"}, "source_branch": "a", "target_branch": "dev",
            "created_at": "x", "updated_at": "y", "web_url": "w", "references": {"full": "g/p!586"},
            "user": {"can_merge": true}, "head_pipeline": {"id": 3, "status": "failed", "web_url": "p"},
            "diff_refs": {"base_sha": "b", "head_sha": "h", "start_sha": "s"}
        }))
        .unwrap();
        assert!(detail.can_merge);
        assert_eq!(detail.head_pipeline.unwrap().status, "failed");
    }

    #[test]
    fn parses_text_positions_only() {
        let note: Note = serde_json::from_value(json!({
            "id": 1, "body": "b", "author": {"id": 1, "username": "u", "name": "U"}, "created_at": "x",
            "position": {"position_type": "text", "base_sha": "b", "start_sha": "s", "head_sha": "h",
                         "old_path": "a.rs", "new_path": "a.rs", "old_line": null, "new_line": 12}
        }))
        .unwrap();
        let pos = note.position.unwrap();
        assert_eq!(pos.new_line, Some(12));
        assert_eq!(pos.old_line, None);
        // 序列化给前端用驼峰
        assert_eq!(serde_json::to_value(&pos).unwrap()["newPath"], "a.rs");

        let image: Note = serde_json::from_value(json!({
            "id": 2, "body": "b", "author": {"id": 1, "username": "u", "name": "U"}, "created_at": "x",
            "position": {"position_type": "image", "base_sha": "b"}
        }))
        .unwrap();
        assert!(image.position.is_none());
    }
}
