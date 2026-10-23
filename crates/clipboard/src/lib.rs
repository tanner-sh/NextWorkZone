//! 剪贴板历史：保存复制过的文字、图片和文件，支持搜索、按类型和来源筛选、置顶板（收藏）。
//!
//! 数据保存在本机的 SQLite 数据库中，图片另存为 PNG 文件（原图和缩略图）。相同内容只保存一份，
//! 再次复制时移到最前面。置顶板中的条目不会被自动清理。

pub mod classify;
pub mod privacy;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use nextworkzone_core::{Error, Result};
use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// 列表中每条文字最多返回的字符数（卡片只显示开头一部分）。
const PREVIEW_CHARS: usize = 800;
/// 超过这个长度的文字不保存（多半是误复制的整份文件）。
pub const MAX_TEXT_BYTES: usize = 4 * 1024 * 1024;
/// HTML 超过这个长度时只保存纯文本。
const MAX_HTML_BYTES: usize = 1024 * 1024;
/// 缩略图的最大尺寸。
const THUMB_SIZE: u32 = 480;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS items (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    hash TEXT NOT NULL UNIQUE,
    text TEXT NOT NULL DEFAULT '',
    html TEXT,
    title TEXT NOT NULL DEFAULT '',
    image_width INTEGER,
    image_height INTEGER,
    image_bytes INTEGER,
    files TEXT,
    app_id TEXT,
    app_name TEXT,
    created_at INTEGER NOT NULL,
    copied_at INTEGER NOT NULL,
    copy_count INTEGER NOT NULL DEFAULT 1,
    pinboard TEXT,
    pinned_at INTEGER
);
CREATE INDEX IF NOT EXISTS items_copied ON items (copied_at DESC);
CREATE INDEX IF NOT EXISTS items_pinboard ON items (pinboard, pinned_at DESC);
CREATE TABLE IF NOT EXISTS pinboards (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    color TEXT NOT NULL,
    sort REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS apps (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    color TEXT,
    has_icon INTEGER NOT NULL DEFAULT 0
);
CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, body, tokenize = 'trigram');
"#;

trait Db<T> {
    fn db(self) -> Result<T>;
}

