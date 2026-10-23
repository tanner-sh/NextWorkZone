//! 本机 Wiki 库：把页面的标题和正文（纯文本）保存到本机 SQLite，用于快速全文搜索、
//! 查找引用某个 Jira 问题的页面、找出分配给我的页面任务，以及记录最近在本应用中查看的页面。
//!
//! 数据随时可以从 Confluence 重建，不参与多设备同步。增量同步按“最后修改时间”进行；
//! 被删除或移出权限范围的页面每天对比一次全部页面 id 后清理。

use std::collections::HashSet;
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use nextworkzone_core::{Error, Result};
use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::text::{InlineTask, inline_tasks, jira_keys, readable_lines};
use crate::{Ancestor, ConfluenceClient, parse_time};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS pages (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    space_key TEXT NOT NULL,
    space_name TEXT NOT NULL,
    title TEXT NOT NULL,
    title_lc TEXT NOT NULL,
    -- 上级页面 [{id, title}]（JSON）
    ancestors TEXT NOT NULL,
    author TEXT NOT NULL,
    author_name TEXT NOT NULL,
    modified TEXT NOT NULL,
    modified_ms INTEGER NOT NULL,
    version INTEGER NOT NULL,
    text TEXT NOT NULL,
    text_lc TEXT NOT NULL,
    -- 引用的 Jira 问题键，前后加空格：' A-1 B-2 '
    jira_keys TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS pages_space ON pages(space_key);
CREATE INDEX IF NOT EXISTS pages_modified ON pages(modified_ms);
CREATE TABLE IF NOT EXISTS tasks (
    page_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    done INTEGER NOT NULL,
    text TEXT NOT NULL,
    -- 任务中提到的用户 key，前后加空格
    assignees TEXT NOT NULL,
    due TEXT,
    PRIMARY KEY (page_id, task_id)
);
CREATE TABLE IF NOT EXISTS viewed (id TEXT PRIMARY KEY, title TEXT NOT NULL, space_key TEXT NOT NULL, at INTEGER NOT NULL);
"#;

/// 保存格式的版本；文本处理方式改变后递增，旧数据会被清空重新同步。
const FORMAT_VERSION: &str = "1";
/// 带正文时 Confluence 每页最多返回 50 条。
const PAGE_SIZE: u32 = 50;
const ID_PAGE_SIZE: u32 = 500;
const PAGE_PAUSE: Duration = Duration::from_millis(200);
/// 单个页面保存的正文上限（字符）。超长的通常是日报汇总表，后面的内容搜索价值不大。
const MAX_TEXT_CHARS: usize = 200_000;
/// 多久对比一次全部页面 id，清理已删除的页面。
const PRUNE_INTERVAL_MS: i64 = 24 * 3600 * 1000;
const SNIPPET_CHARS: usize = 120;
const VIEWED_KEEP: i64 = 200;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiHit {
    pub id: String,
    /// `page` / `blogpost`
    pub kind: String,
    pub title: String,
    pub space_key: String,
    pub space_name: String,
    pub ancestors: Vec<Ancestor>,
    pub author_name: String,
    pub modified: String,
    /// 匹配处附近的文字。
    pub snippet: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WikiQuery {
    pub text: String,
    /// 空间 key，空为全部。
    pub space: String,
    /// 只看我创建或最后修改的（按最后修改人判断）。
    pub mine: bool,
    /// 最近多少天内修改过的；0 不限。
    pub days: u32,
    /// `page` / `blogpost`，空为全部。
    pub kind: String,
    pub limit: u32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiIndexStats {
    pub count: u64,
    pub spaces: Vec<IndexedSpace>,
    pub last_sync: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexedSpace {
    pub key: String,
    pub name: String,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiSyncProgress {
    pub done: u32,
    pub total: u32,
}

/// 分配给某人的页面任务。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssignedTask {
    pub page_id: String,
    pub page_title: String,
    #[serde(flatten)]
    pub task: InlineTask,
}

/// 最近查看的页面。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewedPage {
    pub id: String,
    pub title: String,
    pub space_key: String,
    /// 毫秒
    pub at: i64,
}

/// 同步时得到的一个页面。
pub struct IndexedPage {
    pub id: String,
    pub kind: String,
    pub space_key: String,
    pub space_name: String,
    pub title: String,
    pub ancestors: Vec<Ancestor>,
    pub author: String,
    pub author_name: String,
    pub modified: String,
    pub version: u64,
    pub storage: String,
}

pub struct WikiIndex {
    conn: Mutex<Connection>,
}

trait Db<T> {
    fn db(self) -> Result<T>;
}

impl<T> Db<T> for rusqlite::Result<T> {
    fn db(self) -> Result<T> {
        self.map_err(|e| Error::Other(format!("本机 Wiki 库错误：{e}")))
    }
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn time_ms(s: &str) -> i64 {
    parse_time(s).map(|t| t.timestamp_millis()).unwrap_or_default()
}

/// 比较用的文本：逐字转小写（保持字数不变，便于定位）。
fn fold(text: &str) -> String {
    text.chars().map(|c| c.to_lowercase().next().unwrap_or(c)).collect()
}

fn query_terms(text: &str) -> Vec<String> {
    let mut terms: Vec<String> = Vec::new();
    for t in text.split_whitespace().map(fold) {
        if !terms.contains(&t) && terms.len() < 8 {
            terms.push(t);
        }
    }
    terms
}

impl WikiIndex {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path).db()?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;").db()?;
        conn.execute_batch(SCHEMA).db()?;
        if Self::meta(&conn, "format")?.as_deref() != Some(FORMAT_VERSION) {
            conn.execute_batch("DELETE FROM pages; DELETE FROM tasks; DELETE FROM meta WHERE key IN ('cursor', 'last_sync', 'last_prune');").db()?;
            Self::set_meta(&conn, "format", FORMAT_VERSION)?;
        }
        Ok(Self { conn: Mutex::new(conn) })
    }

    fn meta(conn: &Connection, key: &str) -> Result<Option<String>> {
        conn.query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| r.get(0)).optional().db()
    }

    fn set_meta(conn: &Connection, key: &str, value: &str) -> Result<()> {
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)", params![key, value]).db()?;
        Ok(())
    }

    fn get(&self, key: &str) -> Result<Option<String>> {
        Self::meta(&self.conn.lock().unwrap(), key)
    }

    fn put(&self, key: &str, value: &str) -> Result<()> {
        Self::set_meta(&self.conn.lock().unwrap(), key, value)
    }

    /// 连接的 Wiki 地址或同步范围变化后清空页面和查看记录。
    pub fn ensure_scope(&self, base_url: &str, spaces: &[String]) -> Result<()> {
        let scope = format!("{base_url}|{}", spaces.join(","));
        let conn = self.conn.lock().unwrap();
        let old = Self::meta(&conn, "scope")?;
        if old.as_deref() != Some(scope.as_str()) {
            let same_site = old.as_deref().and_then(|o| o.split('|').next()) == Some(base_url);
            conn.execute_batch("DELETE FROM pages; DELETE FROM tasks; DELETE FROM meta WHERE key IN ('cursor', 'last_sync', 'last_prune');").db()?;
            if !same_site {
                conn.execute_batch("DELETE FROM viewed;").db()?;
            }
            Self::set_meta(&conn, "scope", &scope)?;
        }
        Ok(())
    }

    /// 清空页面数据，下次同步时重新获取。查看记录保留。
    pub fn clear(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch("DELETE FROM pages; DELETE FROM tasks; DELETE FROM meta WHERE key IN ('cursor', 'last_sync', 'last_prune', 'scope');").db()?;
        Ok(())
    }

    pub fn upsert(&self, pages: &[IndexedPage]) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let tx = conn.unchecked_transaction().db()?;
        for p in pages {
            let mut text = readable_lines(&p.storage).join("\n");
            if let Some((cut, _)) = text.char_indices().nth(MAX_TEXT_CHARS) {
                text.truncate(cut);
            }
            let keys = jira_keys(&p.storage, &text);
            tx.execute(
                "INSERT OR REPLACE INTO pages (id, kind, space_key, space_name, title, title_lc, ancestors, author, author_name, modified, modified_ms, version, text, text_lc, jira_keys)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
                params![
                    p.id,
                    p.kind,
                    p.space_key,
                    p.space_name,
                    p.title,
                    fold(&p.title),
                    serde_json::to_string(&p.ancestors)?,
                    p.author,
                    p.author_name,
                    p.modified,
                    time_ms(&p.modified),
                    p.version as i64,
                    text,
                    fold(&text),
                    format!(" {} ", keys.join(" ")),
                ],
            )
            .db()?;
            tx.execute("DELETE FROM tasks WHERE page_id = ?1", params![p.id]).db()?;
            for t in inline_tasks(&p.storage) {
                tx.execute(
                    "INSERT OR REPLACE INTO tasks (page_id, task_id, done, text, assignees, due) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![p.id, t.task_id, t.done, t.text, format!(" {} ", t.assignees.join(" ")), t.due],
                )
                .db()?;
            }
        }
        tx.commit().db()?;
        Ok(())
    }

    /// 删除不在 `alive` 中的页面。
    fn prune(&self, alive: &HashSet<String>) -> Result<usize> {
        let conn = self.conn.lock().unwrap();
        let ids: Vec<String> = {
            let mut stmt = conn.prepare("SELECT id FROM pages").db()?;
            stmt.query_map([], |r| r.get(0)).db()?.collect::<rusqlite::Result<_>>().db()?
        };
        let tx = conn.unchecked_transaction().db()?;
        let mut removed = 0;
        for id in ids.iter().filter(|id| !alive.contains(*id)) {
            tx.execute("DELETE FROM pages WHERE id = ?1", params![id]).db()?;
            tx.execute("DELETE FROM tasks WHERE page_id = ?1", params![id]).db()?;
            removed += 1;
        }
        tx.commit().db()?;
        Ok(removed)
    }

    pub fn stats(&self) -> Result<WikiIndexStats> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT space_key, MAX(space_name), COUNT(*) FROM pages GROUP BY space_key ORDER BY COUNT(*) DESC")
            .db()?;
        let spaces = stmt
            .query_map([], |r| Ok(IndexedSpace { key: r.get(0)?, name: r.get(1)?, count: r.get::<_, i64>(2)? as u64 }))
            .db()?
            .collect::<rusqlite::Result<Vec<_>>>()
            .db()?;
        Ok(WikiIndexStats { count: spaces.iter().map(|s| s.count).sum(), spaces, last_sync: Self::meta(&conn, "last_sync")? })
    }

    pub fn is_empty(&self) -> Result<bool> {
        let conn = self.conn.lock().unwrap();
        Ok(conn.query_row("SELECT COUNT(*) FROM pages", [], |r| r.get::<_, i64>(0)).db()? == 0)
    }

    /// 关键词搜索。多个关键词（空格分隔）需全部出现；标题中的匹配排在前面。`me` 为当前用户 key。
    pub fn search(&self, query: &WikiQuery, me: &str) -> Result<Vec<WikiHit>> {
        let terms = query_terms(&query.text);
        let mut args: Vec<SqlValue> = Vec::new();
        let mut arg = |v: SqlValue| {
            args.push(v);
            format!("?{}", args.len())
        };
        let mut conditions: Vec<String> = Vec::new();
        let mut score: Vec<String> = Vec::new();
        for term in &terms {
            let p = arg(SqlValue::Text(term.clone()));
            conditions.push(format!("(instr(title_lc, {p}) OR instr(text_lc, {p}))"));
            score.push(format!("(instr(title_lc, {p}) > 0) * 10"));
        }
        if !query.space.is_empty() {
            conditions.push(format!("space_key = {}", arg(SqlValue::Text(query.space.clone()))));
        }
        if !query.kind.is_empty() {
            conditions.push(format!("kind = {}", arg(SqlValue::Text(query.kind.clone()))));
        }
        if query.mine && !me.is_empty() {
            conditions.push(format!("author = {}", arg(SqlValue::Text(me.to_string()))));
        }
        if query.days > 0 {
            let since = now_ms() - i64::from(query.days) * 24 * 3600 * 1000;
            conditions.push(format!("modified_ms >= {}", arg(SqlValue::Integer(since))));
        }
        let limit = if query.limit == 0 { 50 } else { query.limit.min(300) };
        let sql = format!(
            "SELECT id, kind, title, space_key, space_name, ancestors, author_name, modified, text FROM pages {} ORDER BY {} modified_ms DESC LIMIT {limit}",
            if conditions.is_empty() { String::new() } else { format!("WHERE {}", conditions.join(" AND ")) },
            if score.is_empty() { String::new() } else { format!("({}) DESC,", score.join(" + ")) },
        );
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&sql).db()?;
        let rows = stmt
            .query_map(params_from_iter(args), |r| {
                let text: String = r.get(8)?;
                let ancestors: String = r.get(5)?;
                Ok(WikiHit {
                    id: r.get(0)?,
                    kind: r.get(1)?,
                    title: r.get(2)?,
                    space_key: r.get(3)?,
                    space_name: r.get(4)?,
                    ancestors: serde_json::from_str(&ancestors).unwrap_or_default(),
                    author_name: r.get(6)?,
                    modified: r.get(7)?,
                    snippet: snippet(&text, &terms),
                })
            })
            .db()?
            .collect::<rusqlite::Result<Vec<_>>>()
            .db()?;
        Ok(rows)
    }

    /// 引用了某个 Jira 问题的页面（Jira 宏或正文中出现问题键）。
    pub fn pages_with_issue(&self, key: &str, limit: u32) -> Result<Vec<WikiHit>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT id, kind, title, space_key, space_name, ancestors, author_name, modified, text FROM pages
                 WHERE instr(jira_keys, ?1) > 0 ORDER BY modified_ms DESC LIMIT {limit}"
            ))
            .db()?;
        let terms = vec![fold(key)];
        stmt.query_map(params![format!(" {key} ")], |r| {
            let text: String = r.get(8)?;
            let ancestors: String = r.get(5)?;
            Ok(WikiHit {
                id: r.get(0)?,
                kind: r.get(1)?,
                title: r.get(2)?,
                space_key: r.get(3)?,
                space_name: r.get(4)?,
                ancestors: serde_json::from_str(&ancestors).unwrap_or_default(),
                author_name: r.get(6)?,
                modified: r.get(7)?,
                snippet: snippet(&text, &terms),
            })
        })
        .db()?
        .collect::<rusqlite::Result<Vec<_>>>()
        .db()
    }

    /// 页面标题（本机有记录时），用于显示 Jira 远程链接等只有页面 id 的地方。
    pub fn titles(&self, ids: &[String]) -> Result<Vec<(String, String, String)>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT title, space_name FROM pages WHERE id = ?1").db()?;
        let mut out = Vec::new();
        for id in ids {
            if let Some((title, space)) = stmt.query_row(params![id], |r| Ok((r.get(0)?, r.get(1)?))).optional().db()? {
                out.push((id.clone(), title, space));
            }
        }
        Ok(out)
    }

    /// 分配给 `user`（userkey）的未完成任务。
    pub fn assigned_tasks(&self, user: &str) -> Result<Vec<AssignedTask>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT t.page_id, p.title, t.task_id, t.done, t.text, t.assignees, t.due FROM tasks t JOIN pages p ON p.id = t.page_id
                 WHERE instr(t.assignees, ?1) > 0 AND t.done = 0 ORDER BY p.modified_ms DESC",
            )
            .db()?;
        stmt.query_map(params![format!(" {user} ")], |r| {
            let assignees: String = r.get(5)?;
            Ok(AssignedTask {
                page_id: r.get(0)?,
                page_title: r.get(1)?,
                task: InlineTask {
                    task_id: r.get(2)?,
                    done: r.get(3)?,
                    text: r.get(4)?,
                    assignees: assignees.split_whitespace().map(str::to_string).collect(),
                    due: r.get(6)?,
                },
            })
        })
        .db()?
        .collect::<rusqlite::Result<Vec<_>>>()
        .db()
    }

    /// 记下页面任务的新状态（勾选后立即生效，不必等下次同步）。
    pub fn set_task_done(&self, page_id: &str, task_id: &str, done: bool) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("UPDATE tasks SET done = ?3 WHERE page_id = ?1 AND task_id = ?2", params![page_id, task_id, done]).db()?;
        Ok(())
    }

    // ---------- 查看记录 ----------

    pub fn mark_viewed(&self, id: &str, title: &str, space_key: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("INSERT OR REPLACE INTO viewed (id, title, space_key, at) VALUES (?1, ?2, ?3, ?4)", params![id, title, space_key, now_ms()])
            .db()?;
        conn.execute(
            &format!("DELETE FROM viewed WHERE id NOT IN (SELECT id FROM viewed ORDER BY at DESC LIMIT {VIEWED_KEEP})"),
            [],
        )
        .db()?;
        Ok(())
    }

    pub fn recent(&self, limit: u32) -> Result<Vec<ViewedPage>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!("SELECT id, title, space_key, at FROM viewed ORDER BY at DESC LIMIT {limit}")).db()?;
        stmt.query_map([], |r| Ok(ViewedPage { id: r.get(0)?, title: r.get(1)?, space_key: r.get(2)?, at: r.get(3)? }))
            .db()?
            .collect::<rusqlite::Result<Vec<_>>>()
            .db()
    }
}

