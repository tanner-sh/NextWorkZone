//! 本机问题库：把一定范围内的问题（概要、描述、评论）保存到本机 SQLite，
//! 用于离线全文搜索、相似问题（附带处理过程），以及记录每个问题上次查看的时间。
//!
//! 问题数据随时可以从 Jira 重建，不参与多设备同步。增量同步按“更新时间”进行：
//! 每个范围（自动模式下每个项目一个，自定义 JQL 一个）记录已同步到的最晚更新时间。

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use nextworkzone_core::{Error, Result};
use regex::Regex;
use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::activity::parse_time;
use crate::fields::value_text;
use crate::model::{IssueSummary, RawIssue};
use crate::{JiraClient, jql_escape, looks_like_key, summary_terms};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS issues (
    key TEXT PRIMARY KEY,
    project TEXT NOT NULL,
    project_name TEXT NOT NULL,
    updated_ms INTEGER NOT NULL,
    resolved INTEGER NOT NULL,
    summary_lc TEXT NOT NULL,
    description_lc TEXT NOT NULL,
    comments_lc TEXT NOT NULL,
    -- 经办人、报告人、评论人的用户名，前后加空格：' a b '
    participants TEXT NOT NULL,
    data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS issues_project ON issues(project);
CREATE TABLE IF NOT EXISTS cursors (scope TEXT PRIMARY KEY, cursor TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS viewed (key TEXT PRIMARY KEY, at INTEGER NOT NULL);
-- 在很多问题中重复出现的评论开头（流程机器人、固定话术），相似问题中不作为处理过程显示
CREATE TABLE IF NOT EXISTS boilerplate (prefix TEXT PRIMARY KEY, n INTEGER NOT NULL);
"#;

/// 同步时请求的字段。
const INDEX_FIELDS: &str =
    "summary,status,issuetype,priority,project,assignee,reporter,resolution,created,updated,duedate,resolutiondate,description,comment";
const PAGE_SIZE: u32 = 100;
/// 保存格式的版本；文本处理方式改变后递增，旧数据会被清空重新同步。
const FORMAT_VERSION: &str = "3";
/// 两页之间稍作停顿，避免首次建库时给服务器太大压力。
const PAGE_PAUSE: Duration = Duration::from_millis(200);
/// 相似问题中显示的最后几条评论。
const LAST_COMMENTS: usize = 2;
const COMMENT_CHARS: usize = 300;
/// 评论开头取多少字判断是否为固定话术。
const BOILERPLATE_CHARS: usize = 20;
/// 同样开头的评论出现在多少个问题中算作固定话术。
const BOILERPLATE_MIN: i64 = 20;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BriefComment {
    pub author: String,
    pub author_name: String,
    pub created: String,
    /// 去掉 wiki 标记后的纯文本。
    pub body: String,
}

/// 本机保存的一个问题。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexedIssue {
    pub issue: IssueSummary,
    pub resolved: Option<String>,
    pub description: String,
    pub comments: Vec<BriefComment>,
}

/// 搜索结果或相似问题。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueHit {
    #[serde(flatten)]
    pub issue: IssueSummary,
    /// 解决时间。
    pub resolved: Option<String>,
    pub comment_count: usize,
    /// 描述或评论中匹配处附近的文字。
    pub snippet: Option<Snippet>,
    /// 最后几条评论（相似问题中用于了解处理过程）。
    pub last_comments: Vec<BriefComment>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snippet {
    /// `description` / `comment`
    pub source: String,
    /// 评论的作者。
    pub author: Option<String>,
    pub text: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IndexQuery {
    pub text: String,
    /// 项目键，空为全部。
    pub project: String,
    /// `all` / `unresolved` / `resolved`
    pub state: String,
    /// 只看我参与过的（经办、报告或评论过）。
    pub mine: bool,
    pub limit: u32,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexedProject {
    pub key: String,
    pub name: String,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexStats {
    pub count: u64,
    pub projects: Vec<IndexedProject>,
    /// 最近一次同步完成的时间（RFC 3339）。
    pub last_sync: Option<String>,
}

/// 同步进度。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncProgress {
    /// 正在同步的范围（项目键或“自定义范围”）。
    pub scope: String,
    pub done: u32,
    pub total: u32,
    /// 已完成的范围数 / 范围总数。
    pub finished: usize,
    pub scopes: usize,
}

/// 同步的范围：`jql` 为空时自动选择“我经办过或报告过问题的项目”。
#[derive(Debug, Clone)]
pub struct IndexScope {
    pub jql: String,
    /// 只同步最近多少天内创建的问题；0 表示不限。
    pub days: u32,
}

pub struct IssueIndex {
    conn: Mutex<Connection>,
}

trait Db<T> {
    fn db(self) -> Result<T>;
}

impl<T> Db<T> for rusqlite::Result<T> {
    fn db(self) -> Result<T> {
        self.map_err(|e| Error::Other(format!("本机问题库错误：{e}")))
    }
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn time_ms(s: &str) -> i64 {
    parse_time(s).map(|t| t.timestamp_millis()).unwrap_or_default()
}

impl IssueIndex {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path).db()?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;").db()?;
        conn.execute_batch(SCHEMA).db()?;
        if Self::meta(&conn, "format")?.as_deref() != Some(FORMAT_VERSION) {
            conn.execute_batch("DELETE FROM issues; DELETE FROM cursors; DELETE FROM boilerplate; DELETE FROM meta WHERE key = 'last_sync';").db()?;
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

    /// 连接的 Jira 地址变化后清空问题和查看记录（属于另一个系统）。
    pub fn ensure_base(&self, base_url: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        match Self::meta(&conn, "base_url")? {
            Some(old) if old == base_url => {}
            Some(_) => {
                conn.execute_batch("DELETE FROM issues; DELETE FROM cursors; DELETE FROM viewed; DELETE FROM boilerplate; DELETE FROM meta WHERE key != 'format';").db()?;
                Self::set_meta(&conn, "base_url", base_url)?;
            }
            None => Self::set_meta(&conn, "base_url", base_url)?,
        }
        Ok(())
    }

    /// 清空问题数据，下次同步时重新获取。查看记录保留。
    pub fn clear(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch("DELETE FROM issues; DELETE FROM cursors; DELETE FROM boilerplate; DELETE FROM meta WHERE key = 'last_sync';").db()?;
        Ok(())
    }

    fn cursor(&self, scope: &str) -> Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT cursor FROM cursors WHERE scope = ?1", params![scope], |r| r.get(0)).optional().db()
    }

    fn set_cursor(&self, scope: &str, cursor: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("INSERT OR REPLACE INTO cursors (scope, cursor) VALUES (?1, ?2)", params![scope, cursor]).db()?;
        Ok(())
    }

    /// 同步完成：记录时间；有数据变化（或还没统计过）时重新统计固定话术。
    fn finish_sync(&self, changed: usize) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let counted: i64 = conn.query_row("SELECT COUNT(*) FROM boilerplate", [], |r| r.get(0)).db()?;
        if changed > 0 || counted == 0 {
            conn.execute_batch(&format!(
                "DELETE FROM boilerplate;
                 INSERT INTO boilerplate (prefix, n)
                 SELECT p, COUNT(DISTINCT k) FROM (
                     SELECT issues.key AS k, substr(json_extract(c.value, '$.body'), 1, {BOILERPLATE_CHARS}) AS p
                       FROM issues, json_each(issues.data, '$.comments') AS c
                 ) WHERE length(p) > 0 GROUP BY p HAVING COUNT(DISTINCT k) >= {BOILERPLATE_MIN};"
            ))
            .db()?;
        }
        Self::set_meta(&conn, "last_sync", &chrono::Local::now().to_rfc3339())
    }

    fn boilerplate(conn: &Connection) -> Result<HashSet<String>> {
        let mut stmt = conn.prepare("SELECT prefix FROM boilerplate").db()?;
        stmt.query_map([], |r| r.get(0)).db()?.collect::<rusqlite::Result<_>>().db()
    }

    pub fn upsert(&self, issues: &[IndexedIssue]) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let tx = conn.unchecked_transaction().db()?;
        for item in issues {
            let i = &item.issue;
            let mut people: Vec<&str> = [i.assignee_name.as_deref(), i.reporter_name.as_deref()].into_iter().flatten().collect();
            people.extend(item.comments.iter().map(|c| c.author_name.as_str()));
            let participants: HashSet<&str> = people.into_iter().filter(|p| !p.is_empty()).collect();
            let participants = format!(" {} ", participants.into_iter().collect::<Vec<_>>().join(" "));
            let comments = item.comments.iter().map(|c| c.body.as_str()).collect::<Vec<_>>().join("\n");
            tx.execute(
                "INSERT OR REPLACE INTO issues (key, project, project_name, updated_ms, resolved, summary_lc, description_lc, comments_lc, participants, data)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    i.key,
                    project_of(&i.key),
                    i.project.name,
                    time_ms(&i.updated),
                    i.resolution.is_some(),
                    fold(&i.summary),
                    fold(&item.description),
                    fold(&comments),
                    participants,
                    serde_json::to_string(item)?,
                ],
            )
            .db()?;
        }
        tx.commit().db()?;
        Ok(())
    }

    pub fn stats(&self) -> Result<IndexStats> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT project, MAX(project_name), COUNT(*) FROM issues GROUP BY project ORDER BY COUNT(*) DESC")
            .db()?;
        let projects = stmt
            .query_map([], |r| Ok(IndexedProject { key: r.get(0)?, name: r.get(1)?, count: r.get::<_, i64>(2)? as u64 }))
            .db()?
            .collect::<rusqlite::Result<Vec<_>>>()
            .db()?;
        Ok(IndexStats { count: projects.iter().map(|p| p.count).sum(), projects, last_sync: Self::meta(&conn, "last_sync")? })
    }

    /// 关键词搜索。多个关键词（空格分隔）需全部出现；概要中的匹配排在前面。
    pub fn search(&self, query: &IndexQuery, me: &str) -> Result<Vec<IssueHit>> {
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
            let mut matches = format!("instr(summary_lc, {p}) OR instr(description_lc, {p}) OR instr(comments_lc, {p})");
            if looks_like_key(term) {
                let k = arg(SqlValue::Text(term.to_uppercase()));
                matches.push_str(&format!(" OR key = {k}"));
                score.push(format!("(key = {k}) * 100"));
            }
            conditions.push(format!("({matches})"));
            score.push(format!("(instr(summary_lc, {p}) > 0) * 10 + (instr(description_lc, {p}) > 0) * 3 + (instr(comments_lc, {p}) > 0)"));
        }
        if !query.project.is_empty() {
            conditions.push(format!("project = {}", arg(SqlValue::Text(query.project.clone()))));
        }
        match query.state.as_str() {
            "unresolved" => conditions.push("resolved = 0".into()),
            "resolved" => conditions.push("resolved = 1".into()),
            _ => {}
        }
        if query.mine && !me.is_empty() {
            conditions.push(format!("instr(participants, {}) > 0", arg(SqlValue::Text(format!(" {me} ")))));
        }
        let limit = if query.limit == 0 { 100 } else { query.limit.min(500) };
        let sql = format!(
            "SELECT data FROM issues {} ORDER BY {} updated_ms DESC LIMIT {limit}",
            if conditions.is_empty() { String::new() } else { format!("WHERE {}", conditions.join(" AND ")) },
            if score.is_empty() { String::new() } else { format!("({}) DESC,", score.join(" + ")) },
        );
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&sql).db()?;
        let rows = stmt.query_map(params_from_iter(args), |r| r.get::<_, String>(0)).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?;
        Ok(rows.iter().filter_map(|data| serde_json::from_str::<IndexedIssue>(data).ok()).map(|i| hit(i, &terms, None)).collect())
    }

    /// 按 key 取本机问题库中的问题（没有的忽略），按给定顺序返回。
    pub fn by_keys(&self, keys: &[String]) -> Result<Vec<IssueHit>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT data FROM issues WHERE key = ?1").db()?;
        let mut hits = Vec::new();
        for key in keys {
            if let Some(data) = stmt.query_row([key.to_uppercase()], |r| r.get::<_, String>(0)).optional().db()?
                && let Ok(item) = serde_json::from_str::<IndexedIssue>(&data)
            {
                hits.push(hit(item, &[], None));
            }
        }
        Ok(hits)
    }

    /// 描述或评论中出现任一 `needles`（已转小写）的问题，最近更新的在前。
    /// `accept` 再用描述、评论原文逐条确认（例如排除 `/merge_requests/12` 匹配到 `/merge_requests/123`）。
    pub fn mentioning(&self, needles: &[String], accept: impl Fn(&str) -> bool, limit: u32) -> Result<Vec<IssueHit>> {
        if needles.is_empty() {
            return Ok(Vec::new());
        }
        let conditions: Vec<String> =
            (1..=needles.len()).map(|i| format!("instr(description_lc, ?{i}) OR instr(comments_lc, ?{i})")).collect();
        let sql = format!("SELECT data FROM issues WHERE {} ORDER BY updated_ms DESC LIMIT 200", conditions.join(" OR "));
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&sql).db()?;
        let rows = stmt.query_map(params_from_iter(needles.iter()), |r| r.get::<_, String>(0)).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?;
        Ok(rows
            .iter()
            .filter_map(|data| serde_json::from_str::<IndexedIssue>(data).ok())
            .filter(|item| std::iter::once(&item.description).chain(item.comments.iter().map(|c| &c.body)).any(|t| accept(t)))
            .take(limit as usize)
            .map(|item| hit(item, needles, None))
            .collect())
    }

    /// 本机问题库中与给定概要相似的问题。问题库中没有这个项目的问题时返回 `None`（由调用方改用 Jira 搜索）。
    ///
    /// 关键词的权重按“越少见越重要”计算：在概要中出现计 3 倍，在描述开头出现计 1 倍；至少要有一个关键词出现在概要中。
    pub fn similar(&self, key: &str, summary: &str, resolved_only: bool, limit: u32) -> Result<Option<Vec<IssueHit>>> {
        let conn = self.conn.lock().unwrap();
        let project = project_of(key);
        let indexed: i64 = conn.query_row("SELECT COUNT(*) FROM issues WHERE project = ?1", params![project], |r| r.get(0)).db()?;
        if indexed == 0 {
            return Ok(None);
        }
        let terms: Vec<String> = summary_terms(summary).iter().map(|t| fold(t)).collect();
        if terms.is_empty() {
            return Ok(Some(Vec::new()));
        }
        let total: i64 = conn.query_row("SELECT COUNT(*) FROM issues", [], |r| r.get(0)).db()?;
        let counts: Vec<i64> = {
            let sql = format!(
                "SELECT {} FROM issues",
                (1..=terms.len()).map(|i| format!("COALESCE(SUM(instr(summary_lc, ?{i}) > 0), 0)")).collect::<Vec<_>>().join(", ")
            );
            conn.query_row(&sql, params_from_iter(terms.iter()), |r| (0..terms.len()).map(|i| r.get::<_, i64>(i)).collect())
                .db()?
        };
        let mut score = Vec::new();
        let mut any = Vec::new();
        for (i, df) in counts.iter().enumerate() {
            if *df == 0 {
                continue;
            }
            let weight = ((total as f64 + 1.0) / (*df as f64 + 1.0)).ln().max(0.05);
            let p = format!("?{}", i + 1);
            score.push(format!("(instr(summary_lc, {p}) > 0) * {:.4} + (instr(substr(description_lc, 1, 1000), {p}) > 0) * {:.4}", weight * 3.0, weight));
            any.push(format!("instr(summary_lc, {p})"));
        }
        if any.is_empty() {
            return Ok(Some(Vec::new()));
        }
        let key_param = terms.len() + 1;
        let sql = format!(
            "SELECT data FROM issues WHERE key != ?{key_param} AND ({}){} ORDER BY ({}) DESC, updated_ms DESC LIMIT {limit}",
            any.join(" OR "),
            if resolved_only { " AND resolved = 1" } else { "" },
            score.join(" + "),
        );
        let mut args: Vec<String> = terms.clone();
        args.push(key.to_string());
        let mut stmt = conn.prepare(&sql).db()?;
        let rows = stmt.query_map(params_from_iter(args), |r| r.get::<_, String>(0)).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?;
        let boilerplate = Self::boilerplate(&conn)?;
        Ok(Some(rows.iter().filter_map(|data| serde_json::from_str::<IndexedIssue>(data).ok()).map(|i| hit(i, &[], Some(&boilerplate))).collect()))
    }

    // ---------- 查看记录 ----------

    /// 每个问题上次在本应用中查看的时间（毫秒），以及开始记录的时间（没有记录的问题以它为准）。
    pub fn viewed(&self, keys: &[String]) -> Result<(HashMap<String, i64>, i64)> {
        let conn = self.conn.lock().unwrap();
        let baseline = match Self::meta(&conn, "viewed_baseline")? {
            Some(v) => v.parse().unwrap_or_default(),
            None => {
                let now = now_ms();
                Self::set_meta(&conn, "viewed_baseline", &now.to_string())?;
                now
            }
        };
        let mut map = HashMap::new();
        let mut stmt = conn.prepare("SELECT at FROM viewed WHERE key = ?1").db()?;
        for key in keys {
            if let Some(at) = stmt.query_row(params![key], |r| r.get::<_, i64>(0)).optional().db()? {
                map.insert(key.clone(), at);
            }
        }
        Ok((map, baseline))
    }

    /// 记录查看时间，返回之前的查看时间。
    pub fn mark_viewed(&self, key: &str, at: i64) -> Result<Option<i64>> {
        let conn = self.conn.lock().unwrap();
        let previous = conn.query_row("SELECT at FROM viewed WHERE key = ?1", params![key], |r| r.get(0)).optional().db()?;
        conn.execute("INSERT OR REPLACE INTO viewed (key, at) VALUES (?1, MAX(?2, COALESCE(?3, 0)))", params![key, at, previous]).db()?;
        Ok(previous)
    }
}