impl<T> Db<T> for rusqlite::Result<T> {
    fn db(self) -> Result<T> {
        self.map_err(|e| Error::Other(format!("剪贴板数据库错误：{e}")))
    }
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn hash(parts: &[&[u8]]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update((part.len() as u64).to_le_bytes());
        hasher.update(part);
    }
    hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// 新复制的一份内容。
#[derive(Default)]
pub struct Capture {
    pub text: Option<String>,
    pub html: Option<String>,
    /// 宽、高和 RGBA 像素。
    pub image: Option<(u32, u32, Vec<u8>)>,
    pub files: Vec<String>,
    /// 来源应用（标识, 名称）。
    pub app: Option<(String, String)>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageMeta {
    pub width: u32,
    pub height: u32,
    /// PNG 文件大小。
    pub bytes: u64,
}

/// 一条历史记录。列表中的 `text` 只有开头一部分，完整内容见 [`Store::content`]。
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipItem {
    pub id: String,
    /// 见 [`classify::KINDS`]。
    pub kind: String,
    pub text: String,
    /// 完整文字的字符数。
    pub text_length: usize,
    pub has_html: bool,
    /// 用户起的名字（置顶的常用片段）。
    pub title: String,
    pub image: Option<ImageMeta>,
    pub files: Vec<String>,
    pub app_id: Option<String>,
    pub app_name: Option<String>,
    /// 来源应用图标的主色，例如 `#3b82f6`。
    pub app_color: Option<String>,
    pub app_icon: bool,
    pub created_at: i64,
    pub copied_at: i64,
    pub copy_count: i64,
    pub pinboard: Option<String>,
}

/// 写回剪贴板所需的完整内容。
pub struct ClipContent {
    pub id: String,
    pub kind: String,
    pub text: String,
    pub html: Option<String>,
    pub image: Option<PathBuf>,
    pub files: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pinboard {
    pub id: String,
    pub name: String,
    pub color: String,
    pub sort: f64,
    pub count: i64,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ListQuery {
    pub text: String,
    pub kind: Option<String>,
    /// 只看某个置顶板；`"*"` 表示所有置顶的条目。
    pub pinboard: Option<String>,
    pub app: Option<String>,
    /// 分页：只返回最近复制时间早于此的条目。
    pub before: Option<i64>,
    pub limit: Option<usize>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub items: i64,
    pub pinned: i64,
    /// 图片占用的空间（字节）。
    pub image_bytes: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppCount {
    pub id: String,
    pub name: String,
    pub color: Option<String>,
    pub icon: bool,
    pub count: i64,
}

pub struct Store {
    conn: Mutex<Connection>,
    dir: PathBuf,
}

const ITEM_COLUMNS: &str = "i.id, i.kind, substr(i.text, 1, ?PREVIEW), length(i.text), i.html IS NOT NULL, i.title, i.image_width, i.image_height, i.image_bytes, i.files, i.app_id, i.app_name, a.color, COALESCE(a.has_icon, 0), i.created_at, i.copied_at, i.copy_count, i.pinboard";

fn item_from_row(row: &Row) -> rusqlite::Result<ClipItem> {
    let width: Option<u32> = row.get(6)?;
    let height: Option<u32> = row.get(7)?;
    let files: Option<String> = row.get(9)?;
    Ok(ClipItem {
        id: row.get(0)?,
        kind: row.get(1)?,
        text: row.get(2)?,
        text_length: row.get::<_, i64>(3)? as usize,
        has_html: row.get(4)?,
        title: row.get(5)?,
        image: match (width, height) {
            (Some(width), Some(height)) => Some(ImageMeta { width, height, bytes: row.get::<_, Option<i64>>(8)?.unwrap_or(0) as u64 }),
            _ => None,
        },
        files: files.map(|f| f.lines().map(str::to_string).collect()).unwrap_or_default(),
        app_id: row.get(10)?,
        app_name: row.get(11)?,
        app_color: row.get(12)?,
        app_icon: row.get(13)?,
        created_at: row.get(14)?,
        copied_at: row.get(15)?,
        copy_count: row.get(16)?,
        pinboard: row.get(17)?,
    })
}

fn select_items(where_clause: &str) -> String {
    format!(
        "SELECT {} FROM items i LEFT JOIN apps a ON a.id = i.app_id {where_clause}",
        ITEM_COLUMNS.replace("?PREVIEW", &PREVIEW_CHARS.to_string())
    )
}

impl Store {
    /// 打开（或创建）`dir` 下的剪贴板历史。
    pub fn open(dir: &Path) -> Result<Self> {
        for sub in ["images", "thumbs", "icons"] {
            fs::create_dir_all(dir.join(sub))?;
        }
        let conn = Connection::open(dir.join("clipboard.db")).db()?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;").db()?;
        conn.execute_batch(SCHEMA).db()?;
        Ok(Self { conn: Mutex::new(conn), dir: dir.to_path_buf() })
    }

    /// 数据所在的文件夹。
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// 原图的宽、高和 RGBA 像素（写回剪贴板时使用）。
    pub fn load_image(&self, id: &str) -> Result<(u32, u32, Vec<u8>)> {
        let image = image::open(self.image_path(id)).map_err(|e| Error::Other(format!("图片已丢失：{e}")))?.to_rgba8();
        Ok((image.width(), image.height(), image.into_raw()))
    }

    pub fn image_path(&self, id: &str) -> PathBuf {
        self.dir.join("images").join(format!("{}.png", safe_name(id)))
    }

    pub fn thumb_path(&self, id: &str) -> PathBuf {
        self.dir.join("thumbs").join(format!("{}.png", safe_name(id)))
    }

    pub fn icon_path(&self, app_id: &str) -> PathBuf {
        self.dir.join("icons").join(format!("{}.png", &hash(&[app_id.as_bytes()])[..24]))
    }

    /// 保存一份新复制的内容。相同内容已存在时把它移到最前面并返回 `(条目, false)`。
    /// 内容为空或过大时返回 `None`。
    pub fn add(&self, capture: Capture) -> Result<Option<(ClipItem, bool)>> {
        let now = now_ms();
        let (kind, text, html, files_text, item_hash) = if !capture.files.is_empty() {
            let joined = capture.files.join("\n");
            (classify::FILE, String::new(), None, Some(joined.clone()), hash(&[b"file", joined.as_bytes()]))
        } else if let Some(text) = capture.text.filter(|t| !t.trim().is_empty()) {
            if text.len() > MAX_TEXT_BYTES {
                return Ok(None);
            }
            let html = capture.html.filter(|h| h.len() <= MAX_HTML_BYTES);
            (classify::kind_of_text(&text), text.clone(), html, None, hash(&[b"text", text.as_bytes()]))
        } else if let Some((w, h, rgba)) = &capture.image {
            (classify::IMAGE, String::new(), None, None, hash(&[b"image", &w.to_le_bytes(), &h.to_le_bytes(), rgba]))
        } else {
            return Ok(None);
        };

        let (app_id, app_name) = capture.app.unzip();
        {
            let conn = self.conn.lock().unwrap();
            // 复制时间严格递增：同一毫秒内连续复制时，最近复制的仍排在最前
            let latest: i64 = conn.query_row("SELECT COALESCE(MAX(copied_at), 0) FROM items", [], |r| r.get(0)).db()?;
            let now = now.max(latest + 1);
            let existing: Option<String> = conn.query_row("SELECT id FROM items WHERE hash = ?1", [&item_hash], |r| r.get(0)).optional().db()?;
            if let Some(id) = existing {
                // 再次复制：移到最前面；来源记为最近一次复制的应用，网页上复制的格式可能更完整
                conn.execute(
                    "UPDATE items SET copied_at = ?2, copy_count = copy_count + 1,
                        app_id = COALESCE(?3, app_id), app_name = COALESCE(?4, app_name), html = COALESCE(?5, html)
                     WHERE id = ?1",
                    params![id, now, app_id, app_name, html],
                )
                .db()?;
                drop(conn);
                return Ok(self.item(&id)?.map(|item| (item, false)));
            }
        }

        let id = uuid::Uuid::new_v4().to_string();
        let mut image_meta = None;
        if let Some((w, h, rgba)) = capture.image.filter(|_| kind == classify::IMAGE) {
            image_meta = Some((w, h, self.save_image(&id, w, h, rgba)?));
        }
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO items (id, kind, hash, text, html, image_width, image_height, image_bytes, files, app_id, app_name, created_at, copied_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12)",
            params![
                id,
                kind,
                item_hash,
                text,
                html,
                image_meta.map(|m| m.0),
                image_meta.map(|m| m.1),
                image_meta.map(|m| m.2 as i64),
                files_text,
                app_id,
                app_name,
                now
            ],
        )
        .db()?;
        let body = search_body(&text, "", files_text.as_deref(), app_name.as_deref());
        conn.execute("INSERT INTO search (id, body) VALUES (?1, ?2)", params![id, body]).db()?;
        drop(conn);
        Ok(self.item(&id)?.map(|item| (item, true)))
    }

    /// 保存原图和缩略图，返回原图 PNG 的大小。
    fn save_image(&self, id: &str, width: u32, height: u32, rgba: Vec<u8>) -> Result<u64> {
        let image = image::RgbaImage::from_raw(width, height, rgba).ok_or_else(|| Error::Other("图片数据不完整".into()))?;
        let path = self.image_path(id);
        image.save_with_format(&path, image::ImageFormat::Png).map_err(|e| Error::Other(format!("保存图片失败：{e}")))?;
        let (tw, th) = fit(width, height, THUMB_SIZE);
        let thumb = if (tw, th) == (width, height) { image } else { image::imageops::thumbnail(&image, tw, th) };
        thumb.save_with_format(self.thumb_path(id), image::ImageFormat::Png).map_err(|e| Error::Other(format!("保存缩略图失败：{e}")))?;
        Ok(fs::metadata(&path)?.len())
    }

    pub fn item(&self, id: &str) -> Result<Option<ClipItem>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(&select_items("WHERE i.id = ?1"), [id], item_from_row).optional().db()
    }

    /// 写回剪贴板所需的完整内容。
    pub fn content(&self, id: &str) -> Result<Option<ClipContent>> {
        let conn = self.conn.lock().unwrap();
        let row = conn
            .query_row("SELECT kind, text, html, files FROM items WHERE id = ?1", [id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?, r.get::<_, Option<String>>(3)?))
            })
            .optional()
            .db()?;
        Ok(row.map(|(kind, text, html, files)| ClipContent {
            id: id.to_string(),
            image: (kind == classify::IMAGE).then(|| self.image_path(id)),
            kind,
            text,
            html,
            files: files.map(|f| f.lines().map(str::to_string).collect()).unwrap_or_default(),
        }))
    }

