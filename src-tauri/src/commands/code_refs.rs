//! 问题与代码的关联（只读）。
//!
//! 问题 → 代码：描述、评论中的 GitLab 链接（分支、提交、合并请求），标题或描述含问题键的合并请求，
//! 以及相关项目里提交说明含问题键的提交（GitLab 只搜索默认分支）。
//! 代码 → 问题：本机问题库中链接了这个分支、提交或合并请求的问题，以及标题、分支名、提交说明中的问题键。

use std::collections::HashMap;
use std::sync::Arc;

use chrono::{DateTime, Duration, FixedOffset};
use nextworkzone_core::Result;
use nextworkzone_gitlab::links::{self, GitlabLink, LinkTarget};
use nextworkzone_gitlab::{Commit, GitlabClient, MergeRequest, Project};
use nextworkzone_jira::index::IssueHit;
use nextworkzone_jira::parse_time;
use serde::{Deserialize, Serialize};
use tauri::State;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

use super::jira_index::blocking;
use crate::state::AppState;

/// 每个问题最多解析的链接数。
const MAX_LINKS: usize = 20;
/// 同时进行的 GitLab 请求数。
const CONCURRENCY: usize = 4;
/// 分支链接：取评论前后这段时间内的提交。
const WINDOW_BEFORE_DAYS: i64 = 3;
const WINDOW_AFTER_DAYS: i64 = 1;
const WINDOW_COMMITS: usize = 30;
/// 按提交说明搜索问题键的项目数上限。
const MAX_SEARCH_PROJECTS: usize = 5;
const MAX_SEARCH_MRS: usize = 20;
const BRANCH_CANDIDATES: usize = 6;
/// 代码 → 问题：最多列出的问题数。
const MAX_RELATED: u32 = 20;
const MAX_KEY_LOOKUPS: usize = 5;

/// 问题中的一段正文（描述或一条评论）。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueText {
    /// `description` / `comment`
    source: String,
    comment_id: Option<String>,
    /// 作者的显示名。
    author: Option<String>,
    at: Option<String>,
    html: String,
}

/// 找到这条关联的线索。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RefSource {
    /// `description` 描述中的链接 / `comment` 评论中的链接 / `mrSearch` 合并请求的标题或描述含问题键 /
    /// `commitSearch` 提交说明含问题键
    kind: String,
    author: Option<String>,
    at: Option<String>,
    comment_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodeRef {
    /// `mr` / `branch` / `commit` / `external`（其他 GitLab 实例，只有地址）
    kind: String,
    url: String,
    project_id: Option<u64>,
    project_path: String,
    project_name: String,
    branch: Option<String>,
    sha: Option<String>,
    iid: Option<u64>,
    /// 合并请求标题、提交标题，或分支最近一次提交的标题。
    title: String,
    /// 合并请求：`opened` / `merged` / `closed` / `locked`；分支：`merged` / `missing`；提交：`missing`。
    state: Option<String>,
    /// 合并请求最近一次流水线的状态。
    pipeline: Option<String>,
    author: Option<String>,
    at: Option<String>,
    /// 分支：线索时间前后的提交，提交说明含问题键的、线索作者的在前。
    commits: Vec<Commit>,
    /// 无法访问时的说明（没有权限、已删除）。
    unavailable: Option<String>,
    sources: Vec<RefSource>,
}

impl CodeRef {
    fn new(kind: &str, url: String, project_path: String, sources: Vec<RefSource>) -> Self {
        CodeRef {
            kind: kind.into(),
            url,
            project_id: None,
            project_name: project_path.rsplit('/').next().unwrap_or_default().to_string(),
            project_path,
            branch: None,
            sha: None,
            iid: None,
            title: String::new(),
            state: None,
            pipeline: None,
            author: None,
            at: None,
            commits: Vec::new(),
            unavailable: None,
            sources,
        }
    }

    fn with_project(mut self, project: &Project) -> Self {
        self.project_id = Some(project.id);
        self.project_path = project.path_with_namespace.clone();
        self.project_name = project.name.clone();
        self
    }

    /// 合并两条指向同一对象的关联时用的键。
    fn identity(&self) -> String {
        let project = self.project_id.map_or_else(|| self.project_path.to_lowercase(), |id| id.to_string());
        match self.kind.as_str() {
            "mr" => format!("mr:{project}!{}", self.iid.unwrap_or_default()),
            "branch" => format!("branch:{project}:{}", self.branch.as_deref().unwrap_or_default()),
            "commit" => format!("commit:{project}@{}", self.sha.as_deref().map(|s| &s[..s.len().min(12)]).unwrap_or_default()),
            _ => format!("url:{}", self.url),
        }
    }
}