/// 同步问题库，返回本次更新的问题数。`progress` 在每页之后调用。
pub async fn sync(client: &JiraClient, index: &IssueIndex, scope: &IndexScope, mut progress: impl FnMut(SyncProgress)) -> Result<usize> {
    index.ensure_base(client.base_url())?;
    let window = if scope.days > 0 { format!(" AND created >= -{}d", scope.days) } else { String::new() };
    let scopes: Vec<(String, String, String)> = if scope.jql.trim().is_empty() {
        client
            .involved_projects()
            .await?
            .into_iter()
            .map(|p| (format!("project:{p}"), p.clone(), format!("project = \"{}\"", jql_escape(&p))))
            .collect()
    } else {
        let jql = strip_order(scope.jql.trim());
        vec![(format!("jql:{jql}"), "自定义范围".into(), jql)]
    };
    let mut changed = 0;
    for (n, (id, label, base)) in scopes.iter().enumerate() {
        // 用相对时间（多少分钟前）表示增量起点，与 Jira 用户的时区设置无关；多回看几分钟，重复的直接覆盖
        let since = match index.cursor(id)?.as_deref().and_then(parse_time) {
            Some(t) => format!(" AND updated >= -{}m", (chrono::Utc::now() - t.to_utc()).num_minutes().max(0) + 5),
            None => String::new(),
        };
        let jql = format!("({base}){window}{since} ORDER BY updated ASC");
        let mut start = 0;
        loop {
            let (total, issues) = client.index_page(&jql, start, PAGE_SIZE).await?;
            if issues.is_empty() {
                break;
            }
            index.upsert(&issues)?;
            // 按更新时间升序获取，已处理部分的最晚时间就是下次的起点
            if let Some(latest) = issues.iter().map(|i| i.issue.updated.as_str()).max_by_key(|s| time_ms(s)) {
                index.set_cursor(id, latest)?;
            }
            start += issues.len() as u32;
            changed += issues.len();
            progress(SyncProgress { scope: label.clone(), done: start.min(total), total, finished: n, scopes: scopes.len() });
            if start >= total {
                break;
            }
            tokio::time::sleep(PAGE_PAUSE).await;
        }
    }
    index.finish_sync(changed)?;
    Ok(changed)
}