    /// 按条件列出，最近复制的在前；置顶板中按置顶时间排列。
    pub fn list(&self, query: &ListQuery) -> Result<Vec<ClipItem>> {
        let mut conditions = Vec::new();
        let mut values: Vec<rusqlite::types::Value> = Vec::new();
        let text = query.text.trim();
        if !text.is_empty() {
            if text.chars().count() >= 3 {
                conditions.push("i.id IN (SELECT id FROM search WHERE search MATCH ?)".to_string());
                values.push(format!("\"{}\"", text.replace('"', "\"\"")).into());
            } else {
                conditions.push("i.id IN (SELECT id FROM search WHERE body LIKE ? ESCAPE '\\')".to_string());
                values.push(format!("%{}%", text.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")).into());
            }
        }
        if let Some(kind) = query.kind.as_deref().filter(|k| !k.is_empty()) {
            conditions.push("i.kind = ?".into());
            values.push(kind.to_string().into());
        }
        let pinned_order = match query.pinboard.as_deref().filter(|p| !p.is_empty()) {
            Some("*") => {
                conditions.push("i.pinboard IS NOT NULL".into());
                true
            }
            Some(board) => {
                conditions.push("i.pinboard = ?".into());
                values.push(board.to_string().into());
                true
            }
            None => false,
        };
        if let Some(app) = query.app.as_deref().filter(|a| !a.is_empty()) {
            conditions.push("i.app_id = ?".into());
            values.push(app.to_string().into());
        }
        // 同一毫秒内复制的条目按写入顺序，后写入的在前
        let order = if pinned_order { "i.pinned_at DESC, i.rowid DESC" } else { "i.copied_at DESC, i.rowid DESC" };
        if let Some(before) = query.before {
            conditions.push(if pinned_order { "i.pinned_at < ?" } else { "i.copied_at < ?" }.into());
            values.push(before.into());
        }
        let where_clause = if conditions.is_empty() { String::new() } else { format!("WHERE {}", conditions.join(" AND ")) };
        let limit = query.limit.unwrap_or(100).min(1000);
        let sql = select_items(&format!("{where_clause} ORDER BY {order} LIMIT {limit}"));
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&sql).db()?;
        stmt.query_map(params_from_iter(values), item_from_row).db()?.collect::<rusqlite::Result<Vec<_>>>().db()
    }

    /// 标记为刚刚使用（粘贴时调用），移到最前面。
    pub fn touch(&self, ids: &[String]) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let now = now_ms();
        for (offset, id) in ids.iter().enumerate() {
            // 多条一起粘贴时保持原来的先后顺序
            conn.execute("UPDATE items SET copied_at = ?2, copy_count = copy_count + 1 WHERE id = ?1", params![id, now - offset as i64]).db()?;
        }
        Ok(())
    }

