use nextworkzone_core::Result;
use nextworkzone_gitlab::{
    Approvals, Branch, Commit, CommitDetail, Comparison, Discussion, FileContent, MergeOptions, MergeRequest, MrChanges, MrQuery,
    MrScope, MrUpdate, NewMergeRequest, Note, NotePosition, Project, TreeEntry, User,
};

use crate::state::AppState;

const PROJECTS_CACHE_KEY: &str = "gitlab:projects";

/// 上一次的项目列表，用于界面秒开。
pub async fn gl_cached_projects(state: &AppState) -> Result<Option<Vec<Project>>> {
    Ok(state.cache.get(PROJECTS_CACHE_KEY))
}

pub async fn gl_projects(state: &AppState, search: Option<String>) -> Result<Vec<Project>> {
    let projects = state.gitlab()?.projects(search.as_deref(), 300).await?;
    if search.as_deref().is_none_or(|s| s.trim().is_empty()) {
        state.cache.put(PROJECTS_CACHE_KEY, &projects);
    }
    Ok(projects)
}

pub async fn gl_project(state: &AppState, id: u64) -> Result<Project> {
    state.gitlab()?.project(id).await
}

pub async fn gl_branches(state: &AppState, project: u64) -> Result<Vec<Branch>> {
    state.gitlab()?.branches(project, None).await
}

pub async fn gl_tree(state: &AppState, project: u64, git_ref: String, path: String) -> Result<Vec<TreeEntry>> {
    state.gitlab()?.tree(project, &git_ref, &path).await
}

pub async fn gl_file(state: &AppState, project: u64, git_ref: String, path: String) -> Result<FileContent> {
    state.gitlab()?.file(project, &git_ref, &path).await
}

pub async fn gl_commits(
    state: &AppState,
    project: u64,
    git_ref: String,
    path: Option<String>,
    page: u32,
) -> Result<Vec<Commit>> {
    state.gitlab()?.commits(project, &git_ref, path.as_deref(), page).await
}

pub async fn gl_commit(state: &AppState, project: u64, sha: String) -> Result<CommitDetail> {
    state.gitlab()?.commit(project, &sha).await
}

pub async fn gl_compare(state: &AppState, project: u64, from: String, to: String) -> Result<Comparison> {
    state.gitlab()?.compare(project, &from, &to).await
}

pub async fn gl_me(state: &AppState) -> Result<User> {
    state.gitlab()?.current_user().await
}

// ---------- 合并请求 ----------
// `project` 可以是数字 id 或 `group/project` 路径。

pub async fn gl_merge_requests(state: &AppState, scope: MrScope, query: MrQuery) -> Result<Vec<MergeRequest>> {
    state.gitlab()?.merge_requests(scope, &query).await
}

pub async fn gl_project_merge_requests(state: &AppState, project: String, query: MrQuery) -> Result<Vec<MergeRequest>> {
    state.gitlab()?.project_merge_requests(&project, &query).await
}

pub async fn gl_merge_request(state: &AppState, project: String, iid: u64) -> Result<MergeRequest> {
    state.gitlab()?.merge_request(&project, iid).await
}

pub async fn gl_mr_changes(state: &AppState, project: String, iid: u64) -> Result<MrChanges> {
    state.gitlab()?.mr_changes(&project, iid).await
}

pub async fn gl_mr_commits(state: &AppState, project: String, iid: u64) -> Result<Vec<Commit>> {
    state.gitlab()?.mr_commits(&project, iid).await
}

pub async fn gl_mr_discussions(state: &AppState, project: String, iid: u64) -> Result<Vec<Discussion>> {
    state.gitlab()?.mr_discussions(&project, iid).await
}

pub async fn gl_mr_approvals(state: &AppState, project: String, iid: u64) -> Result<Approvals> {
    state.gitlab()?.mr_approvals(&project, iid).await
}

pub async fn gl_mr_add_note(
    state: &AppState,
    project: String,
    iid: u64,
    body: String,
    position: Option<NotePosition>,
) -> Result<Discussion> {
    let gitlab = state.gitlab()?;
    match position {
        Some(position) => gitlab.mr_add_diff_note(&project, iid, &body, &position).await,
        None => gitlab.mr_add_note(&project, iid, &body).await,
    }
}

pub async fn gl_mr_reply(state: &AppState, project: String, iid: u64, discussion: String, body: String) -> Result<Note> {
    state.gitlab()?.mr_reply(&project, iid, &discussion, &body).await
}

pub async fn gl_mr_edit_note(state: &AppState, project: String, iid: u64, note: u64, body: String) -> Result<Note> {
    state.gitlab()?.mr_edit_note(&project, iid, note, &body).await
}

pub async fn gl_mr_delete_note(state: &AppState, project: String, iid: u64, note: u64) -> Result<()> {
    state.gitlab()?.mr_delete_note(&project, iid, note).await
}

pub async fn gl_mr_resolve(state: &AppState, project: String, iid: u64, discussion: String, resolved: bool) -> Result<Discussion> {
    state.gitlab()?.mr_resolve(&project, iid, &discussion, resolved).await
}

pub async fn gl_mr_approve(state: &AppState, project: String, iid: u64, approve: bool) -> Result<Approvals> {
    state.gitlab()?.mr_approve(&project, iid, approve).await
}

pub async fn gl_mr_merge(state: &AppState, project: String, iid: u64, options: MergeOptions) -> Result<MergeRequest> {
    state.gitlab()?.mr_merge(&project, iid, &options).await
}

pub async fn gl_mr_update(state: &AppState, project: String, iid: u64, update: MrUpdate) -> Result<MergeRequest> {
    state.gitlab()?.mr_update(&project, iid, &update).await
}

pub async fn gl_mr_create(state: &AppState, project: String, mr: NewMergeRequest) -> Result<MergeRequest> {
    state.gitlab()?.mr_create(&project, &mr).await
}