/// 第一个关键词在正文中出现处附近的文字；没有关键词或只在标题中出现时取正文开头。
fn snippet(text: &str, terms: &[String]) -> String {
    let chars: Vec<char> = text.chars().collect();
    let lower: Vec<char> = chars.iter().map(|c| c.to_lowercase().next().unwrap_or(*c)).collect();
    let start = terms.iter().find_map(|t| {
        let needle: Vec<char> = t.chars().collect();
        if needle.is_empty() || needle.len() > lower.len() {
            return None;
        }
        (0..=lower.len() - needle.len()).find(|&i| lower[i..i + needle.len()] == needle[..])
    });
    let from = start.map_or(0, |s| s.saturating_sub(30));
    let piece: String = chars.iter().skip(from).take(SNIPPET_CHARS).collect();
    let piece = piece.split_whitespace().collect::<Vec<_>>().join(" ");
    if from > 0 { format!("…{piece}") } else { piece }
}

/// 同步的范围：`spaces` 为空时同步全部可见的空间。
#[derive(Debug, Clone)]
pub struct WikiScope {
    pub spaces: Vec<String>,
}

impl WikiScope {
    fn cql(&self) -> String {
        let mut cql = "type in (page, blogpost)".to_string();
        if !self.spaces.is_empty() {
            let list = self.spaces.iter().map(|s| format!("\"{}\"", s.replace('"', ""))).collect::<Vec<_>>().join(", ");
            cql.push_str(&format!(" AND space in ({list})"));
        }
        cql
    }
}