impl JiraClient {
    /// 我经办过或报告过问题的项目，按问题数从多到少。
    pub async fn involved_projects(&self) -> Result<Vec<String>> {
        let mut counts: HashMap<String, usize> = HashMap::new();
        let mut start = 0;
        loop {
            let raw = self
                .get_json(self.get("/rest/api/2/search").query(&[
                    ("jql", "assignee was currentUser() OR reporter = currentUser()"),
                    ("fields", "project"),
                    ("startAt", &start.to_string()),
                    ("maxResults", "1000"),
                ]))
                .await?;
            let issues = raw["issues"].as_array().cloned().unwrap_or_default();
            for issue in &issues {
                *counts.entry(value_text(&issue["fields"]["project"]["key"])).or_default() += 1;
            }
            start += issues.len();
            // 最多看最近的几千个，足以确定常用的项目
            if issues.is_empty() || start as u64 >= raw["total"].as_u64().unwrap_or(0) || start >= 5000 {
                break;
            }
        }
        let mut list: Vec<(String, usize)> = counts.into_iter().filter(|(k, _)| !k.is_empty()).collect();
        list.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        Ok(list.into_iter().map(|(k, _)| k).collect())
    }

    /// 同步问题库用的一页数据：（总数，问题）。
    pub async fn index_page(&self, jql: &str, start_at: u32, max_results: u32) -> Result<(u32, Vec<IndexedIssue>)> {
        let raw = self
            .get_json(self.get("/rest/api/2/search").query(&[
                ("jql", jql),
                ("fields", INDEX_FIELDS),
                ("startAt", &start_at.to_string()),
                ("maxResults", &max_results.to_string()),
            ]))
            .await?;
        let issues = raw["issues"].as_array().into_iter().flatten().map(IndexedIssue::from_raw).collect::<Result<Vec<_>>>()?;
        Ok((raw["total"].as_u64().unwrap_or(0) as u32, issues))
    }

