//! Confluence Server / Data Center 适配器（REST API v1，Bearer PAT 认证）。

pub mod browse;
pub mod diff;
pub mod edit;
pub mod index;
pub mod storage;
pub mod text;
pub mod weekly;

use chrono::NaiveDate;
use nextworkzone_core::http::check;
use nextworkzone_core::{ConnectionInfo, Error, Result, Service};
use reqwest::{Client, RequestBuilder, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::json;

use weekly::{OutlineItem, WeekEntry, WeeklyOverview};

pub struct ConfluenceClient {
    http: Client,
    base_url: String,
    token: String,
}

/// 上级页面。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ancestor {
    pub id: String,
    pub title: String,
}

pub(crate) fn ancestors(raw: &serde_json::Value) -> Vec<Ancestor> {
    raw.as_array()
        .into_iter()
        .flatten()
        .map(|a| Ancestor {
            id: a["id"].as_str().unwrap_or_default().to_string(),
            title: a["title"].as_str().unwrap_or_default().to_string(),
        })
        .collect()
}

/// 解析 Confluence 时间，例如 `2026-10-18T22:21:56.160+08:00`。
pub fn parse_time(s: &str) -> Option<chrono::DateTime<chrono::FixedOffset>> {
    chrono::DateTime::parse_from_rfc3339(s).ok()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CurrentUser {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    username: String,
    #[serde(default)]
    display_name: String,
}

/// 页面的 storage 内容与版本信息。
#[derive(Debug, Clone)]
pub struct Page {
    pub id: String,
    pub title: String,
    pub space_key: String,
    pub version: u64,
    pub storage: String,
    pub modified_by: String,
    pub modified_at: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPage {
    id: String,
    title: String,
    space: RawSpace,
    version: RawVersion,
    body: RawBody,
}

#[derive(Debug, Deserialize)]
struct RawSpace {
    key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawVersion {
    number: u64,
    #[serde(default)]
    when: String,
    by: Option<RawUser>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawUser {
    #[serde(default)]
    display_name: String,
}

#[derive(Debug, Deserialize)]
struct RawBody {
    storage: RawStorage,
}

#[derive(Debug, Deserialize)]
struct RawStorage {
    value: String,
}

/// 周报页面上与自己相关的全部信息。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WeeklyView {
    pub page_id: String,
    pub page_title: String,
    pub page_url: String,
    pub version: u64,
    pub modified_by: String,
    pub modified_at: String,
    pub person_name: String,
    #[serde(flatten)]
    pub overview: WeeklyOverview,
    pub entry: Option<WeekEntry>,
}

/// 保存结果。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveResult {
    pub changed: bool,
    pub version: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub id: String,
    pub title: String,
    pub space: String,
    pub url: String,
    pub excerpt: String,
}

/// 保存时遇到版本冲突（他人同时保存）的最大重试次数。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageView {
    pub id: String,
    pub title: String,
    pub space_key: String,
    pub url: String,
    pub html: String,
    pub version: u64,
}

const SAVE_ATTEMPTS: usize = 3;

impl ConfluenceClient {
    pub fn new(http: Client, base_url: impl Into<String>, token: impl Into<String>) -> Self {
        Self { http, base_url: base_url.into(), token: token.into() }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    fn get(&self, path: &str) -> RequestBuilder {
        self.http.get(format!("{}{}", self.base_url, path)).bearer_auth(&self.token)
    }

    async fn get_json(&self, request: RequestBuilder) -> Result<serde_json::Value> {
        Ok(check(request.send().await?).await?.json().await?)
    }

    pub async fn connection_info(&self) -> Result<ConnectionInfo> {
        let me = self.current_user().await?;
        Ok(ConnectionInfo {
            service: Service::Confluence,
            username: me.username,
            display_name: me.display_name,
            server_version: self.server_version().await,
        })
    }

    async fn current_user(&self) -> Result<CurrentUser> {
        let me: CurrentUser =
            check(self.get("/rest/api/user/current").send().await?).await?.json().await?;
        // Token 无效时 Confluence 可能不报 401，而是把请求当作匿名访问。
        if me.kind == "anonymous" {
            return Err(Error::Unauthorized { status: 401 });
        }
        Ok(me)
    }

    /// Confluence 的 REST API 不提供版本号，这里从 Application Links 的 manifest（XML）里读取。
    /// 版本号只用于展示，读取失败时不影响连接测试。
    async fn server_version(&self) -> Option<String> {
        let response = self.get("/rest/applinks/1.0/manifest").send().await.ok()?;
        let xml = check(response).await.ok()?.text().await.ok()?;
        let start = xml.find("<version>")? + "<version>".len();
        let end = start + xml[start..].find("</version>")?;
        Some(xml[start..end].to_string())
    }

    pub fn page_url(&self, id: &str) -> String {
        format!("{}/pages/viewpage.action?pageId={id}", self.base_url)
    }

    pub async fn page(&self, id: &str) -> Result<Page> {
        let raw: RawPage = check(
            self.get(&format!("/rest/api/content/{id}"))
                .query(&[("expand", "body.storage,version,space")])
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        Ok(Page {
            id: raw.id,
            title: raw.title,
            space_key: raw.space.key,
            version: raw.version.number,
            storage: raw.body.storage.value,
            modified_by: raw.version.by.map(|u| u.display_name).unwrap_or_default(),
            modified_at: raw.version.when,
        })
    }

    /// 以 `page.version + 1` 提交新内容。版本冲突时返回 [`Error::Conflict`]。
    /// 标记为小修改，不给页面关注者发送通知。
    pub async fn update_page(&self, page: &Page, storage: &str, message: &str) -> Result<u64> {
        let version = page.version + 1;
        let body = json!({
            "id": page.id,
            "type": "page",
            "title": page.title,
            "space": { "key": page.space_key },
            "version": { "number": version, "minorEdit": true, "message": message },
            "body": { "storage": { "value": storage, "representation": "storage" } },
        });
        let response = self
            .http
            .put(format!("{}/rest/api/content/{}", self.base_url, page.id))
            .bearer_auth(&self.token)
            .json(&body)
            .send()
            .await?;
        if response.status() == StatusCode::CONFLICT {
            return Err(Error::Conflict("页面已被他人更新".into()));
        }
        check(response).await?;
        Ok(version)
    }

    /// 页面渲染后的 HTML（用于剪藏到知识库）。
    pub async fn page_view(&self, id: &str) -> Result<PageView> {
        let raw: serde_json::Value = check(
            self.get(&format!("/rest/api/content/{id}"))
                .query(&[("expand", "body.view,space,version")])
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        Ok(PageView {
            id: id.to_string(),
            title: raw["title"].as_str().unwrap_or_default().to_string(),
            space_key: raw["space"]["key"].as_str().unwrap_or_default().to_string(),
            url: self.page_url(id),
            html: raw["body"]["view"]["value"].as_str().unwrap_or_default().to_string(),
            version: raw["version"]["number"].as_u64().unwrap_or(0),
        })
    }

    /// 在 `parent_id` 页面下新建子页面，返回新页面的 id。
    pub async fn create_page(&self, parent_id: &str, title: &str, storage: &str) -> Result<String> {
        let parent = self.page(parent_id).await?;
        let body = json!({
            "type": "page",
            "title": title,
            "space": { "key": parent.space_key },
            "ancestors": [{ "id": parent_id }],
            "body": { "storage": { "value": storage, "representation": "storage" } },
        });
        let created: serde_json::Value = check(
            self.http
                .post(format!("{}/rest/api/content", self.base_url))
                .bearer_auth(&self.token)
                .json(&body)
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        created["id"].as_str().map(str::to_string).ok_or_else(|| Error::Other("创建页面失败：响应中没有页面 id".into()))
    }

    /// 给页面上传附件（正文中的图片）。
    pub async fn attach(&self, page_id: &str, filename: &str, mime: &str, bytes: Vec<u8>) -> Result<()> {
        let part = reqwest::multipart::Part::bytes(bytes)
            .file_name(filename.to_string())
            .mime_str(mime)
            .map_err(|e| Error::Other(e.to_string()))?;
        let form = reqwest::multipart::Form::new().part("file", part);
        check(
            self.http
                .post(format!("{}/rest/api/content/{page_id}/child/attachment", self.base_url))
                .bearer_auth(&self.token)
                // Confluence 对附件上传要求关闭 XSRF 校验
                .header("X-Atlassian-Token", "no-check")
                .multipart(form)
                .send()
                .await?,
        )
        .await?;
        Ok(())
    }

    /// 全文搜索页面（CQL）。
    pub async fn search(&self, text: &str, limit: u32) -> Result<Vec<SearchHit>> {
        let escaped = text.replace('\\', "\\\\").replace('"', "\\\"");
        let cql = format!("siteSearch ~ \"{escaped}\" AND type = page");
        let raw: serde_json::Value = check(
            self.get("/rest/api/search")
                .query(&[("cql", cql.as_str()), ("limit", &limit.to_string())])
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        let hits = raw["results"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|r| {
                let content = &r["content"];
                Some(SearchHit {
                    id: content["id"].as_str()?.to_string(),
                    title: content["title"].as_str().unwrap_or_default().to_string(),
                    space: r["resultGlobalContainer"]["title"].as_str().unwrap_or_default().to_string(),
                    url: format!("{}{}", self.base_url, r["url"].as_str().unwrap_or_default()),
                    excerpt: strip_highlight(r["excerpt"].as_str().unwrap_or_default()),
                })
            })
            .collect();
        Ok(hits)
    }

    /// 周报页面中自己的名字：配置了就用配置的，否则用 Confluence 显示名。
    pub async fn resolve_person_name(&self, configured: &str) -> Result<String> {
        if !configured.trim().is_empty() {
            return Ok(configured.trim().to_string());
        }
        Ok(self.current_user().await?.display_name)
    }

    /// 读取周报页面；`section` 为空时选择覆盖今天的小节或最新小节。
    pub async fn weekly_load(
        &self,
        page_id: &str,
        person_name: &str,
        section: Option<&str>,
        today: NaiveDate,
    ) -> Result<WeeklyView> {
        let page = self.page(page_id).await?;
        let overview = weekly::overview(&page.storage, today)?;
        let title = section.map(str::to_string).or_else(|| weekly::default_section(&overview));
        let entry = title.map(|t| weekly::entry(&page.storage, &t, person_name)).transpose()?;
        Ok(WeeklyView {
            page_url: self.page_url(&page.id),
            page_id: page.id,
            page_title: page.title,
            version: page.version,
            modified_by: page.modified_by,
            modified_at: page.modified_at,
            person_name: person_name.to_string(),
            overview,
            entry,
        })
    }

    /// 保存自己那一行。每次都基于最新版本改写；遇到并发保存（409）时重新读取再试。
    pub async fn weekly_save(
        &self,
        page_id: &str,
        person_name: &str,
        section: &str,
        expected: (&str, &str),
        content: &[OutlineItem],
        risk: &[OutlineItem],
    ) -> Result<SaveResult> {
        for _ in 0..SAVE_ATTEMPTS {
            let page = self.page(page_id).await?;
            let edit = weekly::apply_entry(&page.storage, section, person_name, Some(expected), content, risk)?;
            if !edit.changed {
                return Ok(SaveResult { changed: false, version: page.version });
            }
            match self.update_page(&page, &edit.storage, &format!("{person_name} 更新周报（NextWorkZone）")).await {
                Ok(version) => return Ok(SaveResult { changed: true, version }),
                Err(Error::Conflict(_)) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(Error::Conflict("页面正被频繁修改，请稍后重试".into()))
    }

    /// 在页面顶部新建本周小节（以最新一周为模板，标题沿用最新一周的日期写法），返回新小节的标题。
    pub async fn weekly_create_week(&self, page_id: &str, today: NaiveDate) -> Result<String> {
        for _ in 0..SAVE_ATTEMPTS {
            let page = self.page(page_id).await?;
            let title = weekly::overview(&page.storage, today)?.current_week_title;
            let storage = weekly::insert_week(&page.storage, &title)?;
            match self.update_page(&page, &storage, &format!("新建 {title} 周报小节（NextWorkZone）")).await {
                Ok(_) => return Ok(title),
                Err(Error::Conflict(_)) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(Error::Conflict("页面正被频繁修改，请稍后重试".into()))
    }
}

/// 搜索摘要中的高亮标记形如 `@@@hl@@@关键词@@@endhl@@@`。
pub(crate) fn strip_highlight(text: &str) -> String {
    let text = text.replace("@@@hl@@@", "").replace("@@@endhl@@@", "");
    storage::collapse_whitespace(&storage::decode_entities(&text))
}
