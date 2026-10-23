//! 工作空间的本地数据：待办、笔记、日记、知识库页面、图片。
//!
//! 数据存放在本机 SQLite 中，离线可用；多设备之间通过同步文件夹交换变更日志（见 [`sync`]）。
//! 每行数据带有 `updated_at` / `updated_by`，合并时以最后修改的为准；删除使用墓碑标记。

mod model;
mod refs;
pub use refs::plain_text;
pub mod sync;

use std::path::Path;
use std::sync::Mutex;

use nextworkzone_core::{Error, Result};
use rusqlite::{Connection, OptionalExtension, Row, params};

pub use model::*;

const SCHEMA_VERSION: i64 = 1;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS todos (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',
    done INTEGER NOT NULL DEFAULT 0,
    completed_at INTEGER,
    due TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    sort REAL NOT NULL DEFAULT 0,
    ref_system TEXT,
    ref_key TEXT,
    ref_title TEXT,
    source TEXT,
    auto_done INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    updated_by TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    dirty INTEGER NOT NULL DEFAULT 1,
    remind_at INTEGER,
    repeat TEXT,
    checklist TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS inbox (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    url TEXT,
    handled_at INTEGER,
    snooze_until INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    updated_by TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    dirty INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS docs (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    parent_id TEXT,
    sort REAL NOT NULL DEFAULT 0,
    tags TEXT NOT NULL DEFAULT '[]',
    day TEXT,
    pinned INTEGER NOT NULL DEFAULT 0,
    source_system TEXT,
    source_key TEXT,
    source_url TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    updated_by TEXT NOT NULL,
    base_at INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0,
    dirty INTEGER NOT NULL DEFAULT 1,
    published_url TEXT
);
CREATE INDEX IF NOT EXISTS docs_kind ON docs(kind, deleted);
CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    mime TEXT NOT NULL,
    data BLOB,
    created_at INTEGER NOT NULL,
    dirty INTEGER NOT NULL DEFAULT 1
);
-- 以下只保存在本机，不参与同步
-- 已经发出的提醒：条目 id → 提醒时间，提醒时间改了会再次提醒
CREATE TABLE IF NOT EXISTS fired_alerts (id TEXT PRIMARY KEY, at INTEGER NOT NULL);
-- 以下由内容派生，不参与同步
CREATE TABLE IF NOT EXISTS refs (
    item_type TEXT NOT NULL,
    item_id TEXT NOT NULL,
    system TEXT NOT NULL,
    key TEXT NOT NULL,
    PRIMARY KEY (item_type, item_id, system, key)
);
CREATE INDEX IF NOT EXISTS refs_target ON refs(system, key);
CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(item_type UNINDEXED, item_id UNINDEXED, title, body, tokenize = 'trigram');
CREATE TABLE IF NOT EXISTS sync_cursors (device TEXT PRIMARY KEY, offset INTEGER NOT NULL, generation TEXT NOT NULL DEFAULT '');
"#;

pub(crate) const TODO_COLUMNS: &str = "id, title, notes, done, completed_at, due, priority, sort, ref_system, ref_key, ref_title, source, auto_done, created_at, updated_at, updated_by, deleted, remind_at, repeat, checklist";
pub(crate) const INBOX_COLUMNS: &str = "id, kind, title, body, url, handled_at, snooze_until, created_at, updated_at, updated_by, deleted";
pub(crate) const DOC_COLUMNS: &str = "id, kind, title, content, parent_id, sort, tags, day, pinned, source_system, source_key, source_url, created_at, updated_at, updated_by, base_at, deleted, published_url";

pub struct Workspace {
    conn: Mutex<Connection>,
    device: String,
}

/// 把数据库错误转换为统一错误类型。
pub(crate) trait Db<T> {
    fn db(self) -> Result<T>;
}

impl<T> Db<T> for rusqlite::Result<T> {
    fn db(self) -> Result<T> {
        self.map_err(|e| Error::Other(format!("本地数据库错误：{e}")))
    }
}

pub(crate) fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

pub(crate) fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Jira 评论、流转模板（内容为 JSON，由前端解释）。
pub const TEMPLATE_KIND: &str = "jira-template";

/// 日记的 id 由日期决定，多台设备在同一天各自创建也会合并为同一篇。
pub fn daily_id(day: &str) -> String {
    format!("daily-{day}")
}

/// 由 Jira 问题自动创建的待办，id 由问题键决定。
pub fn jira_todo_id(key: &str) -> String {
    format!("jira-{key}")
}

/// 由 Wiki 页面任务自动创建的待办，id 由页面和任务决定。
pub fn wiki_todo_id(page_id: &str, task_id: &str) -> String {
    format!("wiki-{page_id}-{task_id}")
}

/// 自动同步为待办的外部条目。
struct SourceTodo {
    id: String,
    ref_system: String,
    ref_key: String,
    ref_title: String,
    title: String,
    due: Option<String>,
}

impl Workspace {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path).db()?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF;").db()?;
        conn.execute_batch(SCHEMA).db()?;
        migrate(&conn)?;
        conn.execute(
            "INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?1)",
            params![SCHEMA_VERSION.to_string()],
        )
        .db()?;
        let device = match conn
            .query_row("SELECT value FROM meta WHERE key = 'device_id'", [], |r| r.get::<_, String>(0))
            .optional()
            .db()?
        {
            Some(id) => id,
            None => {
                let id = new_id();
                conn.execute("INSERT INTO meta (key, value) VALUES ('device_id', ?1)", params![id]).db()?;
                id
            }
        };
        Ok(Self { conn: Mutex::new(conn), device })
    }

    pub fn device_id(&self) -> &str {
        &self.device
    }

    pub fn get_meta(&self, key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| r.get(0)).optional().db()
    }

    pub fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)", params![key, value]).db()?;
        Ok(())
    }

    /// 新的修改时间：至少比该行原来的修改时间晚 1 毫秒，保证合并时本次修改胜出。
    fn stamp(previous: Option<i64>) -> i64 {
        let now = now_ms();
        previous.map_or(now, |p| now.max(p + 1))
    }

    // ---------- 待办 ----------

    pub fn todos(&self) -> Result<Vec<Todo>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!("SELECT {TODO_COLUMNS} FROM todos WHERE deleted = 0 ORDER BY done, sort, created_at"))
            .db()?;
        stmt.query_map([], todo_from_row).db()?.collect::<rusqlite::Result<Vec<_>>>().db()
    }

    pub fn todo(&self, id: &str) -> Result<Option<Todo>> {
        let conn = self.conn.lock().unwrap();
        load_todo(&conn, id)
    }

    /// 新建（`id` 为空）或修改待办，返回保存后的待办。
    pub fn save_todo(&self, input: TodoInput) -> Result<Todo> {
        let conn = self.conn.lock().unwrap();
        let existing = match &input.id {
            Some(id) => load_todo(&conn, id)?,
            None => None,
        };
        let updated_at = Self::stamp(existing.as_ref().map(|t| t.updated_at));
        let was_done = existing.as_ref().is_some_and(|t| t.done);
        let todo = match existing {
            Some(old) => Todo {
                completed_at: match (old.done, input.done) {
                    (false, true) => Some(updated_at),
                    (_, false) => None,
                    _ => old.completed_at,
                },
                // 手动改变完成状态后不再视为自动完成
                auto_done: old.auto_done && old.done == input.done,
                title: input.title,
                notes: input.notes,
                done: input.done,
                due: input.due.filter(|d| !d.is_empty()),
                priority: input.priority,
                ref_system: input.ref_system,
                ref_key: input.ref_key,
                ref_title: input.ref_title,
                remind_at: input.remind_at,
                repeat: input.repeat.filter(|r| !r.is_empty()),
                checklist: input.checklist,
                updated_at,
                updated_by: self.device.clone(),
                ..old
            },
            None => {
                let sort = conn
                    .query_row("SELECT COALESCE(MIN(sort), 0) - 1 FROM todos WHERE deleted = 0", [], |r| r.get(0))
                    .db()?;
                Todo {
                    id: input.id.unwrap_or_else(new_id),
                    title: input.title,
                    notes: input.notes,
                    done: input.done,
                    completed_at: input.done.then_some(updated_at),
                    due: input.due.filter(|d| !d.is_empty()),
                    priority: input.priority,
                    sort,
                    ref_system: input.ref_system,
                    ref_key: input.ref_key,
                    ref_title: input.ref_title,
                    source: None,
                    auto_done: false,
                    created_at: updated_at,
                    updated_at,
                    updated_by: self.device.clone(),
                    deleted: false,
                    remind_at: input.remind_at,
                    repeat: input.repeat.filter(|r| !r.is_empty()),
                    checklist: input.checklist,
                }
            }
        };
        self.finish(&conn, todo, was_done)
    }

    /// 写入待办；重复的待办从未完成变为完成时生成下一次，本条不再重复（再次取消、勾选不会重复生成）。
    fn finish(&self, conn: &Connection, mut todo: Todo, was_done: bool) -> Result<Todo> {
        let next = match (&todo.repeat, todo.done && !was_done && !todo.deleted) {
            (Some(repeat), true) => next_occurrence(todo.due.as_deref(), repeat, chrono::Local::now().date_naive()),
            _ => None,
        };
        if let Some(next_due) = next {
            let now = Self::stamp(Some(todo.updated_at));
            // 提醒时间随日期顺延，保持一天中的时刻
            let shift = todo.due.as_deref().and_then(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").ok()).map_or(0, |d| (next_due - d).num_days());
            let following = Todo {
                id: new_id(),
                done: false,
                completed_at: None,
                auto_done: false,
                due: Some(next_due.format("%Y-%m-%d").to_string()),
                remind_at: todo.remind_at.map(|at| at + shift * 86_400_000),
                checklist: todo.checklist.iter().map(|c| ChecklistItem { done: false, ..c.clone() }).collect(),
                source: None,
                created_at: now,
                updated_at: now,
                updated_by: self.device.clone(),
                ..todo.clone()
            };
            write_todo(conn, &following, true)?;
            todo.repeat = None;
        }
        write_todo(conn, &todo, true)?;
        Ok(todo)
    }

    pub fn set_todo_done(&self, id: &str, done: bool) -> Result<Todo> {
        let conn = self.conn.lock().unwrap();
        let old = load_todo(&conn, id)?.ok_or_else(|| Error::Other("待办不存在".into()))?;
        let updated_at = Self::stamp(Some(old.updated_at));
        let was_done = old.done;
        let todo = Todo {
            done,
            completed_at: done.then_some(updated_at),
            auto_done: false,
            updated_at,
            updated_by: self.device.clone(),
            ..old
        };
        self.finish(&conn, todo, was_done)
    }

    pub fn move_todo(&self, id: &str, sort: f64) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let old = load_todo(&conn, id)?.ok_or_else(|| Error::Other("待办不存在".into()))?;
        let todo = Todo { sort, updated_at: Self::stamp(Some(old.updated_at)), updated_by: self.device.clone(), ..old };
        write_todo(&conn, &todo, true)
    }

    pub fn delete_todo(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        if let Some(old) = load_todo(&conn, id)? {
            let todo = Todo { deleted: true, updated_at: Self::stamp(Some(old.updated_at)), updated_by: self.device.clone(), ..old };
            write_todo(&conn, &todo, true)?;
        }
        Ok(())
    }

    /// 让“分配给我的未解决问题”与自动创建的待办保持一致：
    /// 新问题加入待办；不在列表中的（已解决或已转给他人）自动完成；重新分配回来的自动完成待办恢复。
    /// 用户手动删除过的问题不会再被加回来。
    pub fn sync_jira_todos(&self, issues: &[AssignedIssue]) -> Result<JiraTodoSync> {
        let items = issues
            .iter()
            .map(|i| SourceTodo {
                id: jira_todo_id(&i.key),
                ref_system: "jira".into(),
                ref_key: i.key.clone(),
                ref_title: i.summary.clone(),
                title: i.summary.clone(),
                due: i.due.clone(),
            })
            .collect::<Vec<_>>();
        self.sync_source_todos("jira", &items)
    }

    /// 让“页面中分配给我的未完成任务”与自动创建的待办保持一致，规则同 [`Self::sync_jira_todos`]。
    pub fn sync_wiki_todos(&self, tasks: &[AssignedWikiTask]) -> Result<JiraTodoSync> {
        let items = tasks
            .iter()
            .map(|t| SourceTodo {
                id: wiki_todo_id(&t.page_id, &t.task_id),
                ref_system: "wiki".into(),
                ref_key: t.page_id.clone(),
                ref_title: t.page_title.clone(),
                title: if t.text.trim().is_empty() { t.page_title.clone() } else { t.text.clone() },
                due: t.due.clone(),
            })
            .collect::<Vec<_>>();
        self.sync_source_todos("wiki", &items)
    }

    fn sync_source_todos(&self, source: &str, items: &[SourceTodo]) -> Result<JiraTodoSync> {
        let conn = self.conn.lock().unwrap();
        let mut report = JiraTodoSync::default();
        let tx = conn.unchecked_transaction().db()?;
        for item in items {
            match load_todo(&tx, &item.id)? {
                None => {
                    let now = now_ms();
                    let sort: f64 = tx
                        .query_row("SELECT COALESCE(MIN(sort), 0) - 1 FROM todos WHERE deleted = 0", [], |r| r.get(0))
                        .db()?;
                    write_todo(
                        &tx,
                        &Todo {
                            id: item.id.clone(),
                            title: item.title.clone(),
                            notes: String::new(),
                            done: false,
                            completed_at: None,
                            due: item.due.clone(),
                            priority: 0,
                            sort,
                            ref_system: Some(item.ref_system.clone()),
                            ref_key: Some(item.ref_key.clone()),
                            ref_title: Some(item.ref_title.clone()),
                            source: Some(source.into()),
                            auto_done: false,
                            created_at: now,
                            updated_at: now,
                            updated_by: self.device.clone(),
                            deleted: false,
                            remind_at: None,
                            repeat: None,
                            checklist: Vec::new(),
                        },
                        true,
                    )?;
                    report.added += 1;
                }
                Some(old) if old.deleted => {}
                Some(old) => {
                    let reopen = old.done && old.auto_done;
                    // Jira 待办在用户没改过标题时跟随问题概要（标题与引用标题相同）
                    let follow_title = source == "jira" && old.ref_title.as_deref() == Some(old.title.as_str());
                    let title = if follow_title { item.title.clone() } else { old.title.clone() };
                    let changed = reopen || title != old.title || old.ref_title.as_deref() != Some(item.ref_title.as_str());
                    if changed {
                        let todo = Todo {
                            title,
                            ref_title: Some(item.ref_title.clone()),
                            done: if reopen { false } else { old.done },
                            completed_at: if reopen { None } else { old.completed_at },
                            auto_done: if reopen { false } else { old.auto_done },
                            updated_at: Self::stamp(Some(old.updated_at)),
                            updated_by: self.device.clone(),
                            ..old
                        };
                        write_todo(&tx, &todo, true)?;
                        if reopen {
                            report.reopened += 1;
                        }
                    }
                }
            }
        }
        let current: std::collections::HashSet<&str> = items.iter().map(|i| i.id.as_str()).collect();
        let open: Vec<Todo> = {
            let mut stmt = tx
                .prepare(&format!("SELECT {TODO_COLUMNS} FROM todos WHERE source = ?1 AND done = 0 AND deleted = 0"))
                .db()?;
            stmt.query_map(params![source], todo_from_row).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?
        };
        for old in open.into_iter().filter(|t| !current.contains(t.id.as_str())) {
            let updated_at = Self::stamp(Some(old.updated_at));
            let todo = Todo {
                done: true,
                completed_at: Some(updated_at),
                auto_done: true,
                updated_at,
                updated_by: self.device.clone(),
                ..old
            };
            write_todo(&tx, &todo, true)?;
            report.completed += 1;
        }
        tx.commit().db()?;
        Ok(report)
    }

    // ---------- 收件箱（需要处理的事的状态） ----------

    /// 收件箱的全部记录（外部条目的处理状态，以及旧版本记下的内容）。
    pub fn inbox(&self) -> Result<Vec<InboxEntry>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!("SELECT {INBOX_COLUMNS} FROM inbox WHERE deleted = 0 ORDER BY created_at DESC")).db()?;
        stmt.query_map([], inbox_from_row).db()?.collect::<rusqlite::Result<Vec<_>>>().db()
    }

    /// 记下一条待处理的内容。新版本不再创建，记下的内容直接成为待办；保留用于测试旧数据。
    pub fn capture(&self, title: &str, body: &str, url: Option<&str>) -> Result<InboxEntry> {
        let conn = self.conn.lock().unwrap();
        let now = now_ms();
        let entry = InboxEntry {
            id: new_id(),
            kind: "capture".into(),
            title: title.trim().to_string(),
            body: body.trim().to_string(),
            url: url.map(str::to_string).filter(|u| !u.is_empty()),
            handled_at: None,
            snooze_until: None,
            created_at: now,
            updated_at: now,
            updated_by: self.device.clone(),
            deleted: false,
        };
        write_inbox(&conn, &entry, true)?;
        Ok(entry)
    }

    /// 把还没处理的记下的内容转为未安排日期的待办（收件箱页面取消后，旧数据和其他设备同步来的都在这里转换）。
    /// 返回转换的条数。
    pub fn captures_to_todos(&self) -> Result<usize> {
        let pending: Vec<InboxEntry> = self.inbox()?.into_iter().filter(|e| e.kind == "capture" && e.handled_at.is_none()).collect();
        for e in &pending {
            // 链接已经写在正文里时不重复
            let notes = match &e.url {
                Some(url) if !e.body.contains(url.as_str()) => [e.body.as_str(), url.as_str()].iter().filter(|s| !s.is_empty()).copied().collect::<Vec<_>>().join("\n"),
                _ => e.body.clone(),
            };
            self.save_todo(TodoInput { title: e.title.clone(), notes, ..Default::default() })?;
            self.delete_inbox(&e.id)?;
        }
        Ok(pending.len())
    }

    /// 设置条目的处理状态；外部条目第一次处理时创建状态记录。`title` 只用于状态记录的说明。
    pub fn set_inbox_state(&self, id: &str, title: &str, handled_at: Option<i64>, snooze_until: Option<i64>) -> Result<InboxEntry> {
        let conn = self.conn.lock().unwrap();
        let existing = load_inbox(&conn, id)?;
        let updated_at = Self::stamp(existing.as_ref().map(|e| e.updated_at));
        let entry = match existing {
            Some(old) => InboxEntry { handled_at, snooze_until, deleted: false, updated_at, updated_by: self.device.clone(), ..old },
            None => InboxEntry {
                id: id.to_string(),
                kind: "state".into(),
                title: title.to_string(),
                body: String::new(),
                url: None,
                handled_at,
                snooze_until,
                created_at: updated_at,
                updated_at,
                updated_by: self.device.clone(),
                deleted: false,
            },
        };
        write_inbox(&conn, &entry, true)?;
        Ok(entry)
    }

    pub fn delete_inbox(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        if let Some(old) = load_inbox(&conn, id)? {
            let entry = InboxEntry { deleted: true, updated_at: Self::stamp(Some(old.updated_at)), updated_by: self.device.clone(), ..old };
            write_inbox(&conn, &entry, true)?;
        }
        Ok(())
    }

    // ---------- 提醒 ----------

    /// 到时间的提醒：待办的提醒时间、收件箱的“稍后提醒”。返回后即记为已提醒。
    /// 过期太久（例如电脑休眠了一整夜）的只记为已提醒，不再通知。
    pub fn take_due_alerts(&self, now: i64) -> Result<Vec<DueAlert>> {
        const STALE_MS: i64 = 12 * 3600 * 1000;
        let conn = self.conn.lock().unwrap();
        let mut candidates: Vec<(String, i64, DueAlert)> = Vec::new();
        {
            let mut stmt = conn
                .prepare("SELECT id, title, remind_at FROM todos WHERE remind_at IS NOT NULL AND remind_at <= ?1 AND done = 0 AND deleted = 0")
                .db()?;
            let rows = stmt.query_map(params![now], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))).db()?;
            for row in rows {
                let (id, title, at) = row.db()?;
                candidates.push((format!("todo:{id}"), at, DueAlert { item_type: "todo".into(), id, title }));
            }
        }
        {
            let mut stmt = conn
                .prepare("SELECT id, title, snooze_until FROM inbox WHERE snooze_until IS NOT NULL AND snooze_until <= ?1 AND handled_at IS NULL AND deleted = 0")
                .db()?;
            let rows = stmt.query_map(params![now], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))).db()?;
            for row in rows {
                let (id, title, at) = row.db()?;
                candidates.push((format!("inbox:{id}"), at, DueAlert { item_type: "inbox".into(), id, title }));
            }
        }
        let mut alerts = Vec::new();
        for (key, at, alert) in candidates {
            let fired: Option<i64> = conn.query_row("SELECT at FROM fired_alerts WHERE id = ?1", params![key], |r| r.get(0)).optional().db()?;
            if fired == Some(at) {
                continue;
            }
            conn.execute("INSERT OR REPLACE INTO fired_alerts (id, at) VALUES (?1, ?2)", params![key, at]).db()?;
            if now - at <= STALE_MS {
                alerts.push(alert);
            }
        }
        Ok(alerts)
    }

    // ---------- 文档 ----------

    pub fn docs(&self, kind: &str) -> Result<Vec<DocSummary>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {DOC_COLUMNS} FROM docs WHERE kind = ?1 AND deleted = 0 ORDER BY pinned DESC, sort, updated_at DESC"
            ))
            .db()?;
        let docs = stmt.query_map(params![kind], doc_from_row).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?;
        Ok(docs.iter().map(summary).collect())
    }

    /// 某类文档的完整内容（模板等数量很少的文档）。
    pub fn full_docs(&self, kind: &str) -> Result<Vec<Doc>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(&format!("SELECT {DOC_COLUMNS} FROM docs WHERE kind = ?1 AND deleted = 0 ORDER BY sort, created_at"))
            .db()?;
        stmt.query_map(params![kind], doc_from_row).db()?.collect::<rusqlite::Result<Vec<_>>>().db()
    }

    pub fn doc(&self, id: &str) -> Result<Option<Doc>> {
        let conn = self.conn.lock().unwrap();
        load_doc(&conn, id)
    }

    /// 某天的日记；不存在时返回一篇尚未保存的空日记（输入内容后再保存）。
    pub fn daily(&self, day: &str) -> Result<Doc> {
        let conn = self.conn.lock().unwrap();
        let id = daily_id(day);
        Ok(match load_doc(&conn, &id)? {
            Some(doc) if !doc.deleted => doc,
            _ => Doc {
                id,
                kind: "daily".into(),
                title: day.to_string(),
                content: String::new(),
                parent_id: None,
                sort: 0.0,
                tags: Vec::new(),
                day: Some(day.to_string()),
                pinned: false,
                source_system: None,
                source_key: None,
                source_url: None,
                created_at: 0,
                updated_at: 0,
                updated_by: String::new(),
                base_at: 0,
                deleted: false,
                published_url: None,
            },
        })
    }

    /// 写过日记的日期（倒序）。
    pub fn daily_days(&self) -> Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT day FROM docs WHERE kind = 'daily' AND deleted = 0 AND content != '' ORDER BY day DESC")
            .db()?;
        stmt.query_map([], |r| r.get(0)).db()?.collect::<rusqlite::Result<Vec<_>>>().db()
    }

    pub fn save_doc(&self, input: DocInput) -> Result<Doc> {
        let conn = self.conn.lock().unwrap();
        let existing = match &input.id {
            Some(id) => load_doc(&conn, id)?,
            None => None,
        };
        let updated_at = Self::stamp(existing.as_ref().map(|d| d.updated_at));
        let doc = match existing {
            Some(old) => Doc {
                title: input.title,
                content: input.content,
                parent_id: input.parent_id,
                tags: clean_tags(input.tags),
                pinned: input.pinned,
                source_system: input.source_system.or(old.source_system.clone()),
                source_key: input.source_key.or(old.source_key.clone()),
                source_url: input.source_url.or(old.source_url.clone()),
                published_url: input.published_url.or(old.published_url.clone()),
                deleted: false,
                updated_at,
                updated_by: self.device.clone(),
                base_at: old.updated_at,
                ..old
            },
            None => {
                let kind = if input.kind.is_empty() { "note".to_string() } else { input.kind };
                let day = input.id.as_deref().and_then(|id| id.strip_prefix("daily-")).map(str::to_string);
                let sort: f64 = conn
                    .query_row(
                        "SELECT COALESCE(MAX(sort), 0) + 1 FROM docs WHERE kind = ?1 AND parent_id IS ?2 AND deleted = 0",
                        params![kind, input.parent_id],
                        |r| r.get(0),
                    )
                    .db()?;
                Doc {
                    id: input.id.unwrap_or_else(new_id),
                    kind,
                    title: input.title,
                    content: input.content,
                    parent_id: input.parent_id,
                    sort,
                    tags: clean_tags(input.tags),
                    day,
                    pinned: input.pinned,
                    source_system: input.source_system,
                    source_key: input.source_key,
                    source_url: input.source_url,
                    created_at: updated_at,
                    updated_at,
                    updated_by: self.device.clone(),
                    base_at: 0,
                    deleted: false,
                    published_url: input.published_url,
                }
            }
        };
        write_doc(&conn, &doc, true)?;
        Ok(doc)
    }

    /// 记下文档发布到的 Wiki 页面（地址中带有页面 id 和发布时的版本），正文不变。
    pub fn set_published(&self, id: &str, url: &str) -> Result<Doc> {
        self.update_doc(id, |d| d.published_url = Some(url.to_string()))
    }

    /// 更新剪藏来源地址（重新剪藏后记下新的版本）。
    pub fn set_source_url(&self, id: &str, url: &str) -> Result<Doc> {
        self.update_doc(id, |d| d.source_url = Some(url.to_string()))
    }

    fn update_doc(&self, id: &str, change: impl FnOnce(&mut Doc)) -> Result<Doc> {
        let conn = self.conn.lock().unwrap();
        let old = load_doc(&conn, id)?.ok_or_else(|| Error::Other("文档不存在".into()))?;
        let mut doc = Doc {
            updated_at: Self::stamp(Some(old.updated_at)),
            updated_by: self.device.clone(),
            base_at: old.updated_at,
            ..old
        };
        change(&mut doc);
        write_doc(&conn, &doc, true)?;
        Ok(doc)
    }

    /// 移动知识库页面到新的上级页面和位置。不能移到自己的下级。
    pub fn move_doc(&self, id: &str, parent_id: Option<&str>, sort: f64) -> Result<Doc> {
        let conn = self.conn.lock().unwrap();
        let mut cursor = parent_id.map(str::to_string);
        while let Some(current) = cursor {
            if current == id {
                return Err(Error::Other("不能移动到自己的下级页面".into()));
            }
            cursor = load_doc(&conn, &current)?.and_then(|d| d.parent_id);
        }
        let old = load_doc(&conn, id)?.ok_or_else(|| Error::Other("文档不存在".into()))?;
        let doc = Doc {
            parent_id: parent_id.map(str::to_string),
            sort,
            updated_at: Self::stamp(Some(old.updated_at)),
            updated_by: self.device.clone(),
            base_at: old.updated_at,
            ..old
        };
        write_doc(&conn, &doc, true)?;
        Ok(doc)
    }

    /// 删除文档；知识库页面连同其下级页面一起删除。
    pub fn delete_doc(&self, id: &str) -> Result<usize> {
        let conn = self.conn.lock().unwrap();
        let mut queue = vec![id.to_string()];
        let mut count = 0;
        while let Some(current) = queue.pop() {
            let mut stmt = conn.prepare("SELECT id FROM docs WHERE parent_id = ?1 AND deleted = 0").db()?;
            let children = stmt.query_map(params![current], |r| r.get::<_, String>(0)).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?;
            queue.extend(children);
            if let Some(old) = load_doc(&conn, &current)?.filter(|d| !d.deleted) {
                let doc = Doc {
                    deleted: true,
                    updated_at: Self::stamp(Some(old.updated_at)),
                    updated_by: self.device.clone(),
                    base_at: old.updated_at,
                    ..old
                };
                write_doc(&conn, &doc, true)?;
                count += 1;
            }
        }
        Ok(count)
    }

    /// 所有文档用过的标签及使用次数。
    pub fn tags(&self) -> Result<Vec<(String, usize)>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT tags FROM docs WHERE deleted = 0 AND tags != '[]'").db()?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?;
        let mut counts: std::collections::BTreeMap<String, usize> = Default::default();
        for row in rows {
            for tag in serde_json::from_str::<Vec<String>>(&row).unwrap_or_default() {
                *counts.entry(tag).or_default() += 1;
            }
        }
        let mut list: Vec<_> = counts.into_iter().collect();
        list.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        Ok(list)
    }

    // ---------- 引用与搜索 ----------

    /// 引用了某个条目的待办和文档，例如 (`jira`, `ABC-123`) 或 (`doc`, 文档 id)。
    pub fn backlinks(&self, system: &str, key: &str) -> Result<Vec<Backlink>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT r.item_type, r.item_id,
                        COALESCE(d.kind, 'todo'), COALESCE(d.title, t.title, ''), COALESCE(t.done, 0),
                        COALESCE(d.updated_at, t.updated_at, 0)
                   FROM refs r
                   LEFT JOIN docs d ON r.item_type = 'doc' AND d.id = r.item_id AND d.deleted = 0
                   LEFT JOIN todos t ON r.item_type = 'todo' AND t.id = r.item_id AND t.deleted = 0
                  WHERE r.system = ?1 AND r.key = ?2 AND (d.id IS NOT NULL OR t.id IS NOT NULL)
                  ORDER BY 6 DESC",
            )
            .db()?;
        stmt.query_map(params![system, key], |r| {
            Ok(Backlink {
                item_type: r.get(0)?,
                id: r.get(1)?,
                kind: r.get(2)?,
                title: r.get(3)?,
                done: r.get(4)?,
                updated_at: r.get(5)?,
            })
        })
        .db()?
        .collect::<rusqlite::Result<Vec<_>>>()
        .db()
    }

    /// 全文搜索待办和文档。三个字及以上使用全文索引，更短的查询逐条匹配。
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self.conn.lock().unwrap();
        let (sql, pattern) = if query.chars().count() >= 3 {
            (
                "SELECT item_type, item_id, title, body FROM search WHERE search MATCH ?1 ORDER BY rank LIMIT ?2",
                format!("\"{}\"", query.replace('"', "\"\"")),
            )
        } else {
            (
                "SELECT item_type, item_id, title, body FROM search WHERE title LIKE ?1 OR body LIKE ?1 LIMIT ?2",
                format!("%{}%", query.replace('%', "\\%").replace('_', "\\_")),
            )
        };
        let mut stmt = conn.prepare(sql).db()?;
        let rows = stmt
            .query_map(params![pattern, limit as i64], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?))
            })
            .db()?
            .collect::<rusqlite::Result<Vec<_>>>()
            .db()?;
        let mut hits = Vec::new();
        for (item_type, id, title, body) in rows {
            let (kind, done) = if item_type == "todo" {
                ("todo".to_string(), load_todo(&conn, &id)?.is_some_and(|t| t.done))
            } else {
                (load_doc(&conn, &id)?.map(|d| d.kind).unwrap_or_default(), false)
            };
            hits.push(SearchHit { item_type, id, kind, title, snippet: snippet(&body, query), done });
        }
        Ok(hits)
    }

    // ---------- 图片 ----------

    pub fn save_asset(&self, mime: &str, data: &[u8]) -> Result<AssetMeta> {
        let conn = self.conn.lock().unwrap();
        let meta = AssetMeta { id: new_id(), mime: mime.to_string(), created_at: now_ms() };
        conn.execute(
            "INSERT INTO assets (id, mime, data, created_at, dirty) VALUES (?1, ?2, ?3, ?4, 1)",
            params![meta.id, meta.mime, data, meta.created_at],
        )
        .db()?;
        Ok(meta)
    }

    /// 图片内容；其他设备的图片尚未同步到时返回 `None`。
    pub fn asset(&self, id: &str) -> Result<Option<(String, Vec<u8>)>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT mime, data FROM assets WHERE id = ?1 AND data IS NOT NULL", params![id], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .optional()
        .db()
    }
}