    /// 在 Jira 中查找相似问题（问题库中没有该项目时使用），同样带回解决时间和最后几条评论。
    pub async fn similar_hits(&self, jql: &str, max_results: u32) -> Result<(u32, Vec<IssueHit>)> {
        let (total, issues) = self.index_page(jql, 0, max_results).await?;
        Ok((total, issues.into_iter().map(|i| hit(i, &[], Some(&HashSet::new()))).collect()))
    }
}

impl IndexedIssue {
    pub fn from_raw(item: &Value) -> Result<Self> {
        let fields = &item["fields"];
        let issue = IssueSummary::from_raw(serde_json::from_value::<RawIssue>(item.clone())?);
        let comments = fields["comment"]["comments"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|c| BriefComment {
                author: value_text(&c["author"]["displayName"]),
                author_name: value_text(&c["author"]["name"]),
                created: value_text(&c["created"]),
                body: wiki_plain(c["body"].as_str().unwrap_or_default()),
            })
            .collect();
        Ok(IndexedIssue {
            issue,
            resolved: fields["resolutiondate"].as_str().map(str::to_string),
            description: wiki_plain(fields["description"].as_str().unwrap_or_default()),
            comments,
        })
    }
}

/// `boilerplate` 不为空时带上最后几条评论（跳过固定话术）。
fn hit(item: IndexedIssue, terms: &[String], boilerplate: Option<&HashSet<String>>) -> IssueHit {
    let snippet = terms.iter().find_map(|t| excerpt(&item.description, t).map(|text| Snippet { source: "description".into(), author: None, text })).or_else(|| {
        terms.iter().find_map(|t| {
            item.comments
                .iter()
                .rev()
                .find_map(|c| excerpt(&c.body, t).map(|text| Snippet { source: "comment".into(), author: Some(c.author.clone()), text }))
        })
    });
    let last_comments = match boilerplate {
        Some(skip) => {
            let useful: Vec<&BriefComment> = item
                .comments
                .iter()
                // 只有图片的评论去掉标记后为空
                .filter(|c| !c.body.trim().is_empty() && !skip.contains(&c.body.chars().take(BOILERPLATE_CHARS).collect::<String>()))
                .collect();
            useful[useful.len().saturating_sub(LAST_COMMENTS)..]
                .iter()
                .map(|c| BriefComment { body: truncate(&c.body, COMMENT_CHARS), ..(*c).clone() })
                .collect()
        }
        None => Vec::new(),
    };
    IssueHit { comment_count: item.comments.len(), issue: item.issue, resolved: item.resolved, snippet, last_comments }
}