/// 待解析的一条关联。
enum Pending {
    Link { link: GitlabLink, url: String, sources: Vec<RefSource> },
    Mr { mr: Box<MergeRequest>, sources: Vec<RefSource> },
    Commit { project: Box<Project>, commit: Box<Commit>, sources: Vec<RefSource> },
}

/// 链接、合并请求、提交中提到的项目，按路径（小写）查一次。
#[derive(Default)]
struct Projects {
    by_path: HashMap<String, Option<Project>>,
}

impl Projects {
    async fn load(&mut self, gitlab: &GitlabClient, paths: Vec<String>) {
        let mut set = JoinSet::new();
        let sem = Arc::new(Semaphore::new(CONCURRENCY));
        for path in paths {
            let key = path.to_lowercase();
            if self.by_path.contains_key(&key) {
                continue;
            }
            self.by_path.insert(key.clone(), None);
            let (gitlab, sem) = (gitlab.clone(), sem.clone());
            set.spawn(async move {
                let _permit = sem.acquire_owned().await;
                (key, gitlab.project_by_path(&path).await.ok())
            });
        }
        while let Some(Ok((key, project))) = set.join_next().await {
            self.by_path.insert(key, project);
        }
    }

    fn get(&self, path: &str) -> Option<&Project> {
        self.by_path.get(&path.to_lowercase()).and_then(Option::as_ref)
    }
}

fn time_of(s: &str) -> Option<DateTime<FixedOffset>> {
    parse_time(s).or_else(|| DateTime::parse_from_rfc3339(s).ok())
}

/// 合并请求的项目路径（从网页地址中取，列表接口不返回路径）。
fn mr_project_path(base: &str, mr: &MergeRequest) -> Option<String> {
    links::parse_link(base, &mr.web_url).map(|l| l.project_path)
}

