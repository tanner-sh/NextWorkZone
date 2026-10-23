//! Jira Server / Data Center 适配器（REST API v2，Bearer PAT 认证）。

mod activity;
mod fields;
pub mod index;
mod meta;
mod model;

use std::path::Path;

use nextworkzone_core::http::check;
use nextworkzone_core::{ConnectionInfo, Error, Result, Service};
use reqwest::{Client, RequestBuilder};
use serde::Deserialize;
use serde_json::{Value, json};

pub use activity::{ActivityEvent, MyAction, parse_time};
pub use model::*;

pub struct JiraClient {
    http: Client,
    base_url: String,
    token: String,
}

/// 列表视图需要的字段，避免一次拉取全部字段。
const LIST_FIELDS: &[&str] = &[
    "summary", "status", "issuetype", "priority", "project", "updated", "created", "duedate",
    "assignee", "reporter", "resolution", "lastViewed",
];

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServerInfo {
    version: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Myself {
    name: String,
    display_name: String,
}

impl JiraClient {
    pub fn new(http: Client, base_url: impl Into<String>, token: impl Into<String>) -> Self {
        Self { http, base_url: base_url.into(), token: token.into() }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    fn url(&self, path: &str) -> String {
        if path.starts_with("http://") || path.starts_with("https://") {
            path.to_string()
        } else {
            format!("{}{}", self.base_url, path)
        }
    }

    fn get(&self, path: &str) -> RequestBuilder {
        self.http.get(self.url(path)).bearer_auth(&self.token)
    }

    fn post(&self, path: &str) -> RequestBuilder {
        self.http.post(self.url(path)).bearer_auth(&self.token)
    }

    fn put(&self, path: &str) -> RequestBuilder {
        self.http.put(self.url(path)).bearer_auth(&self.token)
    }

    fn delete(&self, path: &str) -> RequestBuilder {
        self.http.delete(self.url(path)).bearer_auth(&self.token)
    }

    async fn get_json(&self, request: RequestBuilder) -> Result<Value> {
        Ok(check(request.send().await?).await?.json().await?)
    }

    /// 问题上指向 Confluence 页面的远程链接（页面中用 Jira 宏引用问题时由 Confluence 自动创建），返回页面 id。
    /// 链接里的地址可能是 Wiki 的旧域名，因此从 `globalId`（`appId=…&pageId=…`）或地址中取页面 id。
    pub async fn wiki_page_links(&self, key: &str) -> Result<Vec<String>> {
        let raw = self.get_json(self.get(&format!("/rest/api/2/issue/{key}/remotelink"))).await?;
        let mut ids: Vec<String> = Vec::new();
        for link in raw.as_array().into_iter().flatten() {
            if link["application"]["type"] != "com.atlassian.confluence" {
                continue;
            }
            let from_global = link["globalId"].as_str().and_then(|g| g.split('&').find_map(|p| p.strip_prefix("pageId=")));
            let from_url = link["object"]["url"].as_str().and_then(|u| u.split("pageId=").nth(1)).map(|r| r.split(['&', '#']).next().unwrap_or(r));
            if let Some(id) = from_global.or(from_url).filter(|id| !id.is_empty() && id.chars().all(|c| c.is_ascii_digit()))
                && !ids.iter().any(|x| x == id) {
                    ids.push(id.to_string());
                }
        }
        Ok(ids)
    }

    /// 任意只读 GET 请求（调试工具使用）。
    pub async fn get_path(&self, path: &str) -> Result<Value> {
        self.get_json(self.get(path)).await
    }

    /// 当前用户的用户名。
    pub async fn my_username(&self) -> Result<String> {
        let me: Myself = check(self.get("/rest/api/2/myself").send().await?).await?.json().await?;
        Ok(me.name)
    }

    pub async fn connection_info(&self) -> Result<ConnectionInfo> {
        let me: Myself = check(self.get("/rest/api/2/myself").send().await?).await?.json().await?;
        let info: ServerInfo =
            check(self.get("/rest/api/2/serverInfo").send().await?).await?.json().await?;
        Ok(ConnectionInfo {
            service: Service::Jira,
            username: me.name,
            display_name: me.display_name,
            server_version: Some(info.version),
        })
    }

    /// 按 JQL 搜索，返回列表视图所需的精简数据。
    /// 使用 GET（只读、可安全重试），JQL 放在查询参数中。
    pub async fn search(&self, jql: &str, start_at: u32, max_results: u32) -> Result<SearchResult> {
        self.search_with_fields(jql, start_at, max_results, &[]).await
    }

    /// 同 [`search`](Self::search)，并带回 `extra` 中列出的字段（显示为文本）。
    pub async fn search_with_fields(&self, jql: &str, start_at: u32, max_results: u32, extra: &[String]) -> Result<SearchResult> {
        let mut fields: Vec<&str> = LIST_FIELDS.to_vec();
        fields.extend(extra.iter().map(String::as_str));
        let raw: Value = check(
            self.get("/rest/api/2/search")
                .query(&[
                    ("jql", jql),
                    ("startAt", &start_at.to_string()),
                    ("maxResults", &max_results.to_string()),
                    ("fields", &fields.join(",")),
                ])
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        let mut issues = Vec::new();
        for item in raw["issues"].as_array().into_iter().flatten() {
            let mut issue = IssueSummary::from_raw(serde_json::from_value::<RawIssue>(item.clone())?);
            for id in extra {
                let text = fields::value_text(&item["fields"][id.as_str()]);
                if !text.is_empty() {
                    issue.extra.insert(id.clone(), text);
                }
            }
            issues.push(issue);
        }
        Ok(SearchResult { total: raw["total"].as_u64().unwrap_or(0) as u32, issues })
    }

    /// 可以在列表中显示的字段（按名称排序）。
    pub async fn list_fields(&self) -> Result<Vec<FieldInfo>> {
        let raw = self.get_json(self.get("/rest/api/2/field")).await?;
        let mut list: Vec<FieldInfo> = raw
            .as_array()
            .into_iter()
            .flatten()
            .filter(|f| f["navigable"].as_bool().unwrap_or(false))
            .map(|f| FieldInfo {
                id: fields::value_text(&f["id"]),
                name: fields::value_text(&f["name"]),
                custom: f["custom"].as_bool().unwrap_or(false),
                kind: fields::value_text(&f["schema"]["type"]),
            })
            .collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(list)
    }

    pub async fn issue(&self, key: &str) -> Result<IssueDetail> {
        let raw: Value = check(
            self.get(&format!("/rest/api/2/issue/{key}"))
                // editmeta 给出问题界面上的字段及顺序，详情按它显示（与网页一致）
                .query(&[("expand", "renderedFields,names,schema,editmeta")])
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        IssueDetail::from_raw(raw)
    }

    pub async fn transitions(&self, key: &str) -> Result<Vec<Transition>> {
        let raw: Value = check(
            self.get(&format!("/rest/api/2/issue/{key}/transitions"))
                .query(&[("expand", "transitions.fields")])
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        Ok(fields::parse_transitions(&raw))
    }

    /// 执行状态流转。`fields` 是流转界面上字段的取值（已按 Jira 要求的格式构造）。
    pub async fn transition(&self, key: &str, transition_id: &str, fields: Value) -> Result<()> {
        let mut body = json!({ "transition": { "id": transition_id } });
        if fields.as_object().is_some_and(|f| !f.is_empty()) {
            body["fields"] = fields;
        }
        check(
            self.post(&format!("/rest/api/2/issue/{key}/transitions")).json(&body).send().await?,
        )
        .await?;
        Ok(())
    }

    /// 添加评论。`body` 使用 Jira wiki markup，`visibility` 为空表示所有用户可见；返回渲染后的评论。
    pub async fn add_comment(&self, key: &str, body: &str, visibility: Option<&CommentVisibility>) -> Result<Comment> {
        let created: RawComment = check(
            self.post(&format!("/rest/api/2/issue/{key}/comment"))
                .query(&[("expand", "renderedBody")])
                .json(&comment_body(body, visibility))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        Ok(Comment::from_raw(created, None))
    }

    /// 修改评论（同时提交可见范围，保持不变或按需修改），返回渲染后的评论。
    pub async fn update_comment(&self, key: &str, id: &str, body: &str, visibility: Option<&CommentVisibility>) -> Result<Comment> {
        let updated: RawComment = check(
            self.put(&format!("/rest/api/2/issue/{key}/comment/{id}"))
                .query(&[("expand", "renderedBody")])
                .json(&comment_body(body, visibility))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        Ok(Comment::from_raw(updated, None))
    }

    pub async fn delete_comment(&self, key: &str, id: &str) -> Result<()> {
        check(self.delete(&format!("/rest/api/2/issue/{key}/comment/{id}")).send().await?).await?;
        Ok(())
    }

    /// 上传本地文件作为附件。
    pub async fn upload_attachment(&self, key: &str, path: &Path) -> Result<Vec<Attachment>> {
        let bytes = std::fs::read(path)?;
        let file_name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .ok_or_else(|| Error::Io(std::io::Error::other("无效的文件路径")))?;
        let part = reqwest::multipart::Part::bytes(bytes).file_name(file_name);
        let form = reqwest::multipart::Form::new().part("file", part);
        let created: Vec<RawAttachment> = check(
            self.post(&format!("/rest/api/2/issue/{key}/attachments"))
                // Jira 对附件上传要求关闭 XSRF 校验
                .header("X-Atlassian-Token", "no-check")
                .multipart(form)
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        Ok(created.into_iter().map(Attachment::from_raw).collect())
    }

    // ---------- 编辑与创建 ----------

    /// 编辑界面上的字段（按界面顺序），附带各字段的当前值。
    pub async fn edit_fields(&self, key: &str) -> Result<Vec<FieldMeta>> {
        let raw = self
            .get_json(self.get(&format!("/rest/api/2/issue/{key}")).query(&[("expand", "editmeta")]))
            .await?;
        let mut fields = meta::parse_fields(&raw["editmeta"]["fields"]);
        for field in &mut fields {
            field.value = meta::form_value(&field.kind, &raw["fields"][field.key.as_str()]);
        }
        Ok(fields)
    }

    /// 修改问题字段。`fields` 只需包含有变化的字段，取值已按 Jira 要求的格式构造。
    pub async fn update_issue(&self, key: &str, fields: Value) -> Result<()> {
        check(
            self.put(&format!("/rest/api/2/issue/{key}"))
                .json(&json!({ "fields": fields }))
                .send()
                .await?,
        )
        .await?;
        Ok(())
    }

    /// 当前用户有权创建问题的项目，以及每个项目可用的问题类型。
    pub async fn create_projects(&self) -> Result<Vec<CreateProject>> {
        let raw = self.get_json(self.get("/rest/api/2/issue/createmeta")).await?;
        let projects = raw["projects"].as_array().into_iter().flatten().map(|p| CreateProject {
            id: fields::value_text(&p["id"]),
            key: fields::value_text(&p["key"]),
            name: fields::value_text(&p["name"]).trim().to_string(),
            issue_types: p["issuetypes"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|t| CreateIssueType {
                    id: fields::value_text(&t["id"]),
                    name: fields::value_text(&t["name"]),
                    icon_url: t["iconUrl"].as_str().map(str::to_string),
                    subtask: t["subtask"].as_bool().unwrap_or(false),
                })
                .collect(),
        });
        Ok(projects.collect())
    }

    /// 创建界面上的字段（按界面顺序），附带默认值。
    /// 使用带 `expand` 的 createmeta：新版分页接口返回的字段不是界面顺序。
    pub async fn create_fields(&self, project_key: &str, issue_type_id: &str) -> Result<Vec<FieldMeta>> {
        let raw = self
            .get_json(self.get("/rest/api/2/issue/createmeta").query(&[
                ("projectKeys", project_key),
                ("issuetypeIds", issue_type_id),
                ("expand", "projects.issuetypes.fields"),
            ]))
            .await?;
        let fields = &raw["projects"][0]["issuetypes"][0]["fields"];
        if !fields.is_object() {
            return Err(Error::Other("没有在该项目中创建此类问题的权限".into()));
        }
        Ok(meta::parse_fields(fields))
    }

    /// 创建问题，返回新问题的键。
    pub async fn create_issue(&self, fields: Value) -> Result<String> {
        let created = self
            .get_json(self.post("/rest/api/2/issue").json(&json!({ "fields": fields })))
            .await?;
        Ok(fields::value_text(&created["key"]))
    }

    /// 把 wiki 标记渲染为 HTML（与网页显示一致），供可视化编辑使用。
    /// 传入问题键时，`!图片名!` 会解析为该问题的附件。
    pub async fn render_wiki(&self, markup: &str, issue_key: Option<&str>) -> Result<String> {
        let mut body = json!({ "rendererType": "atlassian-wiki-renderer", "unrenderedMarkup": markup });
        if let Some(key) = issue_key {
            body["issueKey"] = json!(key);
        }
        Ok(check(self.post("/rest/api/1.0/render").json(&body).send().await?).await?.text().await?)
    }

    // ---------- 字段取值的搜索 ----------

    /// 搜索用户。经办人只能选可分配的用户，按问题（编辑时）或项目（创建时）查询。
    pub async fn find_users(
        &self,
        query: &str,
        field: &str,
        issue_key: Option<&str>,
        project_key: Option<&str>,
    ) -> Result<Vec<UserRef>> {
        let users = match (field, issue_key, project_key) {
            ("assignee", Some(scope), _) | ("assignee", None, Some(scope)) => {
                let scope_param = if issue_key.is_some() { "issueKey" } else { "project" };
                self.get_json(self.get("/rest/api/2/user/assignable/search").query(&[
                    (scope_param, scope),
                    ("username", query),
                    ("maxResults", "20"),
                ]))
                .await?
            }
            _ => {
                let raw = self
                    .get_json(
                        self.get("/rest/api/2/user/picker")
                            .query(&[("query", query), ("maxResults", "20")]),
                    )
                    .await?;
                raw["users"].clone()
            }
        };
        Ok(users
            .as_array()
            .into_iter()
            .flatten()
            .map(|u| UserRef { name: fields::value_text(&u["name"]), display_name: fields::value_text(u) })
            .collect())
    }

    pub async fn suggest_labels(&self, query: &str) -> Result<Vec<String>> {
        // 该接口默认返回 XML，需显式要求 JSON
        let raw = self
            .get_json(
                self.get("/rest/api/1.0/labels/suggest")
                    .header("Accept", "application/json")
                    .query(&[("query", query)]),
            )
            .await?;
        Ok(raw["suggestions"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|s| fields::value_text(&s["label"]))
            .collect())
    }

    /// 搜索 Epic（Jira Software 的接口），返回 Epic 的键和名称。
    pub async fn search_epics(&self, query: &str, project_key: &str) -> Result<Vec<IssueRef>> {
        let raw = self
            .get_json(self.get("/rest/greenhopper/1.0/epics").query(&[
                ("searchQuery", query),
                ("projectKey", project_key),
                ("maxResults", "20"),
            ]))
            .await?;
        let mut epics: Vec<IssueRef> = Vec::new();
        for epic in raw["epicLists"].as_array().into_iter().flatten().flat_map(|l| l["epicNames"].as_array().into_iter().flatten()) {
            let key = fields::value_text(&epic["key"]);
            if !epics.iter().any(|e| e.key == key) {
                epics.push(IssueRef { key, summary: fields::value_text(&epic["name"]), status: None, issue_type: None });
            }
        }
        Ok(epics)
    }

    /// 按问题键或概要搜索问题，用于选择父任务、添加链接。
    /// `project_key` 限定项目；`standard_only` 时排除子任务（父任务不能是子任务）。
    pub async fn pick_issues(
        &self,
        query: &str,
        project_key: Option<&str>,
        standard_only: bool,
    ) -> Result<Vec<IssueSummary>> {
        let query = query.trim();
        let mut clauses = Vec::new();
        if looks_like_key(query) {
            clauses.push(format!("key = \"{}\"", query.to_uppercase()));
        } else if !query.is_empty() {
            clauses.push(format!("summary ~ \"{}\"", jql_escape(query)));
        }
        if let Some(project) = project_key {
            clauses.push(format!("project = \"{}\"", jql_escape(project)));
        }
        if standard_only {
            clauses.push("issuetype in standardIssueTypes()".into());
        }
        let jql = format!("{} ORDER BY updated DESC", clauses.join(" AND "));
        match self.search(&jql, 0, 15).await {
            Ok(result) => Ok(result.issues),
            // 输入的问题键不存在时 Jira 返回 400
            Err(Error::Http { status: 400, .. }) => Ok(Vec::new()),
            Err(e) => Err(e),
        }
    }

    // ---------- 快捷操作 ----------

    /// 分配问题；`username` 为空时取消分配。
    pub async fn assign(&self, key: &str, username: Option<&str>) -> Result<()> {
        check(
            self.put(&format!("/rest/api/2/issue/{key}/assignee"))
                .json(&json!({ "name": username }))
                .send()
                .await?,
        )
        .await?;
        Ok(())
    }

    pub async fn watchers(&self, key: &str) -> Result<Watchers> {
        let raw = self.get_json(self.get(&format!("/rest/api/2/issue/{key}/watchers"))).await?;
        Ok(Watchers {
            watching: raw["isWatching"].as_bool().unwrap_or(false),
            count: raw["watchCount"].as_u64().unwrap_or(0) as u32,
        })
    }

    /// 关注或取消关注（当前用户）。
    pub async fn set_watching(&self, key: &str, me: &str, watching: bool) -> Result<()> {
        let path = format!("/rest/api/2/issue/{key}/watchers");
        let request = if watching {
            // 请求体是 JSON 字符串形式的用户名
            self.post(&path).json(&me)
        } else {
            self.delete(&path).query(&[("username", me)])
        };
        check(request.send().await?).await?;
        Ok(())
    }

    pub async fn priorities(&self) -> Result<Vec<Priority>> {
        let raw = self.get_json(self.get("/rest/api/2/priority")).await?;
        Ok(raw
            .as_array()
            .into_iter()
            .flatten()
            .map(|p| Priority {
                id: fields::value_text(&p["id"]),
                name: fields::value_text(&p["name"]),
                icon_url: p["iconUrl"].as_str().map(str::to_string),
            })
            .collect())
    }

    /// 当前用户在 Jira 中收藏的过滤器。
    pub async fn favourite_filters(&self) -> Result<Vec<Filter>> {
        let raw = self.get_json(self.get("/rest/api/2/filter/favourite")).await?;
        Ok(raw
            .as_array()
            .into_iter()
            .flatten()
            .map(|f| Filter { id: fields::value_text(&f["id"]), name: fields::value_text(&f["name"]), jql: fields::value_text(&f["jql"]) })
            .collect())
    }

    /// `since`（Jira 的 JQL 时间格式 `yyyy/MM/dd HH:mm`）之后与我有关的动态，新的在前。
    /// `cutoff` 为检查时间，只保留之后发生的变化（问题更新时间晚于检查时间，不代表每条评论都是新的）。
    pub async fn activity(&self, me: &str, since: &str, cutoff: chrono::DateTime<chrono::FixedOffset>) -> Result<Vec<ActivityEvent>> {
        let raw = self
            .get_json(self.get("/rest/api/2/search").query(&[
                ("jql", activity::activity_jql(me, since).as_str()),
                ("fields", "summary,issuetype,created,reporter,assignee,comment"),
                ("expand", "changelog"),
                ("maxResults", "50"),
            ]))
            .await?;
        let mut events: Vec<ActivityEvent> =
            raw["issues"].as_array().into_iter().flatten().flat_map(|issue| activity::events_from_issue(issue, me, cutoff)).collect();
        events.sort_by(|a, b| b.at.cmp(&a.at));
        Ok(events)
    }

    /// 时间段 `[from, to)`（`YYYY-MM-DD`，按 Jira 用户时区）内我在 Jira 上做的事，按时间先后排列。
    pub async fn my_actions(&self, me: &str, from: &str, to: &str, start: chrono::DateTime<chrono::FixedOffset>, end: chrono::DateTime<chrono::FixedOffset>) -> Result<Vec<MyAction>> {
        let raw = self
            .get_json(self.get("/rest/api/2/search").query(&[
                ("jql", activity::my_actions_jql(from, to).as_str()),
                ("fields", "summary,created,reporter,comment"),
                ("expand", "changelog"),
                ("maxResults", "100"),
            ]))
            .await?;
        let mut actions: Vec<MyAction> =
            raw["issues"].as_array().into_iter().flatten().flat_map(|issue| activity::my_actions_in_issue(issue, me, start, end)).collect();
        actions.sort_by_key(|a| parse_time(&a.at));
        Ok(actions)
    }

    // ---------- 链接 ----------

    pub async fn link_types(&self) -> Result<Vec<LinkType>> {
        let raw = self.get_json(self.get("/rest/api/2/issueLinkType")).await?;
        Ok(raw["issueLinkTypes"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|t| LinkType {
                id: fields::value_text(&t["id"]),
                name: fields::value_text(&t["name"]),
                inward: fields::value_text(&t["inward"]),
                outward: fields::value_text(&t["outward"]),
            })
            .collect())
    }

    /// 在 `key` 与 `other` 之间建立链接。`outward` 为 true 时关系读作
    /// “key <outward 描述> other”，否则读作“key <inward 描述> other”。
    pub async fn add_link(&self, key: &str, type_id: &str, other: &str, outward: bool) -> Result<()> {
        // Jira 的约定：inwardIssue 一方显示 outward 描述，即“inwardIssue <outward> outwardIssue”
        let (inward_issue, outward_issue) = if outward { (key, other) } else { (other, key) };
        check(
            self.post("/rest/api/2/issueLink")
                .json(&json!({
                    "type": { "id": type_id },
                    "inwardIssue": { "key": inward_issue },
                    "outwardIssue": { "key": outward_issue },
                }))
                .send()
                .await?,
        )
        .await?;
        Ok(())
    }

    pub async fn delete_link(&self, link_id: &str) -> Result<()> {
        check(self.delete(&format!("/rest/api/2/issueLink/{link_id}")).send().await?).await?;
        Ok(())
    }

    // ---------- 工作日志与历史 ----------

    pub async fn worklogs(&self, key: &str) -> Result<Vec<Worklog>> {
        let (raw, me) = tokio::join!(
            self.get_json(self.get(&format!("/rest/api/2/issue/{key}/worklog"))),
            self.my_username(),
        );
        let (raw, me) = (raw?, me?);
        Ok(raw["worklogs"].as_array().into_iter().flatten().map(|w| Worklog::from_raw(w, &me)).collect())
    }

    /// 当前用户在 `from`～`to`（`YYYY-MM-DD`，含两端）登记的工作日志，按问题分组。
    pub async fn my_worklogs(&self, me: &str, from: &str, to: &str) -> Result<Vec<(IssueSummary, Vec<Worklog>)>> {
        let jql = format!(
            "worklogAuthor = currentUser() AND worklogDate >= \"{from}\" AND worklogDate <= \"{to}\" ORDER BY project, updated DESC"
        );
        let issues = self.search(&jql, 0, 50).await?.issues;
        let mut result = Vec::new();
        for issue in issues {
            let raw = self.get_json(self.get(&format!("/rest/api/2/issue/{}/worklog", issue.key))).await?;
            let logs: Vec<Worklog> = raw["worklogs"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|w| Worklog::from_raw(w, me))
                .filter(|w| w.mine && w.started.get(..10).is_some_and(|day| day >= from && day <= to))
                .collect();
            if !logs.is_empty() {
                result.push((issue, logs));
            }
        }
        Ok(result)
    }

    /// 记录工作日志；剩余估算由 Jira 自动扣减。
    pub async fn add_worklog(&self, key: &str, input: &WorklogInput) -> Result<()> {
        check(
            self.post(&format!("/rest/api/2/issue/{key}/worklog"))
                .json(&worklog_body(input))
                .send()
                .await?,
        )
        .await?;
        Ok(())
    }

    pub async fn update_worklog(&self, key: &str, id: &str, input: &WorklogInput) -> Result<()> {
        check(
            self.put(&format!("/rest/api/2/issue/{key}/worklog/{id}"))
                .json(&worklog_body(input))
                .send()
                .await?,
        )
        .await?;
        Ok(())
    }

    pub async fn delete_worklog(&self, key: &str, id: &str) -> Result<()> {
        check(self.delete(&format!("/rest/api/2/issue/{key}/worklog/{id}")).send().await?).await?;
        Ok(())
    }

    /// 变更历史，按时间先后排列。
    pub async fn history(&self, key: &str) -> Result<Vec<HistoryEntry>> {
        // names 提供字段 id 到显示名称的映射，系统字段在变更记录中只有 id（如 assignee）
        let raw = self
            .get_json(
                self.get(&format!("/rest/api/2/issue/{key}"))
                    .query(&[("fields", "*all"), ("expand", "changelog,names")]),
            )
            .await?;
        Ok(raw["changelog"]["histories"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|h| HistoryEntry::from_raw(h, &raw["names"]))
            .collect())
    }
}

fn comment_body(body: &str, visibility: Option<&CommentVisibility>) -> Value {
    match visibility {
        Some(v) => json!({ "body": body, "visibility": v }),
        None => json!({ "body": body }),
    }
}

/// 从网页“添加评论”表单中解析可选的评论可见范围（项目角色、用户组）。
/// REST 接口只对项目管理员开放角色列表，网页表单列出的正是当前用户可选的范围。
pub fn parse_comment_levels(html: &str) -> Vec<CommentLevel> {
    static SELECT: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r#"(?s)<select[^>]*name="commentLevel"[^>]*>(.*?)</select>"#).unwrap());
    static OPTION: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r#"<option[^>]*value="(role|group):[^"]*"[^>]*>([^<]+)</option>"#).unwrap());
    let Some(select) = SELECT.captures(html) else { return Vec::new() };
    OPTION
        .captures_iter(&select[1])
        .map(|c| {
            let name = html_unescape(c[2].trim());
            CommentLevel { visibility: CommentVisibility { kind: c[1].to_string(), value: name.clone() }, label: name }
        })
        .collect()
}

/// 从网页“分配”表单中解析经办人的“建议”列表（最近分配过的人、报告人、当前用户等，与网页下拉框一致）。
/// 不含“未分配”“自动”这两个特殊选项。
pub fn parse_suggested_assignees(html: &str) -> Vec<UserRef> {
    static GROUP: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r#"(?s)<optgroup[^>]*id="assignee-group-suggested"[^>]*>(.*?)</optgroup>"#).unwrap());
    static OPTION: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r#"(?s)<option[^>]*?\svalue="([^"]*)"[^>]*>(.*?)</option>"#).unwrap());
    let Some(group) = GROUP.captures(html) else { return Vec::new() };
    OPTION
        .captures_iter(&group[1])
        .filter(|c| !c[1].is_empty() && &c[1] != "-1")
        .map(|c| UserRef { name: html_unescape(&c[1]), display_name: html_unescape(c[2].trim()) })
        .collect()
}

fn html_unescape(text: &str) -> String {
    text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&amp;", "&")
}

fn worklog_body(input: &WorklogInput) -> Value {
    json!({ "started": input.started, "timeSpent": input.time_spent, "comment": input.comment })
}

/// 相似问题的查询：把概要拆成关键词，任一关键词匹配即可，不指定排序时 Jira 按相关度排序。
/// Jira 按单字索引中文，一个多字的词会被当作“这些字都出现”，所以中文按相邻两字拆分，
/// 英文、数字按整词。
pub fn similar_jql(key: &str, summary: &str, resolved_only: bool) -> Option<String> {
    let terms = summary_terms(summary);
    if terms.is_empty() {
        return None;
    }
    let mut jql = format!("summary ~ \"{}\" AND key != \"{}\"", jql_escape(&terms.join(" OR ")), jql_escape(key));
    if resolved_only {
        jql.push_str(" AND resolution is not EMPTY");
    }
    Some(jql)
}

/// 最多取的关键词数，避免查询过长。
const MAX_TERMS: usize = 30;

/// 问题概要里很常见、对区分问题没有帮助的词。
const STOP_WORDS: &[&str] = &[
    "需要", "调整", "增加", "新增", "修改", "优化", "处理", "问题", "功能", "字段", "显示", "对应", "相关", "时候",
    "需求", "支持", "实现", "进行", "导致", "无法", "不能", "错误", "报错", "异常", "没有", "一个", "应该", "目前",
    "现在", "可以", "以及", "或者", "如果", "这个", "那个", "其中", "要求", "情况", "是否",
];

/// 虚词：含有这些字的两字组合多半跨了词的边界（例如“表中”“的字”）。
const PARTICLES: &str = "的了与及和时需将在为是把被从等或并中对后前里上下";

fn summary_terms(summary: &str) -> Vec<String> {
    let is_cjk = |c: char| ('\u{4e00}'..='\u{9fff}').contains(&c);
    let mut terms: Vec<String> = Vec::new();
    let mut push = |t: String| {
        if !terms.contains(&t) && terms.len() < MAX_TERMS {
            terms.push(t);
        }
    };
    let useful = |t: &str| !STOP_WORDS.contains(&t) && !t.chars().any(|c| PARTICLES.contains(c));
    let chars: Vec<char> = summary.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if is_cjk(c) {
            let start = i;
            while i < chars.len() && is_cjk(chars[i]) {
                i += 1;
            }
            let run = &chars[start..i];
            let candidates: Vec<String> = if run.len() <= 2 { vec![run.iter().collect()] } else { run.windows(2).map(|p| p.iter().collect()).collect() };
            for term in candidates.into_iter().filter(|t| useful(t)) {
                push(term);
            }
        } else if c.is_ascii_alphanumeric() {
            let start = i;
            while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            // 单个字母、纯数字太宽泛
            if word.len() > 1 && !word.chars().all(|c| c.is_ascii_digit()) {
                push(word);
            }
        } else {
            i += 1;
        }
    }
    terms
}

fn looks_like_key(s: &str) -> bool {
    let Some((project, number)) = s.rsplit_once('-') else { return false };
    !project.is_empty()
        && project.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && project.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !number.is_empty()
        && number.chars().all(|c| c.is_ascii_digit())
}

fn jql_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_issue_keys() {
        assert!(looks_like_key("ABC-123"));
        assert!(looks_like_key("proj-21067"));
        assert!(!looks_like_key("清理-1"));
        assert!(!looks_like_key("ABC-"));
        assert!(!looks_like_key("批量清理"));
    }

    #[test]
    fn splits_summary_into_terms() {
        assert_eq!(summary_terms("导入期货txt文件"), vec!["导入", "入期", "期货", "txt", "文件"]);
        // 常用词、跨词边界的组合被去掉
        assert_eq!(summary_terms("报表中债券的字段需调整"), vec!["报表", "债券"]);
        assert_eq!(summary_terms("【WEB】费用 v2 1234"), vec!["WEB", "费用", "v2"]);
        assert!(summary_terms("！？…").is_empty());
        let jql = similar_jql("A-1", "债转股", true).unwrap();
        assert_eq!(jql, r#"summary ~ "债转 OR 转股" AND key != "A-1" AND resolution is not EMPTY"#);
    }

    #[test]
    fn parses_comment_levels_from_form() {
        let html = r#"<select name="commentLevel" id="commentLevel" data-enable-default="true">
            <option value="">所有用户</option>
            <optgroup label="项目角色">
                <option value="role:10504" >Developers</option>
                <option value="role:10100" >开发</option>
            </optgroup>
            <optgroup label="组"><option value="group:jira-users">jira-users</option></optgroup>
        </select><select name="other"><option value="role:1">x</option></select>"#;
        let levels = parse_comment_levels(html);
        let got: Vec<(&str, &str)> = levels.iter().map(|l| (l.visibility.kind.as_str(), l.visibility.value.as_str())).collect();
        assert_eq!(got, vec![("role", "Developers"), ("role", "开发"), ("group", "jira-users")]);
        assert!(parse_comment_levels("<html>登录</html>").is_empty());
    }

    #[test]
    fn parses_suggested_assignees_from_form() {
        let html = r#"<select id="assignee" name="assignee"><optgroup id="assignee-group-suggested" label="建议" data-weight="0">
            <option class="current-user" value="alice" data-field-text="Alice" data-icon="/a?x=1&amp;y=2" >Alice</option>
            <option value="" data-field-text="未分配" >未分配</option><option value="-1" data-field-text="自动" >自动</option>
            <option value="bob.w" data-field-text="Bob &amp; Co" >Bob &amp; Co</option>
        </optgroup><optgroup id="assignee-group-all-users" label="所有用户"><option value="carol">Carol</option></optgroup></select>"#;
        let users: Vec<(String, String)> = parse_suggested_assignees(html).into_iter().map(|u| (u.name, u.display_name)).collect();
        assert_eq!(users, vec![("alice".into(), "Alice".into()), ("bob.w".into(), "Bob & Co".into())]);
        assert!(parse_suggested_assignees("<html>登录</html>").is_empty());
    }

    #[test]
    fn escapes_jql_strings() {
        assert_eq!(jql_escape(r#"a"b\c"#), r#"a\"b\\c"#);
    }
}
