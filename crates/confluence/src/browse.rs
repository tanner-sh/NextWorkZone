//! 在应用内浏览 Wiki：空间、页面树、页面内容、附件、历史版本、评论、模板、通知，以及页面地址的解析。

use base64::Engine;
use nextworkzone_core::http::check;
use nextworkzone_core::{Error, Result};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::storage::{collapse_whitespace, decode_entities};
use crate::{Ancestor, ConfluenceClient, ancestors};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Space {
    pub key: String,
    pub name: String,
    /// `global` / `personal`
    pub kind: String,
    pub homepage_id: Option<String>,
    pub description: String,
}

/// 页面树中的一个节点。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageNode {
    pub id: String,
    pub title: String,
    pub has_children: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageDetail {
    pub id: String,
    /// `page` / `blogpost`
    pub kind: String,
    pub title: String,
    pub space_key: String,
    pub space_name: String,
    pub version: u64,
    pub modified_by: String,
    pub modified: String,
    pub version_message: String,
    pub created_by: String,
    pub created: String,
    pub ancestors: Vec<Ancestor>,
    pub labels: Vec<String>,
    /// 渲染后的 HTML。
    pub html: String,
    pub url: String,
    pub can_edit: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiAttachment {
    pub id: String,
    pub filename: String,
    pub size: u64,
    pub mime_type: String,
    /// 下载地址（站内路径）。
    pub content_url: String,
    pub thumbnail_url: Option<String>,
    pub author: String,
    pub created: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionInfo {
    pub number: u64,
    pub by: String,
    pub when: String,
    pub message: String,
    pub minor_edit: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiComment {
    pub id: String,
    pub author: String,
    pub created: String,
    pub html: String,
    /// 回复的评论 id。
    pub parent_id: Option<String>,
    /// 行内评论选中的原文；页面底部的评论为空。
    pub inline_text: Option<String>,
    pub version: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiTemplate {
    pub id: String,
    pub name: String,
    pub description: String,
    /// 所属空间；全局模板为空。
    pub space_key: Option<String>,
}

/// CQL 搜索结果（服务器端搜索）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CqlHit {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub space_key: String,
    pub space_name: String,
    pub ancestors: Vec<Ancestor>,
    pub author_name: String,
    pub modified: String,
    pub snippet: String,
}

/// Confluence 自带的通知（评论、提到、分享、任务等），来自“工作箱”。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiNotification {
    pub id: String,
    /// `comment` / `mention` / `share` / `task` / `like` / 其他动作原样
    pub action: String,
    pub title: String,
    pub text: String,
    pub actor: String,
    pub page_id: Option<String>,
    pub page_title: String,
    pub url: String,
    /// 毫秒
    pub updated: i64,
}

/// 最近修改过的页面（关注或自己创建的页面上，他人的修改）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageChange {
    pub id: String,
    pub title: String,
    pub version: u64,
    pub by: String,
    pub by_key: String,
    pub when: String,
    pub message: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CqlQuery {
    pub text: String,
    pub space: String,
    pub mine: bool,
    pub days: u32,
    pub kind: String,
    pub label: String,
    pub start: u32,
    pub limit: u32,
}

fn text(v: &Value) -> String {
    v.as_str().unwrap_or_default().to_string()
}

fn cql_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// HTML 去掉标签后的文字。
fn strip_html(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    collapse_whitespace(&decode_entities(&out))
}

/// 短链接 `/x/<代码>` 中的页面 id：代码是页面 id（小端字节、去掉末尾的 0）的 base64。
pub fn decode_tiny(code: &str) -> Option<String> {
    let mut s: String = code
        .trim_end_matches('=')
        .chars()
        .map(|c| match c {
            '-' => '/',
            '_' => '+',
            c => c,
        })
        .collect();
    while !s.len().is_multiple_of(4) {
        s.push('=');
    }
    let bytes = base64::engine::general_purpose::STANDARD.decode(s).ok()?;
    if bytes.is_empty() || bytes.len() > 8 {
        return None;
    }
    let mut buf = [0u8; 8];
    buf[..bytes.len()].copy_from_slice(&bytes);
    Some(u64::from_le_bytes(buf).to_string())
}

impl ConfluenceClient {
    /// 全部可见的全局空间。
    pub async fn spaces(&self) -> Result<Vec<Space>> {
        let mut out = Vec::new();
        let mut start = 0;
        loop {
            let raw = self
                .get_json(self.get("/rest/api/space").query(&[
                    ("type", "global"),
                    ("start", &start.to_string()),
                    ("limit", "200"),
                    ("expand", "homepage,description.plain"),
                ]))
                .await?;
            let results = raw["results"].as_array().cloned().unwrap_or_default();
            for s in &results {
                out.push(Space {
                    key: text(&s["key"]),
                    name: text(&s["name"]),
                    kind: text(&s["type"]),
                    homepage_id: s["homepage"]["id"].as_str().map(str::to_string),
                    description: text(&s["description"]["plain"]["value"]),
                });
            }
            start += results.len();
            if results.is_empty() || raw["_links"]["next"].is_null() {
                break;
            }
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }

    /// 空间的顶层页面。
    pub async fn space_roots(&self, space_key: &str) -> Result<Vec<PageNode>> {
        let path = format!("/rest/api/space/{space_key}/content/page");
        self.page_nodes(self.get(&path).query(&[("depth", "root")])).await
    }

    /// 子页面（按页面树中的顺序）。
    pub async fn children(&self, page_id: &str) -> Result<Vec<PageNode>> {
        let path = format!("/rest/api/content/{page_id}/child/page");
        self.page_nodes(self.get(&path)).await
    }

    async fn page_nodes(&self, request: reqwest::RequestBuilder) -> Result<Vec<PageNode>> {
        let mut out = Vec::new();
        let mut start = 0;
        loop {
            let raw = self
                .get_json(request.try_clone().expect("GET 请求可以复制").query(&[
                    ("start", start.to_string().as_str()),
                    ("limit", "200"),
                    ("expand", "children.page"),
                ]))
                .await?;
            let results = raw["results"].as_array().cloned().unwrap_or_default();
            for p in &results {
                out.push(PageNode {
                    id: text(&p["id"]),
                    title: text(&p["title"]),
                    has_children: p["children"]["page"]["size"].as_u64().unwrap_or(0) > 0,
                });
            }
            start += results.len();
            if results.is_empty() || raw["_links"]["next"].is_null() {
                break;
            }
        }
        Ok(out)
    }

    pub async fn page_detail(&self, id: &str) -> Result<PageDetail> {
        let raw = self
            .get_json(self.get(&format!("/rest/api/content/{id}")).query(&[(
                "expand",
                "body.view,version,space,ancestors,history,metadata.labels,operations",
            )]))
            .await?;
        let can_edit = raw["operations"].as_array().into_iter().flatten().any(|o| o["operation"] == "update");
        Ok(PageDetail {
            id: text(&raw["id"]),
            kind: text(&raw["type"]),
            title: text(&raw["title"]),
            space_key: text(&raw["space"]["key"]),
            space_name: text(&raw["space"]["name"]),
            version: raw["version"]["number"].as_u64().unwrap_or(0),
            modified_by: text(&raw["version"]["by"]["displayName"]),
            modified: text(&raw["version"]["when"]),
            version_message: text(&raw["version"]["message"]),
            created_by: text(&raw["history"]["createdBy"]["displayName"]),
            created: text(&raw["history"]["createdDate"]),
            ancestors: ancestors(&raw["ancestors"]),
            labels: raw["metadata"]["labels"]["results"].as_array().into_iter().flatten().map(|l| text(&l["name"])).collect(),
            html: text(&raw["body"]["view"]["value"]),
            url: self.page_url(id),
            can_edit,
        })
    }

    /// 页面当前的版本号（用于判断剪藏、发布的页面是否有更新）。
    pub async fn page_version(&self, id: &str) -> Result<(String, u64, String, String)> {
        let raw = self.get_json(self.get(&format!("/rest/api/content/{id}")).query(&[("expand", "version")])).await?;
        Ok((
            text(&raw["title"]),
            raw["version"]["number"].as_u64().unwrap_or(0),
            text(&raw["version"]["by"]["displayName"]),
            text(&raw["version"]["when"]),
        ))
    }

    pub async fn attachments(&self, page_id: &str) -> Result<Vec<WikiAttachment>> {
        let mut out = Vec::new();
        let mut start = 0;
        loop {
            let raw = self
                .get_json(self.get(&format!("/rest/api/content/{page_id}/child/attachment")).query(&[
                    ("start", start.to_string().as_str()),
                    ("limit", "200"),
                    ("expand", "version"),
                ]))
                .await?;
            let results = raw["results"].as_array().cloned().unwrap_or_default();
            for a in &results {
                let mime = text(&a["metadata"]["mediaType"]);
                let download = text(&a["_links"]["download"]);
                out.push(WikiAttachment {
                    id: text(&a["id"]),
                    filename: text(&a["title"]),
                    size: a["extensions"]["fileSize"].as_u64().unwrap_or(0),
                    thumbnail_url: mime.starts_with("image/").then(|| download.clone()),
                    mime_type: mime,
                    content_url: download,
                    author: text(&a["version"]["by"]["displayName"]),
                    created: text(&a["version"]["when"]),
                });
            }
            start += results.len();
            if results.is_empty() || raw["_links"]["next"].is_null() {
                break;
            }
        }
        Ok(out)
    }

    /// 页面的全部历史版本，最新的在前。
    pub async fn versions(&self, page_id: &str) -> Result<Vec<VersionInfo>> {
        let mut out = Vec::new();
        let mut start = 0;
        loop {
            let raw = self
                .get_json(self.get(&format!("/rest/experimental/content/{page_id}/version")).query(&[("start", start.to_string().as_str()), ("limit", "200")]))
                .await?;
            let results = raw["results"].as_array().cloned().unwrap_or_default();
            for v in &results {
                out.push(VersionInfo {
                    number: v["number"].as_u64().unwrap_or(0),
                    by: text(&v["by"]["displayName"]),
                    when: text(&v["when"]),
                    message: text(&v["message"]),
                    minor_edit: v["minorEdit"].as_bool().unwrap_or(false),
                });
            }
            start += results.len();
            if results.is_empty() || raw["_links"]["next"].is_null() {
                break;
            }
        }
        out.sort_by(|a, b| b.number.cmp(&a.number));
        Ok(out)
    }

    /// 某个版本的 storage 内容。
    pub async fn version_storage(&self, page_id: &str, version: u64) -> Result<String> {
        let raw = self
            .get_json(self.get(&format!("/rest/api/content/{page_id}")).query(&[
                ("status", "historical"),
                ("version", version.to_string().as_str()),
                ("expand", "body.storage"),
            ]))
            .await?;
        Ok(text(&raw["body"]["storage"]["value"]))
    }

    /// 某个版本渲染后的 HTML。
    pub async fn version_html(&self, page_id: &str, version: u64) -> Result<String> {
        let raw = self
            .get_json(self.get(&format!("/rest/api/content/{page_id}")).query(&[
                ("status", "historical"),
                ("version", version.to_string().as_str()),
                ("expand", "body.view"),
            ]))
            .await?;
        Ok(text(&raw["body"]["view"]["value"]))
    }

    pub async fn comments(&self, page_id: &str) -> Result<Vec<WikiComment>> {
        let mut out = Vec::new();
        let mut start = 0;
        loop {
            let raw = self
                .get_json(self.get(&format!("/rest/api/content/{page_id}/child/comment")).query(&[
                    ("start", start.to_string().as_str()),
                    ("limit", "100"),
                    ("depth", "all"),
                    ("expand", "body.view,version,history,ancestors,extensions.inlineProperties"),
                ]))
                .await?;
            let results = raw["results"].as_array().cloned().unwrap_or_default();
            for c in &results {
                let inline = c["extensions"]["location"] == "inline";
                out.push(WikiComment {
                    id: text(&c["id"]),
                    author: text(&c["history"]["createdBy"]["displayName"]),
                    created: text(&c["history"]["createdDate"]),
                    html: text(&c["body"]["view"]["value"]),
                    parent_id: c["ancestors"].as_array().and_then(|a| a.last()).map(|a| text(&a["id"])),
                    inline_text: inline
                        .then(|| text(&c["extensions"]["inlineProperties"]["originalSelection"]))
                        .filter(|t| !t.is_empty()),
                    version: c["version"]["number"].as_u64().unwrap_or(1),
                });
            }
            start += results.len();
            if results.is_empty() || raw["_links"]["next"].is_null() {
                break;
            }
        }
        out.sort_by(|a, b| a.created.cmp(&b.created));
        Ok(out)
    }

    /// 发表评论；`parent_id` 不为空时是回复。
    pub async fn add_comment(&self, page_id: &str, parent_id: Option<&str>, storage: &str) -> Result<String> {
        let mut body = json!({
            "type": "comment",
            "container": { "id": page_id, "type": "page" },
            "body": { "storage": { "value": storage, "representation": "storage" } },
        });
        if let Some(parent) = parent_id {
            body["ancestors"] = json!([{ "id": parent }]);
        }
        let created: Value = check(self.http.post(format!("{}/rest/api/content", self.base_url)).bearer_auth(&self.token).json(&body).send().await?)
            .await?
            .json()
            .await?;
        created["id"].as_str().map(str::to_string).ok_or_else(|| Error::Other("发表评论失败：响应中没有评论 id".into()))
    }

    /// 保存页面的新内容。`base_version` 是开始编辑时的版本：页面在此之后被别人改过时返回 [`Error::Conflict`]，不覆盖。
    pub async fn save_page(&self, id: &str, title: &str, storage: &str, base_version: u64, minor_edit: bool, message: &str) -> Result<u64> {
        let current = self.page(id).await?;
        if current.version != base_version {
            return Err(Error::Conflict(format!(
                "页面在你编辑期间被 {} 修改过（当前为第 {} 版，你基于第 {base_version} 版编辑）",
                current.modified_by, current.version
            )));
        }
        let version = base_version + 1;
        let body = json!({
            "id": id,
            "type": "page",
            "title": title,
            "space": { "key": current.space_key },
            "version": { "number": version, "minorEdit": minor_edit, "message": message },
            "body": { "storage": { "value": storage, "representation": "storage" } },
        });
        let response = self.http.put(format!("{}/rest/api/content/{id}", self.base_url)).bearer_auth(&self.token).json(&body).send().await?;
        if response.status() == StatusCode::CONFLICT {
            return Err(Error::Conflict("页面刚刚被他人更新，请刷新后重新编辑".into()));
        }
        check(response).await?;
        Ok(version)
    }

    /// 页面的附件文件名（发布时跳过已存在的图片）。
    pub async fn attachment_names(&self, page_id: &str) -> Result<Vec<String>> {
        Ok(self.attachments(page_id).await?.into_iter().map(|a| a.filename).collect())
    }

    /// 勾选或取消页面中的任务。
    pub async fn set_task_status(&self, page_id: &str, task_id: &str, done: bool) -> Result<()> {
        let body = json!({ "status": if done { "CHECKED" } else { "UNCHECKED" }, "trigger": "VIEW_PAGE" });
        check(
            self.http
                .post(format!("{}/rest/inlinetasks/1/task/{page_id}/{task_id}/", self.base_url))
                .bearer_auth(&self.token)
                .header("X-Atlassian-Token", "no-check")
                .json(&body)
                .send()
                .await?,
        )
        .await?;
        Ok(())
    }

    /// 页面模板：全局模板，以及 `space_key` 空间的模板。
    pub async fn templates(&self, space_key: Option<&str>) -> Result<Vec<WikiTemplate>> {
        let mut out = Vec::new();
        let mut scopes: Vec<Option<&str>> = vec![None];
        if let Some(space) = space_key {
            scopes.push(Some(space));
        }
        for space in scopes {
            let mut request = self.get("/rest/experimental/template/page").query(&[("limit", "200")]);
            if let Some(space) = space {
                request = request.query(&[("spaceKey", space)]);
            }
            let Ok(raw) = self.get_json(request).await else { continue };
            for t in raw["results"].as_array().into_iter().flatten() {
                out.push(WikiTemplate {
                    id: text(&t["templateId"]),
                    name: text(&t["name"]),
                    description: text(&t["description"]),
                    space_key: t["space"]["key"].as_str().map(str::to_string).or(space.map(str::to_string)),
                });
            }
        }
        Ok(out)
    }

    pub async fn template_storage(&self, id: &str) -> Result<String> {
        let raw = self.get_json(self.get(&format!("/rest/experimental/template/{id}")).query(&[("expand", "body.storage")])).await?;
        Ok(text(&raw["body"]["storage"]["value"]))
    }

    /// 在空间顶层或 `parent_id` 下新建页面，返回页面 id。
    pub async fn create_in(&self, space_key: &str, parent_id: Option<&str>, title: &str, storage: &str) -> Result<String> {
        let mut body = json!({
            "type": "page",
            "title": title,
            "space": { "key": space_key },
            "body": { "storage": { "value": storage, "representation": "storage" } },
        });
        if let Some(parent) = parent_id {
            body["ancestors"] = json!([{ "id": parent }]);
        }
        let created: Value = check(self.http.post(format!("{}/rest/api/content", self.base_url)).bearer_auth(&self.token).json(&body).send().await?)
            .await?
            .json()
            .await?;
        created["id"].as_str().map(str::to_string).ok_or_else(|| Error::Other("创建页面失败：响应中没有页面 id".into()))
    }

    /// 服务器端 CQL 搜索：（总数，结果）。
    pub async fn cql_search(&self, q: &CqlQuery, me: &str) -> Result<(u32, Vec<CqlHit>)> {
        let mut parts = vec![if q.kind.is_empty() { "type in (page, blogpost)".to_string() } else { format!("type = {}", cql_escape(&q.kind)) }];
        if !q.text.trim().is_empty() {
            parts.push(format!("siteSearch ~ \"{}\"", cql_escape(q.text.trim())));
        }
        if !q.space.is_empty() {
            parts.push(format!("space = \"{}\"", cql_escape(&q.space)));
        }
        if q.mine && !me.is_empty() {
            parts.push(format!("contributor = \"{}\"", cql_escape(me)));
        }
        if q.days > 0 {
            parts.push(format!("lastmodified >= now(\"-{}d\")", q.days));
        }
        if !q.label.is_empty() {
            parts.push(format!("label = \"{}\"", cql_escape(&q.label)));
        }
        let mut cql = parts.join(" AND ");
        if q.text.trim().is_empty() {
            cql.push_str(" ORDER BY lastmodified DESC");
        }
        let limit = if q.limit == 0 { 50 } else { q.limit.min(100) };
        let raw = self
            .get_json(self.get("/rest/api/search").query(&[
                ("cql", cql.as_str()),
                ("start", q.start.to_string().as_str()),
                ("limit", limit.to_string().as_str()),
                ("expand", "content.space,content.version,content.ancestors"),
            ]))
            .await?;
        let total = raw["totalSize"].as_u64().unwrap_or(0) as u32;
        let hits = raw["results"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|r| {
                let c = &r["content"];
                Some(CqlHit {
                    id: c["id"].as_str()?.to_string(),
                    kind: text(&c["type"]),
                    title: text(&c["title"]),
                    space_key: text(&c["space"]["key"]),
                    space_name: text(&c["space"]["name"]),
                    ancestors: ancestors(&c["ancestors"]),
                    author_name: text(&c["version"]["by"]["displayName"]),
                    modified: text(&c["version"]["when"]),
                    snippet: crate::strip_highlight(r["excerpt"].as_str().unwrap_or_default()),
                })
            })
            .collect();
        Ok((total, hits))
    }

    /// 当前用户的 userkey 与用户名。
    pub async fn me(&self) -> Result<(String, String)> {
        let raw = self.get_json(self.get("/rest/api/user/current")).await?;
        Ok((text(&raw["userKey"]), text(&raw["username"])))
    }

    /// 用户的显示名（按 userkey 查询）；查不到的跳过。
    pub async fn user_names(&self, keys: &[String]) -> Result<Vec<(String, String)>> {
        let mut out = Vec::new();
        for key in keys.iter().take(50) {
            if let Ok(raw) = self.get_json(self.get("/rest/api/user").query(&[("key", key.as_str())])).await {
                out.push((key.clone(), text(&raw["displayName"])));
            }
        }
        Ok(out)
    }

    /// 在网页上最近查看的页面（Confluence 的“最近查看”）。接口不存在时返回空。
    pub async fn recently_viewed(&self, limit: u32) -> Result<Vec<(String, String, String, i64)>> {
        let response = self.get("/rest/recentlyviewed/1.0/recent").query(&[("limit", limit.to_string())]).send().await?;
        if !response.status().is_success() {
            return Ok(Vec::new());
        }
        let raw: Value = response.json().await.unwrap_or(Value::Null);
        Ok(raw
            .as_array()
            .into_iter()
            .flatten()
            .filter(|r| r["type"] == "page" || r["type"] == "blogpost")
            .filter_map(|r| {
                Some((r["id"].as_u64().map(|n| n.to_string()).or_else(|| r["id"].as_str().map(str::to_string))?, text(&r["title"]), text(&r["space"]), r["lastSeen"].as_i64().unwrap_or(0)))
            })
            .collect())
    }

    /// Confluence 工作箱中的通知（评论、提到、分享、任务等）。接口不存在时返回空。
    pub async fn notifications(&self) -> Result<Vec<WikiNotification>> {
        let response = self.get("/rest/mywork/latest/notification/nested").query(&[("limit", "100")]).send().await?;
        if !response.status().is_success() {
            return Ok(Vec::new());
        }
        let raw: Value = response.json().await.unwrap_or(Value::Null);
        let mut out = Vec::new();
        for group in raw.as_array().into_iter().flatten() {
            let item = &group["item"];
            // 应用链接授权之类的系统提示不是动态
            if item["entity"] == "authentication" || item["application"] == "com.atlassian.mywork.host.provider" {
                continue;
            }
            for n in group["notifications"].as_array().into_iter().flatten() {
                let url = text(&n["url"]).if_empty(text(&item["url"]));
                let action = text(&n["action"]).if_empty(text(&item["action"]));
                let meta = &n["metadata"];
                let actor = [&meta["user"], &meta["userDisplayName"], &meta["username"], &meta["fullName"]]
                    .into_iter()
                    .find_map(|v| v.as_str().filter(|s| !s.is_empty()))
                    .unwrap_or_default()
                    .to_string();
                out.push(WikiNotification {
                    id: n["id"].as_i64().map(|i| i.to_string()).unwrap_or_else(|| text(&n["globalId"])),
                    action: normalize_action(&action, &text(&n["title"])),
                    title: strip_html(&text(&n["title"])),
                    text: strip_html(&text(&n["description"])).chars().take(200).collect(),
                    actor,
                    page_id: nextworkzone_core::config::parse_page_id(&format!("{}{}", self.base_url, url))
                        .or_else(|| meta["pageId"].as_str().map(str::to_string))
                        .or_else(|| meta["contentId"].as_i64().map(|i| i.to_string())),
                    page_title: strip_html(&text(&item["title"])),
                    url: if url.starts_with('/') { format!("{}{url}", self.base_url) } else { url },
                    updated: n["updated"].as_i64().or_else(|| n["created"].as_i64()).unwrap_or(0),
                });
            }
        }
        Ok(out)
    }

    /// `since` 之后修改过的、我关注或创建的页面。
    pub async fn watched_changes(&self, minutes: i64) -> Result<Vec<PageChange>> {
        let cql = format!(
            "type in (page, blogpost) AND (watcher = currentUser() OR creator = currentUser()) AND lastmodified >= now(\"-{minutes}m\") ORDER BY lastmodified DESC"
        );
        let raw = self
            .get_json(self.get("/rest/api/content/search").query(&[("cql", cql.as_str()), ("limit", "50"), ("expand", "version")]))
            .await?;
        Ok(raw["results"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|r| PageChange {
                id: text(&r["id"]),
                title: text(&r["title"]),
                version: r["version"]["number"].as_u64().unwrap_or(0),
                by: text(&r["version"]["by"]["displayName"]),
                by_key: text(&r["version"]["by"]["userKey"]),
                when: text(&r["version"]["when"]),
                message: text(&r["version"]["message"]),
            })
            .collect())
    }

    /// 把各种形式的页面地址解析为页面 id：`pageId=`、`/pages/<id>/`、短链接 `/x/<代码>`、
    /// `/display/<空间>/<标题>`、`/display/<空间>`（空间首页）以及 `viewpage.action?spaceKey=&title=`。
    pub async fn resolve_page(&self, input: &str) -> Result<Option<String>> {
        let input = input.trim();
        if let Some(id) = nextworkzone_core::config::parse_page_id(input) {
            return Ok(Some(id));
        }
        let Ok(url) = url::Url::parse(input) else { return Ok(None) };
        let base_path = url::Url::parse(&self.base_url).map(|b| b.path().trim_end_matches('/').to_string()).unwrap_or_default();
        let path = url.path().strip_prefix(&base_path).unwrap_or(url.path()).to_string();
        let segments: Vec<String> = path
            .split('/')
            .filter(|s| !s.is_empty())
            .map(percent_decode)
            .collect();
        let query = |name: &str| url.query_pairs().find(|(k, _)| k == name).map(|(_, v)| v.into_owned());
        match segments.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
            ["x", code, ..] => Ok(decode_tiny(code)),
            ["display", space] => self.space_home(space).await,
            ["display", space, title, ..] if !space.starts_with('~') || !title.is_empty() => {
                self.find_by_title(space, &title.replace('+', " ")).await
            }
            ["pages", "viewpage.action"] | ["pages", "editpage.action"] => match (query("spaceKey"), query("title")) {
                (Some(space), Some(title)) => self.find_by_title(&space, &title).await,
                _ => Ok(None),
            },
            ["spaces", "viewspace.action"] => match query("key") {
                Some(space) => self.space_home(&space).await,
                None => Ok(None),
            },
            _ => Ok(None),
        }
    }

    async fn space_home(&self, space: &str) -> Result<Option<String>> {
        let raw = self.get_json(self.get(&format!("/rest/api/space/{space}")).query(&[("expand", "homepage")])).await?;
        Ok(raw["homepage"]["id"].as_str().map(str::to_string))
    }

    async fn find_by_title(&self, space: &str, title: &str) -> Result<Option<String>> {
        let raw = self.get_json(self.get("/rest/api/content").query(&[("spaceKey", space), ("title", title), ("type", "page")])).await?;
        let found = raw["results"].as_array().and_then(|r| r.first()).and_then(|p| p["id"].as_str()).map(str::to_string);
        if found.is_some() {
            return Ok(found);
        }
        let raw = self.get_json(self.get("/rest/api/content").query(&[("spaceKey", space), ("title", title), ("type", "blogpost")])).await?;
        Ok(raw["results"].as_array().and_then(|r| r.first()).and_then(|p| p["id"].as_str()).map(str::to_string))
    }
}

trait IfEmpty {
    fn if_empty(self, other: String) -> String;
}

impl IfEmpty for String {
    fn if_empty(self, other: String) -> String {
        if self.is_empty() { other } else { self }
    }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = bytes.get(i + 1..i + 3).and_then(|h| std::str::from_utf8(h).ok()).and_then(|h| u8::from_str_radix(h, 16).ok());
        match (bytes[i], hex) {
            (b'%', Some(b)) => {
                out.push(b);
                i += 3;
            }
            (b, _) => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 工作箱中的动作名称统一为几类。
fn normalize_action(action: &str, title: &str) -> String {
    let a = action.to_ascii_lowercase();
    let t = title.to_lowercase();
    if a.contains("mention") || t.contains("提到") || t.contains("mentioned") {
        "mention".into()
    } else if a.contains("comment") || t.contains("评论") || t.contains("comment") {
        "comment".into()
    } else if a.contains("share") || t.contains("分享") || t.contains("shared") {
        "share".into()
    } else if a.contains("task") || t.contains("任务") {
        "task".into()
    } else if a.contains("like") || t.contains("赞") {
        "like".into()
    } else if a.is_empty() {
        "other".into()
    } else {
        a
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiny_links() {
        assert_eq!(decode_tiny("sVi5Dg").as_deref(), Some("247027889"));
        assert_eq!(decode_tiny("").as_deref(), None);
    }

    #[test]
    fn decodes_paths() {
        assert_eq!(percent_decode("%E5%91%A8%E6%8A%A5+A"), "周报+A");
        assert_eq!(percent_decode("abc%"), "abc%");
        assert_eq!(strip_html("<p>a&nbsp;<b>b</b></p>"), "a b");
        assert_eq!(normalize_action("", "张三 评论了 页面"), "comment");
    }
}