    pub fn delete(&self, ids: &[String]) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        for id in ids {
            conn.execute("DELETE FROM items WHERE id = ?1", [id]).db()?;
            conn.execute("DELETE FROM search WHERE id = ?1", [id]).db()?;
        }
        drop(conn);
        for id in ids {
            self.remove_files(id);
        }
        Ok(())
    }

    fn remove_files(&self, id: &str) {
        let _ = fs::remove_file(self.image_path(id));
        let _ = fs::remove_file(self.thumb_path(id));
    }

    /// 清空历史，置顶的条目保留。返回删除的条数。
    pub fn clear_history(&self) -> Result<usize> {
        let ids: Vec<String> = {
            let conn = self.conn.lock().unwrap();
            let mut stmt = conn.prepare("SELECT id FROM items WHERE pinboard IS NULL").db()?;
            stmt.query_map([], |r| r.get(0)).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?
        };
        self.delete(&ids)?;
        Ok(ids.len())
    }

    /// 清理过期的历史：超过 `keep_days` 天（0 表示不限）或超出 `max_items` 条（0 表示不限）的未置顶条目。
    pub fn prune(&self, keep_days: u32, max_items: u32) -> Result<usize> {
        let ids: Vec<String> = {
            let conn = self.conn.lock().unwrap();
            let cutoff = if keep_days == 0 { i64::MIN } else { now_ms() - keep_days as i64 * 86_400_000 };
            let offset = if max_items == 0 { i64::MAX } else { max_items as i64 };
            let mut stmt = conn
                .prepare(
                    "SELECT id FROM items WHERE pinboard IS NULL AND (copied_at < ?1 OR id IN (
                        SELECT id FROM items WHERE pinboard IS NULL ORDER BY copied_at DESC, rowid DESC LIMIT -1 OFFSET ?2))",
                )
                .db()?;
            stmt.query_map(params![cutoff, offset], |r| r.get(0)).db()?.collect::<rusqlite::Result<Vec<_>>>().db()?
        };
        self.delete(&ids)?;
        Ok(ids.len())
    }

    /// 修改文字内容（编辑后保存）。内容与另一条相同时合并到那一条。返回修改后的条目。
    pub fn update_text(&self, id: &str, text: &str) -> Result<Option<ClipItem>> {
        if text.trim().is_empty() || text.len() > MAX_TEXT_BYTES {
            return Err(Error::Other("内容为空或过长".into()));
        }
        let new_hash = hash(&[b"text", text.as_bytes()]);
        let conn = self.conn.lock().unwrap();
        if let Some(other) = conn.query_row("SELECT id FROM items WHERE hash = ?1", [&new_hash], |r| r.get::<_, String>(0)).optional().db()?
            && other != id
        {
            drop(conn);
            self.delete(&[id.to_string()])?;
            return self.item(&other);
        }
        conn.execute(
            "UPDATE items SET text = ?2, html = NULL, hash = ?3, kind = ?4 WHERE id = ?1 AND kind NOT IN ('image', 'file')",
            params![id, text, new_hash, classify::kind_of_text(text)],
        )
        .db()?;
        Self::reindex(&conn, id)?;
        drop(conn);
        self.item(id)
    }

    /// 给条目起名字（为空表示取消）。
    pub fn rename(&self, id: &str, title: &str) -> Result<Option<ClipItem>> {
        let conn = self.conn.lock().unwrap();
        conn.execute("UPDATE items SET title = ?2 WHERE id = ?1", params![id, title.trim()]).db()?;
        Self::reindex(&conn, id)?;
        drop(conn);
        self.item(id)
    }

    fn reindex(conn: &Connection, id: &str) -> Result<()> {
        let row = conn
            .query_row("SELECT text, title, files, app_name FROM items WHERE id = ?1", [id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?, r.get::<_, Option<String>>(3)?))
            })
            .optional()
            .db()?;
        conn.execute("DELETE FROM search WHERE id = ?1", [id]).db()?;
        if let Some((text, title, files, app)) = row {
            conn.execute("INSERT INTO search (id, body) VALUES (?1, ?2)", params![id, search_body(&text, &title, files.as_deref(), app.as_deref())]).db()?;
        }
        Ok(())
    }

    /// 放入置顶板（`None` 表示取消置顶）。
    pub fn set_pinboard(&self, ids: &[String], pinboard: Option<&str>) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let now = now_ms();
        for (offset, id) in ids.iter().enumerate() {
            conn.execute(
                "UPDATE items SET pinboard = ?2, pinned_at = CASE WHEN ?2 IS NULL THEN NULL ELSE ?3 END WHERE id = ?1",
                params![id, pinboard, now - offset as i64],
            )
            .db()?;
        }
        Ok(())
    }

    pub fn pinboards(&self) -> Result<Vec<Pinboard>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT p.id, p.name, p.color, p.sort, (SELECT COUNT(*) FROM items WHERE pinboard = p.id) FROM pinboards p ORDER BY p.sort, p.name")
            .db()?;
        stmt.query_map([], |r| Ok(Pinboard { id: r.get(0)?, name: r.get(1)?, color: r.get(2)?, sort: r.get(3)?, count: r.get(4)? }))
            .db()?
            .collect::<rusqlite::Result<Vec<_>>>()
            .db()
    }

    /// 新建（`id` 为空）或修改置顶板。
    pub fn save_pinboard(&self, id: Option<&str>, name: &str, color: &str) -> Result<Pinboard> {
        let name = name.trim();
        if name.is_empty() {
            return Err(Error::Other("请输入名称".into()));
        }
        let conn = self.conn.lock().unwrap();
        let id = match id.filter(|i| !i.is_empty()) {
            Some(id) => {
                conn.execute("UPDATE pinboards SET name = ?2, color = ?3 WHERE id = ?1", params![id, name, color]).db()?;
                id.to_string()
            }
            None => {
                let id = uuid::Uuid::new_v4().to_string();
                let sort: f64 = conn.query_row("SELECT COALESCE(MAX(sort), 0) + 1 FROM pinboards", [], |r| r.get(0)).db()?;
                conn.execute("INSERT INTO pinboards (id, name, color, sort) VALUES (?1, ?2, ?3, ?4)", params![id, name, color, sort]).db()?;
                id
            }
        };
        drop(conn);
        self.pinboards()?.into_iter().find(|p| p.id == id).ok_or_else(|| Error::Other("置顶板不存在".into()))
    }

    /// 删除置顶板，其中的条目回到历史中（取消置顶）。
    pub fn delete_pinboard(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("UPDATE items SET pinboard = NULL, pinned_at = NULL, copied_at = MAX(copied_at, ?2) WHERE pinboard = ?1", params![id, now_ms() - 1]).db()?;
        conn.execute("DELETE FROM pinboards WHERE id = ?1", [id]).db()?;
        Ok(())
    }

    /// 调整置顶板的顺序：按给定的 id 顺序排列。
    pub fn order_pinboards(&self, ids: &[String]) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        for (index, id) in ids.iter().enumerate() {
            conn.execute("UPDATE pinboards SET sort = ?2 WHERE id = ?1", params![id, index as f64]).db()?;
        }
        Ok(())
    }

    /// 是否已记录过这个应用的图标和颜色。
    pub fn has_app(&self, app_id: &str) -> Result<bool> {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT 1 FROM apps WHERE id = ?1", [app_id], |_| Ok(())).optional().db().map(|r| r.is_some())
    }

    /// 记录应用的名称和图标（PNG），并从图标中取主色。
    pub fn save_app(&self, app_id: &str, name: &str, icon_png: Option<&[u8]>) -> Result<()> {
        let mut color = None;
        if let Some(png) = icon_png {
            fs::write(self.icon_path(app_id), png)?;
            color = image::load_from_memory(png).ok().and_then(|img| dominant_color(&img.to_rgba8()));
        }
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO apps (id, name, color, has_icon) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color, has_icon = excluded.has_icon",
            params![app_id, name, color, icon_png.is_some()],
        )
        .db()?;
        Ok(())
    }

    /// 出现过的来源应用及条数，条数多的在前。
    pub fn apps(&self) -> Result<Vec<AppCount>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT i.app_id, MAX(i.app_name), a.color, COALESCE(a.has_icon, 0), COUNT(*) FROM items i LEFT JOIN apps a ON a.id = i.app_id
                 WHERE i.app_id IS NOT NULL GROUP BY i.app_id ORDER BY COUNT(*) DESC",
            )
            .db()?;
        stmt.query_map([], |r| Ok(AppCount { id: r.get(0)?, name: r.get(1)?, color: r.get(2)?, icon: r.get(3)?, count: r.get(4)? }))
            .db()?
            .collect::<rusqlite::Result<Vec<_>>>()
            .db()
    }

    pub fn stats(&self) -> Result<Stats> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(*), COUNT(pinboard), COALESCE(SUM(image_bytes), 0) FROM items",
            [],
            |r| Ok(Stats { items: r.get(0)?, pinned: r.get(1)?, image_bytes: r.get(2)? }),
        )
        .db()
    }
}