/// 增量同步：获取上次同步之后修改过的页面；每天清理一次已删除的页面。返回更新的页面数。
pub async fn sync(client: &ConfluenceClient, index: &WikiIndex, scope: &WikiScope, mut progress: impl FnMut(WikiSyncProgress)) -> Result<usize> {
    index.ensure_scope(client.base_url(), &scope.spaces)?;
    let base = scope.cql();
    // 用相对时间表示增量起点，与 Confluence 用户的时区设置无关；多回看几分钟，重复的直接覆盖
    let since = match index.get("cursor")?.as_deref().and_then(parse_time) {
        Some(t) => format!(" AND lastmodified >= now(\"-{}m\")", (chrono::Utc::now() - t.to_utc()).num_minutes().max(0) + 5),
        None => String::new(),
    };
    let cql = format!("{base}{since} ORDER BY lastmodified ASC");
    let mut start = 0;
    let mut changed = 0;
    let mut total = 0;
    loop {
        let Some((count, pages)) = fetch_batch(client, &cql, start).await? else {
            // 连续失败的页面跳过；第一批就失败说明服务器不可用
            if start == 0 {
                return Err(Error::Other("获取 Wiki 页面失败，请稍后重试".into()));
            }
            start += 1;
            if start >= total {
                break;
            }
            continue;
        };
        total = count;
        if pages.is_empty() {
            break;
        }
        index.upsert(&pages)?;
        if let Some(latest) = pages.iter().map(|p| p.modified.as_str()).max_by_key(|s| time_ms(s)) {
            index.put("cursor", latest)?;
        }
        start += pages.len() as u32;
        changed += pages.len();
        progress(WikiSyncProgress { done: start.min(total), total });
        if start >= total {
            break;
        }
        tokio::time::sleep(PAGE_PAUSE).await;
    }
    let last_prune: i64 = index.get("last_prune")?.and_then(|v| v.parse().ok()).unwrap_or(0);
    if now_ms() - last_prune > PRUNE_INTERVAL_MS {
        let alive = client.all_ids(&base, ID_PAGE_SIZE).await?;
        index.prune(&alive)?;
        index.put("last_prune", &now_ms().to_string())?;
    }
    index.put("last_sync", &chrono::Local::now().to_rfc3339())?;
    Ok(changed)
}