/// 问题中提到的代码：分支、提交、合并请求。
#[tauri::command]
pub async fn issue_code_refs(state: State<'_, AppState>, key: String, texts: Vec<IssueText>) -> Result<Vec<CodeRef>> {
    let gitlab = state.gitlab().ok();
    let base = gitlab.as_ref().map(|g| g.base_url().trim_end_matches('/').to_string()).unwrap_or_default();

    // 1. 正文中的链接
    let mut pending: Vec<Pending> = Vec::new();
    let mut externals: Vec<CodeRef> = Vec::new();
    let mut seen_links: HashMap<String, usize> = HashMap::new();
    for text in &texts {
        let source = RefSource {
            kind: if text.source == "description" { "description".into() } else { "comment".into() },
            author: text.author.clone(),
            at: text.at.clone(),
            comment_id: text.comment_id.clone(),
        };
        for url in links::extract_urls(&text.html) {
            let parsed = if base.is_empty() { None } else { links::parse_link(&base, &url) };
            match parsed {
                Some(link) => {
                    let id = format!("{}|{:?}", link.project_path.to_lowercase(), link.target);
                    if let Some(&i) = seen_links.get(&id) {
                        if let Pending::Link { sources, .. } = &mut pending[i] {
                            sources.push(source.clone());
                        }
                    } else if seen_links.len() < MAX_LINKS {
                        seen_links.insert(id, pending.len());
                        pending.push(Pending::Link { link, url, sources: vec![source.clone()] });
                    }
                }
                None if links::looks_like_gitlab(&url) => {
                    if let Some(existing) = externals.iter_mut().find(|e| e.url == url) {
                        existing.sources.push(source.clone());
                    } else {
                        let path = url.split_once("://").map(|(_, r)| r.split("/-/").next().unwrap_or(r).to_string()).unwrap_or_default();
                        externals.push(CodeRef::new("external", url, path, vec![source.clone()]));
                    }
                }
                None => {}
            }
        }
    }

    let Some(gitlab) = gitlab else {
        return Ok(externals);
    };

    // 2. 标题或描述中含问题键的合并请求
    let mrs: Vec<MergeRequest> = gitlab.search_merge_requests(&key, MAX_SEARCH_MRS).await.unwrap_or_default();
    for mr in mrs.into_iter().filter(|m| links::mentions_key(&format!("{} {} {}", m.title, m.source_branch, m.description), &key)) {
        let source = RefSource { kind: "mrSearch".into(), author: Some(mr.author.name.clone()), at: Some(mr.created_at.clone()), comment_id: None };
        pending.push(Pending::Mr { mr: Box::new(mr), sources: vec![source] });
    }

    // 3. 查出涉及的项目
    let mut projects = Projects::default();
    let mut paths: Vec<String> = Vec::new();
    for p in &pending {
        match p {
            Pending::Link { link, .. } => paths.push(link.project_path.clone()),
            Pending::Mr { mr, .. } => paths.extend(mr_project_path(&base, mr)),
            Pending::Commit { .. } => {}
        }
    }
    projects.load(&gitlab, paths.clone()).await;

    // 4. 这些项目中提交说明含问题键的提交
    let mut search_projects: Vec<Project> = Vec::new();
    for path in &paths {
        if let Some(p) = projects.get(path)
            && !search_projects.iter().any(|s| s.id == p.id)
            && search_projects.len() < MAX_SEARCH_PROJECTS
        {
            search_projects.push(p.clone());
        }
    }
    let mut set = JoinSet::new();
    for project in search_projects {
        let (gitlab, key) = (gitlab.clone(), key.clone());
        set.spawn(async move {
            let commits = gitlab.search_commits(project.id, &key, 20).await.unwrap_or_default();
            (project, commits)
        });
    }
    while let Some(Ok((project, commits))) = set.join_next().await {
        for commit in commits.into_iter().filter(|c| links::mentions_key(&c.message, &key) || links::mentions_key(&c.title, &key)) {
            let source = RefSource { kind: "commitSearch".into(), author: Some(commit.author_name.clone()), at: Some(commit.authored_date.clone()), comment_id: None };
            pending.push(Pending::Commit { project: Box::new(project.clone()), commit: Box::new(commit), sources: vec![source] });
        }
    }

    // 5. 逐条取详情
    let sem = Arc::new(Semaphore::new(CONCURRENCY));
    let mut set = JoinSet::new();
    for (order, item) in pending.into_iter().enumerate() {
        let (gitlab, sem, base, key) = (gitlab.clone(), sem.clone(), base.clone(), key.clone());
        let project = match &item {
            Pending::Link { link, .. } => projects.get(&link.project_path).cloned(),
            Pending::Mr { mr, .. } => mr_project_path(&base, mr).and_then(|p| projects.get(&p).cloned()),
            Pending::Commit { project, .. } => Some((**project).clone()),
        };
        set.spawn(async move {
            let _permit = sem.acquire_owned().await;
            (order, resolve(&gitlab, item, project, &key).await)
        });
    }
    let mut resolved: Vec<(usize, CodeRef)> = Vec::new();
    while let Some(Ok(item)) = set.join_next().await {
        resolved.push(item);
    }
    resolved.sort_by_key(|(order, _)| *order);

    // 6. 合并指向同一对象的关联
    let mut refs: Vec<CodeRef> = Vec::new();
    for (_, r) in resolved {
        // 短提交号的链接与完整提交号的搜索结果按前缀合并
        let existing = refs.iter_mut().find(|e| {
            e.identity() == r.identity()
                || (e.kind == "commit" && r.kind == "commit" && e.project_id == r.project_id && same_commit(e.sha.as_deref(), r.sha.as_deref()))
        });
        match existing {
            Some(e) => {
                e.sources.extend(r.sources);
                if e.unavailable.is_some() && r.unavailable.is_none() {
                    let sources = std::mem::take(&mut e.sources);
                    *e = CodeRef { sources, ..r };
                }
            }
            None => refs.push(r),
        }
    }
    refs.sort_by_key(|r| match r.kind.as_str() {
        "mr" => 0,
        "branch" => 1,
        _ => 2,
    });
    refs.extend(externals);
    Ok(refs)
}

fn same_commit(a: Option<&str>, b: Option<&str>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) if a.len() >= 7 && b.len() >= 7 => a.starts_with(b) || b.starts_with(a),
        _ => false,
    }
}

const UNAVAILABLE_PROJECT: &str = "无法访问这个项目（没有权限或已删除）";