/// 重复待办的下一次日期：从截止日期（没有时从今天）起按规则推进，跳过已经过去的日期。
pub fn next_occurrence(due: Option<&str>, repeat: &str, today: chrono::NaiveDate) -> Option<chrono::NaiveDate> {
    use chrono::{Datelike, Duration, Months, Weekday};
    let step = |d: chrono::NaiveDate| -> Option<chrono::NaiveDate> {
        match repeat {
            "daily" => Some(d + Duration::days(1)),
            "weekdays" => {
                let mut n = d + Duration::days(1);
                while matches!(n.weekday(), Weekday::Sat | Weekday::Sun) {
                    n += Duration::days(1);
                }
                Some(n)
            }
            "weekly" => Some(d + Duration::days(7)),
            "monthly" => d.checked_add_months(Months::new(1)),
            _ => None,
        }
    };
    let start = due.and_then(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").ok()).unwrap_or(today);
    let mut next = step(start)?;
    while next <= today {
        next = step(next)?;
    }
    Some(next)
}

/// 给早期版本创建的数据库补上后来新增的列。
fn migrate(conn: &Connection) -> Result<()> {
    let added: &[(&str, &str, &str)] = &[("sync_cursors", "generation", "TEXT NOT NULL DEFAULT ''"), ("docs", "base_at", "INTEGER NOT NULL DEFAULT 0"), ("docs", "published_url", "TEXT"), ("todos", "remind_at", "INTEGER"), ("todos", "repeat", "TEXT"), ("todos", "checklist", "TEXT NOT NULL DEFAULT '[]'")];
    for (table, column, definition) in added {
        let exists: bool = conn
            .query_row(&format!("SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name = ?1"), params![column], |r| r.get(0))
            .db()?;
        if !exists {
            conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {definition}")).db()?;
        }
    }
    Ok(())
}

// ---------- 行读写 ----------

pub(crate) fn todo_from_row(r: &Row) -> rusqlite::Result<Todo> {
    Ok(Todo {
        id: r.get(0)?,
        title: r.get(1)?,
        notes: r.get(2)?,
        done: r.get(3)?,
        completed_at: r.get(4)?,
        due: r.get(5)?,
        priority: r.get(6)?,
        sort: r.get(7)?,
        ref_system: r.get(8)?,
        ref_key: r.get(9)?,
        ref_title: r.get(10)?,
        source: r.get(11)?,
        auto_done: r.get(12)?,
        created_at: r.get(13)?,
        updated_at: r.get(14)?,
        updated_by: r.get(15)?,
        deleted: r.get(16)?,
        remind_at: r.get(17)?,
        repeat: r.get(18)?,
        checklist: serde_json::from_str(&r.get::<_, String>(19)?).unwrap_or_default(),
    })
}

pub(crate) fn inbox_from_row(r: &Row) -> rusqlite::Result<InboxEntry> {
    Ok(InboxEntry {
        id: r.get(0)?,
        kind: r.get(1)?,
        title: r.get(2)?,
        body: r.get(3)?,
        url: r.get(4)?,
        handled_at: r.get(5)?,
        snooze_until: r.get(6)?,
        created_at: r.get(7)?,
        updated_at: r.get(8)?,
        updated_by: r.get(9)?,
        deleted: r.get(10)?,
    })
}

pub(crate) fn load_inbox(conn: &Connection, id: &str) -> Result<Option<InboxEntry>> {
    conn.query_row(&format!("SELECT {INBOX_COLUMNS} FROM inbox WHERE id = ?1"), params![id], inbox_from_row)
        .optional()
        .db()
}

pub(crate) fn write_inbox(conn: &Connection, e: &InboxEntry, dirty: bool) -> Result<()> {
    conn.execute(
        &format!("INSERT OR REPLACE INTO inbox ({INBOX_COLUMNS}, dirty) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)"),
        params![e.id, e.kind, e.title, e.body, e.url, e.handled_at, e.snooze_until, e.created_at, e.updated_at, e.updated_by, e.deleted, dirty],
    )
    .db()?;
    Ok(())
}

pub(crate) fn doc_from_row(r: &Row) -> rusqlite::Result<Doc> {
    let tags: String = r.get(6)?;
    Ok(Doc {
        id: r.get(0)?,
        kind: r.get(1)?,
        title: r.get(2)?,
        content: r.get(3)?,
        parent_id: r.get(4)?,
        sort: r.get(5)?,
        tags: serde_json::from_str(&tags).unwrap_or_default(),
        day: r.get(7)?,
        pinned: r.get(8)?,
        source_system: r.get(9)?,
        source_key: r.get(10)?,
        source_url: r.get(11)?,
        created_at: r.get(12)?,
        updated_at: r.get(13)?,
        updated_by: r.get(14)?,
        base_at: r.get(15)?,
        deleted: r.get(16)?,
        published_url: r.get(17)?,
    })
}

pub(crate) fn load_todo(conn: &Connection, id: &str) -> Result<Option<Todo>> {
    conn.query_row(&format!("SELECT {TODO_COLUMNS} FROM todos WHERE id = ?1"), params![id], todo_from_row)
        .optional()
        .db()
}

pub(crate) fn load_doc(conn: &Connection, id: &str) -> Result<Option<Doc>> {
    conn.query_row(&format!("SELECT {DOC_COLUMNS} FROM docs WHERE id = ?1"), params![id], doc_from_row)
        .optional()
        .db()
}

/// 写入整行并更新派生的引用和搜索索引。`dirty` 表示尚未导出到同步文件夹。
pub(crate) fn write_todo(conn: &Connection, t: &Todo, dirty: bool) -> Result<()> {
    conn.execute(
        &format!(
            "INSERT OR REPLACE INTO todos ({TODO_COLUMNS}, dirty) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)"
        ),
        params![
            t.id, t.title, t.notes, t.done, t.completed_at, t.due, t.priority, t.sort, t.ref_system, t.ref_key,
            t.ref_title, t.source, t.auto_done, t.created_at, t.updated_at, t.updated_by, t.deleted, t.remind_at,
            t.repeat, serde_json::to_string(&t.checklist).unwrap_or_else(|_| "[]".into()), dirty
        ],
    )
    .db()?;
    let mut keys = refs::extract(&format!("{}\n{}", t.title, t.notes));
    if let (Some(system), Some(key)) = (&t.ref_system, &t.ref_key) {
        keys.push((system.clone(), key.clone()));
    }
    let body = std::iter::once(t.notes.as_str()).chain(t.checklist.iter().map(|c| c.text.as_str())).collect::<Vec<_>>().join("\n");
    index(conn, "todo", &t.id, t.deleted, &t.title, &body, keys)
}

pub(crate) fn write_doc(conn: &Connection, d: &Doc, dirty: bool) -> Result<()> {
    conn.execute(
        &format!(
            "INSERT OR REPLACE INTO docs ({DOC_COLUMNS}, dirty) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)"
        ),
        params![
            d.id,
            d.kind,
            d.title,
            d.content,
            d.parent_id,
            d.sort,
            serde_json::to_string(&d.tags).unwrap_or_else(|_| "[]".into()),
            d.day,
            d.pinned,
            d.source_system,
            d.source_key,
            d.source_url,
            d.created_at,
            d.updated_at,
            d.updated_by,
            d.base_at,
            d.deleted,
            d.published_url,
            dirty
        ],
    )
    .db()?;
    let mut keys = refs::extract(&d.content);
    if let (Some(system), Some(key)) = (&d.source_system, &d.source_key) {
        keys.push((system.clone(), key.clone()));
    }
    let body = format!("{}\n{}", d.tags.join(" "), refs::plain_text(&d.content));
    // 模板不是正文内容，不出现在搜索和反向链接中
    index(conn, "doc", &d.id, d.deleted || d.kind == TEMPLATE_KIND, &d.title, &body, keys)
}

fn index(conn: &Connection, item_type: &str, id: &str, deleted: bool, title: &str, body: &str, keys: Vec<(String, String)>) -> Result<()> {
    conn.execute("DELETE FROM refs WHERE item_type = ?1 AND item_id = ?2", params![item_type, id]).db()?;
    conn.execute("DELETE FROM search WHERE item_type = ?1 AND item_id = ?2", params![item_type, id]).db()?;
    if deleted {
        return Ok(());
    }
    for (system, key) in keys {
        conn.execute(
            "INSERT OR IGNORE INTO refs (item_type, item_id, system, key) VALUES (?1, ?2, ?3, ?4)",
            params![item_type, id, system, key],
        )
        .db()?;
    }
    conn.execute(
        "INSERT INTO search (item_type, item_id, title, body) VALUES (?1, ?2, ?3, ?4)",
        params![item_type, id, title, body],
    )
    .db()?;
    Ok(())
}

fn summary(d: &Doc) -> DocSummary {
    DocSummary {
        id: d.id.clone(),
        kind: d.kind.clone(),
        title: d.title.clone(),
        excerpt: refs::plain_text(&d.content).chars().take(140).collect(),
        parent_id: d.parent_id.clone(),
        sort: d.sort,
        tags: d.tags.clone(),
        day: d.day.clone(),
        pinned: d.pinned,
        source_system: d.source_system.clone(),
        source_key: d.source_key.clone(),
        published_url: d.published_url.clone(),
        updated_at: d.updated_at,
    }
}

fn clean_tags(tags: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for tag in tags.into_iter().map(|t| t.trim().trim_start_matches('#').to_string()).filter(|t| !t.is_empty()) {
        if !out.contains(&tag) {
            out.push(tag);
        }
    }
    out
}

/// 匹配位置附近的一段文字。
fn snippet(body: &str, query: &str) -> String {
    let chars: Vec<char> = body.chars().collect();
    let lower: String = body.to_lowercase();
    let start = lower
        .find(&query.to_lowercase())
        .map(|byte| lower[..byte].chars().count())
        .unwrap_or(0);
    let from = start.saturating_sub(30);
    let text: String = chars.iter().skip(from).take(120).collect();
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if from > 0 { format!("…{text}") } else { text }
}

#[cfg(test)]
mod tests;