/// 取一批页面：（总数，页面）。超长页面多的一批可能超时，此时缩小批量重试；
/// 单个页面仍然失败时返回 `None`，由调用方跳过它，不让一个页面卡住整个同步。
async fn fetch_batch(client: &ConfluenceClient, cql: &str, start: u32) -> Result<Option<(u32, Vec<IndexedPage>)>> {
    for size in [PAGE_SIZE, 10, 1] {
        match client.index_page(cql, start, size).await {
            Ok(batch) => return Ok(Some(batch)),
            Err(e @ (Error::Unauthorized { .. } | Error::Forbidden { .. } | Error::SessionRequired(_))) => return Err(e),
            Err(_) => continue,
        }
    }
    Ok(None)
}

impl ConfluenceClient {
    /// 同步用的一页数据：（总数，页面）。
    pub async fn index_page(&self, cql: &str, start: u32, limit: u32) -> Result<(u32, Vec<IndexedPage>)> {
        let raw = self
            .get_json(self.get("/rest/api/content/search").query(&[
                ("cql", cql),
                ("start", &start.to_string()),
                ("limit", &limit.to_string()),
                ("expand", "body.storage,version,space,ancestors"),
            ]))
            .await?;
        let total = raw["totalSize"].as_u64().unwrap_or(0) as u32;
        let pages = raw["results"].as_array().into_iter().flatten().filter_map(indexed_page).collect();
        Ok((total, pages))
    }