/// 问题键的前缀就是项目键。
fn project_of(key: &str) -> &str {
    key.rsplit_once('-').map_or(key, |(p, _)| p)
}

/// 比较用的文本：逐字转小写（保持字数不变，便于定位）。
fn fold(text: &str) -> String {
    text.chars().map(fold_char).collect()
}

fn fold_char(c: char) -> char {
    c.to_lowercase().next().unwrap_or(c)
}

/// 搜索框中的关键词：按空白拆分，最多 8 个。
fn query_terms(text: &str) -> Vec<String> {
    let mut terms: Vec<String> = Vec::new();
    for t in text.split_whitespace().map(fold) {
        if !terms.contains(&t) && terms.len() < 8 {
            terms.push(t);
        }
    }
    terms
}

/// `term`（已转小写）在 `text` 中第一次出现处附近的文字；没有出现时返回 `None`。
fn excerpt(text: &str, term: &str) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    let lower: Vec<char> = chars.iter().map(|c| fold_char(*c)).collect();
    let needle: Vec<char> = term.chars().collect();
    if needle.is_empty() || needle.len() > lower.len() {
        return None;
    }
    let at = lower.windows(needle.len()).position(|w| w == needle.as_slice())?;
    let from = at.saturating_sub(30);
    let to = (at + needle.len() + 90).min(chars.len());
    let text: String = chars[from..to].iter().collect();
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    Some(format!("{}{text}{}", if from > 0 { "…" } else { "" }, if to < chars.len() { "…" } else { "" }))
}