fn search_body(text: &str, title: &str, files: Option<&str>, app: Option<&str>) -> String {
    [title, text, files.unwrap_or(""), app.unwrap_or("")].iter().filter(|s| !s.is_empty()).copied().collect::<Vec<_>>().join("\n")
}

/// 只保留 id 中可以用作文件名的字符。
fn safe_name(id: &str) -> String {
    id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect()
}

/// 按比例缩小到 `max` 以内。
fn fit(width: u32, height: u32, max: u32) -> (u32, u32) {
    if width <= max && height <= max {
        return (width, height);
    }
    let scale = max as f64 / width.max(height) as f64;
    (((width as f64 * scale).round() as u32).max(1), ((height as f64 * scale).round() as u32).max(1))
}

/// 把 PNG 等图片缩小到 `max` 以内并编码为 PNG（拖动时显示的预览图）。
pub fn shrink_png(data: &[u8], max: u32) -> Option<Vec<u8>> {
    let image = image::load_from_memory(data).ok()?;
    let (w, h) = fit(image.width(), image.height(), max);
    let mut out = std::io::Cursor::new(Vec::new());
    image.thumbnail(w, h).write_to(&mut out, image::ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

/// 图标的主色：不透明且有一定饱和度的像素的平均色；图标几乎是灰色时返回 `None`。
pub fn dominant_color(image: &image::RgbaImage) -> Option<String> {
    let (mut r, mut g, mut b, mut weight) = (0f64, 0f64, 0f64, 0f64);
    for pixel in image.pixels() {
        let [pr, pg, pb, pa] = pixel.0;
        if pa < 200 {
            continue;
        }
        let max = pr.max(pg).max(pb) as f64;
        let min = pr.min(pg).min(pb) as f64;
        let saturation = if max == 0.0 { 0.0 } else { (max - min) / max };
        // 很亮或很暗的像素（白底、描边）不计入
        if saturation < 0.25 || max < 40.0 {
            continue;
        }
        let w = saturation * saturation;
        r += pr as f64 * w;
        g += pg as f64 * w;
        b += pb as f64 * w;
        weight += w;
    }
    let opaque = image.pixels().filter(|p| p.0[3] >= 200).count().max(1) as f64;
    if weight < opaque * 0.02 {
        return None;
    }
    Some(format!("#{:02x}{:02x}{:02x}", (r / weight) as u8, (g / weight) as u8, (b / weight) as u8))
}

#[cfg(test)]
mod tests;