async fn resolve(gitlab: &GitlabClient, item: Pending, project: Option<Project>, key: &str) -> CodeRef {
    match item {
        Pending::Mr { mr, sources } => {
            let path = project.as_ref().map(|p| p.path_with_namespace.clone()).unwrap_or_default();
            let mut r = CodeRef::new("mr", mr.web_url.clone(), path, sources);
            if let Some(p) = &project {
                r = r.with_project(p);
            }
            r.project_id = Some(mr.project_id);
            // 列表接口不带流水线，取一次详情
            let detail = gitlab.merge_request(&mr.project_id.to_string(), mr.iid).await.map(Box::new).unwrap_or(mr);
            fill_mr(&mut r, &detail);
            r
        }
        Pending::Commit { project, commit, sources } => {
            let url = commit.web_url.clone().unwrap_or_else(|| format!("{}/-/commit/{}", project.web_url, commit.id));
            let mut r = CodeRef::new("commit", url, String::new(), sources).with_project(&project);
            fill_commit(&mut r, &commit);
            r
        }
        Pending::Link { link, url, sources } => {
            let kind = match link.target {
                LinkTarget::Branch { .. } => "branch",
                LinkTarget::Commit { .. } => "commit",
                LinkTarget::MergeRequest { .. } => "mr",
            };
            let mut r = CodeRef::new(kind, url, link.project_path.clone(), sources);
            let Some(project) = project else {
                match &link.target {
                    LinkTarget::Branch { rest } => r.branch = Some(rest.clone()),
                    LinkTarget::Commit { sha } => r.sha = Some(sha.clone()),
                    LinkTarget::MergeRequest { iid } => r.iid = Some(*iid),
                }
                r.unavailable = Some(UNAVAILABLE_PROJECT.into());
                return r;
            };
            r = r.with_project(&project);
            match link.target {
                LinkTarget::MergeRequest { iid } => {
                    r.iid = Some(iid);
                    match gitlab.merge_request(&project.id.to_string(), iid).await {
                        Ok(mr) => fill_mr(&mut r, &mr),
                        Err(_) => r.unavailable = Some("无法读取这个合并请求".into()),
                    }
                }
                LinkTarget::Commit { sha } => {
                    r.sha = Some(sha.clone());
                    match gitlab.commit_info(project.id, &sha).await {
                        Ok(commit) => fill_commit(&mut r, &commit),
                        Err(_) => r.state = Some("missing".into()),
                    }
                }
                LinkTarget::Branch { rest } => resolve_branch(gitlab, &mut r, &project, &rest, key).await,
            }
            r
        }
    }
}

fn fill_mr(r: &mut CodeRef, mr: &MergeRequest) {
    r.iid = Some(mr.iid);
    r.title = mr.title.clone();
    r.state = Some(mr.state.clone());
    r.pipeline = mr.head_pipeline.as_ref().map(|p| p.status.clone());
    r.author = Some(mr.author.name.clone());
    r.at = Some(mr.merged_at.clone().unwrap_or_else(|| mr.updated_at.clone()));
    r.branch = Some(mr.source_branch.clone());
    r.url = mr.web_url.clone();
}

fn fill_commit(r: &mut CodeRef, commit: &Commit) {
    r.sha = Some(commit.id.clone());
    r.title = commit.title.clone();
    r.author = Some(commit.author_name.clone());
    r.at = Some(commit.authored_date.clone());
}

/// 分支链接：确定分支名（分支名可以含 `/`），再取线索时间前后的提交。
/// 提交说明含问题键的排在最前，其次是线索作者（评论人）的提交。
async fn resolve_branch(gitlab: &GitlabClient, r: &mut CodeRef, project: &Project, rest: &str, key: &str) {
    let mut found = None;
    for name in links::branch_candidates(rest, BRANCH_CANDIDATES) {
        if let Ok(Some(branch)) = gitlab.branch(project.id, &name).await {
            found = Some(branch);
            break;
        }
    }
    let Some(branch) = found else {
        // 分支已删除（常见于合并后）：只保留名称
        r.branch = Some(links::branch_candidates(rest, BRANCH_CANDIDATES).last().cloned().unwrap_or_else(|| rest.to_string()));
        r.state = Some("missing".into());
        return;
    };
    r.branch = Some(branch.name.clone());
    if branch.merged {
        r.state = Some("merged".into());
    }
    r.title = branch.commit.title.clone();
    r.author = Some(branch.commit.author_name.clone());
    r.at = Some(branch.commit.authored_date.clone());

    let times: Vec<DateTime<FixedOffset>> = r.sources.iter().filter_map(|s| s.at.as_deref().and_then(time_of)).collect();
    let (Some(first), Some(last)) = (times.iter().min(), times.iter().max()) else {
        return;
    };
    let since = (*first - Duration::days(WINDOW_BEFORE_DAYS)).to_rfc3339();
    let until = (*last + Duration::days(WINDOW_AFTER_DAYS)).to_rfc3339();
    let mut commits = gitlab.commits_between(project.id, &branch.name, &since, &until, WINDOW_COMMITS).await.unwrap_or_default();
    // 合并提交不是具体改动
    commits.retain(|c| !c.title.starts_with("Merge branch ") && !c.title.starts_with("Merge remote-tracking branch "));
    let authors: Vec<&str> = r.sources.iter().filter_map(|s| s.author.as_deref()).collect();
    commits.sort_by_key(|c| (!links::mentions_key(&c.message, key), !authors.contains(&c.author_name.as_str())));
    r.commits = commits;
}