fn truncate(text: &str, max: usize) -> String {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() <= max { text } else { format!("{}…", text.chars().take(max).collect::<String>()) }
}

/// 去掉 JQL 末尾的排序（同步时统一按更新时间排序）。
fn strip_order(jql: &str) -> String {
    static ORDER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?is)\s+ORDER\s+BY\s+.*$").unwrap());
    let jql = ORDER.replace(jql, "").trim().to_string();
    // 只写了排序的 JQL 表示全部问题
    if jql.is_empty() { "created is not EMPTY".into() } else { jql }
}

/// 把 Jira wiki 标记粗略转为纯文本，用于搜索和摘要。
pub fn wiki_plain(markup: &str) -> String {
    static RULES: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
        [
            // 部分项目使用富文本渲染器，内容是 HTML
            (r"(?i)<br\s*/?>|</p>|</li>|</tr>", "\n"),
            // 链接的地址保留下来（按地址查找引用了某个分支、提交的问题）
            (r#"(?i)<a\s[^>\n]*?href="(https?://[^"]+)"[^>\n]*>"#, " $1 "),
            (r"<[^>\n]{1,500}>", " "),
            // {code:java}、{quote}、{color:red} 等宏只留内容
            (r"\{[a-zA-Z]+(?::[^}]*)?\}", " "),
            // 图片、附件 !a.png|thumbnail!
            (r"![^!\s][^!\n]*!", " "),
            (r"\[~([^\]]+)\]", "@$1"),
            (r"\[([^|\]]+)\|(https?://[^\]]+)\]", "$1 $2"),
            (r"\[([^|\]]+)\|[^\]]+\]", "$1"),
            (r"\[([^\]]+)\]", "$1"),
            (r"(?m)^\s*h[1-6]\.\s*", ""),
            (r"(?m)^\s*(?:[*#-]+|bq\.)\s+", ""),
            (r"\|\|?", " "),
            (r"(^|[\s(])[*_+](\S[^*_+\n]*?)[*_+]", "$1$2"),
            (r"[ \t\u{3000}]+", " "),
            (r"\s*\n[\s\n]*", "\n"),
        ]
        .into_iter()
        .map(|(p, r)| (Regex::new(p).unwrap(), r))
        .collect()
    });
    let mut text = markup.replace("\r\n", "\n");
    for (re, replacement) in RULES.iter() {
        text = re.replace_all(&text, *replacement).into_owned();
    }
    let text = text.replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&amp;", "&");
    text.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn issue(key: &str, summary: &str, description: &str, resolution: Option<&str>, comments: &[(&str, &str)]) -> IndexedIssue {
        let raw = serde_json::json!({
            "key": key,
            "fields": {
                "summary": summary,
                "description": description,
                "status": {"name": "处理中", "statusCategory": {"key": "indeterminate"}},
                "project": {"name": "测试项目"},
                "assignee": {"name": "zs", "displayName": "张三"},
                "resolution": resolution.map(|r| serde_json::json!({"name": r})),
                "updated": "2026-10-20T10:00:00.000+0800",
                "created": "2026-10-01T10:00:00.000+0800",
                "comment": {"comments": comments.iter().map(|(who, body)| serde_json::json!({
                    "author": {"name": who, "displayName": who.to_uppercase()}, "created": "2026-10-02T10:00:00.000+0800", "body": body
                })).collect::<Vec<_>>()}
            }
        });
        IndexedIssue::from_raw(&raw).unwrap()
    }

    fn sample() -> (tempfile::TempDir, IssueIndex) {
        let dir = tempfile::tempdir().unwrap();
        let index = IssueIndex::open(&dir.path().join("index.db")).unwrap();
        index
            .upsert(&[
                issue("AB-1", "导入期货文件报错", "导入 *TXT* 文件时提示格式错误", Some("已修复"), &[("ls", "原因是编码为 GBK，已改为自动识别")]),
                issue("AB-2", "订单报表字段调整", "报表增加订单状态", None, &[]),
                issue("AB-3", "期权行权单据类型", "期货期权执行单据", Some("已修复"), &[("me", "参考 AB-1 的处理")]),
                issue("CD-1", "Report export", "Export to Excel fails", None, &[]),
            ])
            .unwrap();
        (dir, index)
    }

    #[test]
    fn finds_issues_mentioning_a_link() {
        let dir = tempfile::tempdir().unwrap();
        let index = IssueIndex::open(&dir.path().join("index.db")).unwrap();
        index
            .upsert(&[
                issue("AB-1", "一", "", None, &[("ls", "代码已提交至 [分支|https://git.example.com/G/App/-/merge_requests/12]")]),
                issue("AB-2", "二", "见 https://git.example.com/g/app/-/merge_requests/123", None, &[]),
                issue("AB-3", "三", "无关", None, &[]),
            ])
            .unwrap();
        let needles = vec!["g/app/-/merge_requests/12".to_string()];
        let all = index.mentioning(&needles, |_| true, 10).unwrap();
        assert_eq!(all.len(), 2, "子串匹配到 12 和 123");
        let exact = index.mentioning(&needles, |t| t.to_lowercase().contains("merge_requests/12]") || t.ends_with("merge_requests/12"), 10).unwrap();
        assert_eq!(exact.iter().map(|h| h.issue.key.as_str()).collect::<Vec<_>>(), vec!["AB-1"]);
        assert_eq!(exact[0].snippet.as_ref().map(|s| s.source.as_str()), Some("comment"));
    }

    #[test]
    fn searches_summary_description_and_comments() {
        let (_dir, index) = sample();
        let q = |text: &str| IndexQuery { text: text.into(), ..Default::default() };
        let keys = |hits: Vec<IssueHit>| hits.into_iter().map(|h| h.issue.key).collect::<Vec<_>>();
        // 两个字的中文关键词，概要中出现的排在前面
        assert_eq!(keys(index.search(&q("期货"), "").unwrap()), vec!["AB-1", "AB-3"]);
        assert_eq!(keys(index.search(&q("编码"), "").unwrap()), vec!["AB-1"]);
        assert_eq!(keys(index.search(&q("EXCEL"), "").unwrap()), vec!["CD-1"]);
        assert_eq!(keys(index.search(&q("期货 编码"), "").unwrap()), vec!["AB-1"]);
        assert_eq!(keys(index.search(&q("ab-2"), "").unwrap()), vec!["AB-2"]);
        let hit = &index.search(&q("编码"), "").unwrap()[0];
        let snippet = hit.snippet.as_ref().unwrap();
        assert_eq!(snippet.source, "comment");
        assert_eq!(snippet.author.as_deref(), Some("LS"));
        // 筛选
        let resolved = IndexQuery { text: "期货".into(), state: "unresolved".into(), ..Default::default() };
        assert!(index.search(&resolved, "").unwrap().is_empty());
        let mine = IndexQuery { mine: true, ..Default::default() };
        assert_eq!(keys(index.search(&mine, "me").unwrap()), vec!["AB-3"]);
        let project = IndexQuery { project: "CD".into(), ..Default::default() };
        assert_eq!(keys(index.search(&project, "").unwrap()), vec!["CD-1"]);
    }

    #[test]
    fn finds_similar_with_comments() {
        let (_dir, index) = sample();
        let hits = index.similar("AB-9", "导入期货txt文件", true, 5).unwrap().unwrap();
        assert_eq!(hits[0].issue.key, "AB-1");
        assert_eq!(hits[0].last_comments[0].body, "原因是编码为 GBK，已改为自动识别");
        assert!(hits.iter().all(|h| h.issue.resolution.is_some()));
        assert!(index.similar("ZZ-1", "导入期货", true, 5).unwrap().is_none(), "没有该项目的数据时改用 Jira");
    }

    #[test]
    fn skips_boilerplate_comments() {
        let (_dir, index) = sample();
        let bot = "您好，此问题已解决但超过三个月未验证，系统自动关闭";
        let many: Vec<IndexedIssue> = (10..40).map(|n| issue(&format!("AB-{n}"), "其他问题", "", Some("已修复"), &[("bot", bot)])).collect();
        index.upsert(&many).unwrap();
        index.upsert(&[issue("AB-5", "导入期货文件格式", "", Some("已修复"), &[("ls", "改为自动识别编码"), ("bot", bot)])]).unwrap();
        index.finish_sync(1).unwrap();
        let hits = index.similar("AB-9", "导入期货文件格式", true, 3).unwrap().unwrap();
        let top = hits.iter().find(|h| h.issue.key == "AB-5").unwrap();
        assert_eq!(top.last_comments.iter().map(|c| c.body.as_str()).collect::<Vec<_>>(), vec!["改为自动识别编码"]);
    }

    #[test]
    fn records_views() {
        let (_dir, index) = sample();
        assert_eq!(index.mark_viewed("AB-1", 100).unwrap(), None);
        assert_eq!(index.mark_viewed("AB-1", 50).unwrap(), Some(100));
        let (map, baseline) = index.viewed(&["AB-1".into(), "AB-2".into()]).unwrap();
        assert_eq!(map.get("AB-1"), Some(&100), "查看时间不会倒退");
        assert!(!map.contains_key("AB-2"));
        assert!(baseline > 0);
    }

    #[test]
    fn strips_wiki_markup() {
        assert_eq!(wiki_plain("h2. 标题\n* *加粗* 文字 [~zs]\n{code:java}int a;{code}\n!img.png|thumbnail! [链接|http://x] [问题|PROJ-1]"), "标题\n加粗 文字 @zs\nint a;\n链接 http://x 问题");
        assert_eq!(wiki_plain(r#"<p>见 <a href="https://git.example.com/g/a/-/tree/dev" class="x">分支</a></p>"#), "见 https://git.example.com/g/a/-/tree/dev 分支");
        assert_eq!(wiki_plain("<p>补丁&nbsp;已上传</p><p>第二段<br>换行</p>"), "补丁 已上传\n第二段\n换行");
        assert_eq!(strip_order("project = A ORDER BY created DESC"), "project = A");
    }
}