    /// 范围内全部页面的 id（用于清理已删除的页面）。
    async fn all_ids(&self, cql: &str, limit: u32) -> Result<HashSet<String>> {
        let mut ids = HashSet::new();
        let mut start = 0;
        loop {
            let raw = self
                .get_json(self.get("/rest/api/content/search").query(&[("cql", cql), ("start", &start.to_string()), ("limit", &limit.to_string())]))
                .await?;
            let results = raw["results"].as_array().cloned().unwrap_or_default();
            if results.is_empty() {
                break;
            }
            ids.extend(results.iter().filter_map(|r| r["id"].as_str().map(str::to_string)));
            // 服务器可能把每页数量限制得比请求的小，按实际返回数前进
            start += results.len() as u32;
            if u64::from(start) >= raw["totalSize"].as_u64().unwrap_or(0) {
                break;
            }
            tokio::time::sleep(PAGE_PAUSE).await;
        }
        Ok(ids)
    }
}

fn indexed_page(r: &Value) -> Option<IndexedPage> {
    Some(IndexedPage {
        id: r["id"].as_str()?.to_string(),
        kind: r["type"].as_str().unwrap_or("page").to_string(),
        space_key: r["space"]["key"].as_str().unwrap_or_default().to_string(),
        space_name: r["space"]["name"].as_str().unwrap_or_default().to_string(),
        title: r["title"].as_str().unwrap_or_default().to_string(),
        ancestors: crate::ancestors(&r["ancestors"]),
        author: r["version"]["by"]["userKey"].as_str().unwrap_or_default().to_string(),
        author_name: r["version"]["by"]["displayName"].as_str().unwrap_or_default().to_string(),
        modified: r["version"]["when"].as_str().unwrap_or_default().to_string(),
        version: r["version"]["number"].as_u64().unwrap_or(0),
        storage: r["body"]["storage"]["value"].as_str().unwrap_or_default().to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(id: &str, title: &str, storage: &str) -> IndexedPage {
        IndexedPage {
            id: id.into(),
            kind: "page".into(),
            space_key: "S".into(),
            space_name: "空间".into(),
            title: title.into(),
            ancestors: vec![Ancestor { id: "1".into(), title: "首页".into() }],
            author: "me".into(),
            author_name: "我".into(),
            modified: "2026-10-20T10:00:00.000+08:00".into(),
            version: 3,
            storage: storage.into(),
        }
    }

    #[test]
    fn search_and_references() {
        let dir = tempfile::tempdir().unwrap();
        let index = WikiIndex::open(&dir.path().join("w.db")).unwrap();
        index
            .upsert(&[
                page("10", "部署手册", "<p>如何部署 Nginx 服务 ABC-12</p>"),
                page("11", "周报", r#"<p>本周处理 <ac:structured-macro ac:name="jira"><ac:parameter ac:name="key">ABC-12</ac:parameter></ac:structured-macro></p><ac:task-list><ac:task><ac:task-id>1</ac:task-id><ac:task-status>incomplete</ac:task-status><ac:task-body>跟进部署 <ac:link><ri:user ri:userkey="me" /></ac:link></ac:task-body></ac:task></ac:task-list>"#),
            ])
            .unwrap();
        let hits = index.search(&WikiQuery { text: "部署".into(), ..Default::default() }, "").unwrap();
        assert_eq!(hits[0].id, "10", "标题匹配排在前面");
        assert_eq!(hits.len(), 2);
        let hits = index.search(&WikiQuery { text: "nginx 服务".into(), ..Default::default() }, "").unwrap();
        assert_eq!(hits.len(), 1);
        assert!(hits[0].snippet.contains("Nginx"));
        assert_eq!(index.pages_with_issue("ABC-12", 10).unwrap().len(), 2);
        assert!(index.pages_with_issue("ABC-1", 10).unwrap().is_empty());
        let tasks = index.assigned_tasks("me").unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].page_title, "周报");
        index.set_task_done("11", "1", true).unwrap();
        assert!(index.assigned_tasks("me").unwrap().is_empty());
        index.prune(&HashSet::from(["10".to_string()])).unwrap();
        assert_eq!(index.stats().unwrap().count, 1);
    }

    #[test]
    fn viewed_pages() {
        let dir = tempfile::tempdir().unwrap();
        let index = WikiIndex::open(&dir.path().join("w.db")).unwrap();
        index.mark_viewed("1", "A", "S").unwrap();
        index.mark_viewed("2", "B", "S").unwrap();
        index.mark_viewed("1", "A", "S").unwrap();
        let recent = index.recent(10).unwrap();
        assert_eq!(recent.len(), 2);
    }
}