// ---------- 代码 → 问题 ----------

/// 一个分支、提交或合并请求。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodeTarget {
    project_path: String,
    branch: Option<String>,
    sha: Option<String>,
    iid: Option<u64>,
    /// 标题、分支名、提交说明等，从中找问题键。
    text: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelatedIssue {
    #[serde(flatten)]
    hit: IssueHit,
    /// `key` 标题、分支名或提交说明中的问题键 / `link` 问题中链接了它
    via: String,
}

/// 提到这个分支、提交或合并请求的问题。
#[tauri::command]
pub async fn code_related_issues(state: State<'_, AppState>, target: CodeTarget) -> Result<Vec<RelatedIssue>> {
    let mut out: Vec<RelatedIssue> = Vec::new();
    let keys = links::issue_keys(&target.text);

    // 问题键：先查本机问题库，没有的再问 Jira（不存在的键会被忽略）
    if !keys.is_empty() {
        let lookup = keys.clone();
        let hits = blocking(&state.issue_index, move |i| i.by_keys(&lookup)).await.unwrap_or_default();
        let missing: Vec<String> = keys.iter().filter(|k| !hits.iter().any(|h| &h.issue.key == *k)).take(MAX_KEY_LOOKUPS).cloned().collect();
        out.extend(hits.into_iter().map(|hit| RelatedIssue { hit, via: "key".into() }));
        if !missing.is_empty()
            && let Ok(jira) = state.jira()
        {
            for key in missing {
                if let Ok(result) = jira.search(&format!("key = {key}"), 0, 1).await {
                    out.extend(result.issues.into_iter().map(|issue| RelatedIssue {
                        hit: IssueHit { issue, resolved: None, comment_count: 0, snippet: None, last_comments: Vec::new() },
                        via: "key".into(),
                    }));
                }
            }
        }
        // 按键在正文中出现的顺序
        out.sort_by_key(|r| keys.iter().position(|k| *k == r.hit.issue.key).unwrap_or(usize::MAX));
    }

    // 链接：本机问题库中描述或评论链接了它的问题
    if let Ok(gitlab) = state.gitlab() {
        let base = gitlab.base_url().trim_end_matches('/').to_string();
        let path = target.project_path.to_lowercase();
        let needles: Vec<String> = match (&target.branch, &target.sha, target.iid) {
            (_, _, Some(iid)) => vec![format!("{path}/-/merge_requests/{iid}"), format!("{path}/merge_requests/{iid}")],
            (_, Some(sha), _) if sha.len() >= 7 => {
                let short = sha[..7].to_lowercase();
                vec![format!("{path}/-/commit/{short}"), format!("{path}/commit/{short}")]
            }
            (Some(branch), _, _) => {
                let b = branch.to_lowercase();
                vec![format!("{path}/-/tree/{b}"), format!("{path}/tree/{b}"), format!("{path}/-/commits/{b}"), format!("{path}/commits/{b}")]
            }
            _ => Vec::new(),
        };
        if !needles.is_empty() {
            let accept = {
                let (branch, sha, iid) = (target.branch.clone(), target.sha.clone().map(|s| s.to_lowercase()), target.iid);
                move |text: &str| {
                    links::extract_urls(text).iter().filter_map(|u| links::parse_link(&base, u)).any(|l| {
                        l.project_path.to_lowercase() == path
                            && match (&l.target, iid, &sha, &branch) {
                                (LinkTarget::MergeRequest { iid: a }, Some(b), _, _) => *a == b,
                                (LinkTarget::Commit { sha: a }, None, Some(b), _) => same_commit(Some(a), Some(b)),
                                (LinkTarget::Branch { rest }, None, None, Some(b)) => links::branch_candidates(rest, BRANCH_CANDIDATES).contains(b),
                                _ => false,
                            }
                    })
                }
            };
            let hits = blocking(&state.issue_index, move |i| i.mentioning(&needles, accept, MAX_RELATED)).await.unwrap_or_default();
            for hit in hits {
                if !out.iter().any(|r| r.hit.issue.key == hit.issue.key) {
                    out.push(RelatedIssue { hit, via: "link".into() });
                }
            }
        }
    }
    out.truncate(MAX_RELATED as usize);
    Ok(out)
}
