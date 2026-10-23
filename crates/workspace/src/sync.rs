//! 多设备同步：通过一个共享文件夹（iCloud Drive、坚果云、NAS 等）交换变更日志。
//!
//! 目录结构：
//! - `devices/<设备 id>.jsonl`：每台设备只追加写自己的文件，每行是一条完整的记录（待办、文档或图片信息）；
//! - `assets/<图片 id>`：图片内容，写入后不再修改。
//!
//! 每台设备只写自己的文件，同步盘不会出现同一文件被多端同时修改的冲突。
//! 读取其他设备的文件时记录读到的位置，下次从该位置继续。合并规则：修改时间较晚的记录胜出；
//! 文档两端都有未同步的修改且内容不同时，本地版本另存为“冲突副本”，不丢失内容。

use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use nextworkzone_core::Result;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::{AssetMeta, Db, Doc, InboxEntry, SyncReport, Todo, Workspace, load_doc, load_inbox, load_todo, new_id, now_ms, write_doc, write_inbox, write_todo};

#[derive(Serialize, Deserialize)]
#[serde(tag = "type", content = "row", rename_all = "camelCase")]
enum Record {
    /// 整理后的文件第一行：每次整理生成新的代号，读取方据此知道文件已被重写
    Header { generation: String },
    Todo(Todo),
    Doc(Doc),
    Asset(AssetMeta),
    Inbox(InboxEntry),
}

impl Workspace {
    /// 与同步文件夹交换数据：先导出本地修改，再合并其他设备的修改。
    pub fn sync(&self, dir: &Path) -> Result<SyncReport> {
        let devices_dir = dir.join("devices");
        let assets_dir = dir.join("assets");
        fs::create_dir_all(&devices_dir)?;
        fs::create_dir_all(&assets_dir)?;
        let conn = self.conn.lock().unwrap();
        let mut report = SyncReport { exported: export(&conn, &devices_dir.join(format!("{}.jsonl", self.device)), &assets_dir)?, ..Default::default() };

        for entry in fs::read_dir(&devices_dir)? {
            let path = entry?.path();
            let Some(device) = path.file_stem().and_then(|s| s.to_str()).map(str::to_string) else { continue };
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") || device == self.device {
                continue;
            }
            report.devices += 1;
            let (imported, conflicts) = import(&conn, &device, &path, &assets_dir, &self.device)?;
            report.imported += imported;
            report.conflicts += conflicts;
        }
        fill_assets(&conn, &assets_dir)?;
        report.finished_at = now_ms();
        Ok(report)
    }
}

/// 把未导出的修改追加到本设备的日志文件。
fn export(conn: &Connection, file: &Path, assets_dir: &Path) -> Result<usize> {
    let todos: Vec<Todo> = {
        let mut stmt = conn.prepare(&format!("SELECT {} FROM todos WHERE dirty = 1", crate::TODO_COLUMNS)).db()?;
        stmt.query_map([], crate::todo_from_row).db()?.collect::<rusqlite::Result<_>>().db()?
    };
    let docs: Vec<Doc> = {
        let mut stmt = conn.prepare(&format!("SELECT {} FROM docs WHERE dirty = 1", crate::DOC_COLUMNS)).db()?;
        stmt.query_map([], crate::doc_from_row).db()?.collect::<rusqlite::Result<_>>().db()?
    };
    let inbox: Vec<InboxEntry> = {
        let mut stmt = conn.prepare(&format!("SELECT {} FROM inbox WHERE dirty = 1", crate::INBOX_COLUMNS)).db()?;
        stmt.query_map([], crate::inbox_from_row).db()?.collect::<rusqlite::Result<_>>().db()?
    };
    let assets: Vec<(AssetMeta, Vec<u8>)> = {
        let mut stmt = conn.prepare("SELECT id, mime, created_at, data FROM assets WHERE dirty = 1 AND data IS NOT NULL").db()?;
        stmt.query_map([], |r| Ok((AssetMeta { id: r.get(0)?, mime: r.get(1)?, created_at: r.get(2)? }, r.get(3)?)))
            .db()?
            .collect::<rusqlite::Result<_>>()
            .db()?
    };
    if todos.is_empty() && docs.is_empty() && inbox.is_empty() && assets.is_empty() {
        return Ok(0);
    }
    // 图片先落盘，其他设备读到记录时内容已经在了
    for (meta, data) in &assets {
        let path = assets_dir.join(&meta.id);
        if !path.exists() {
            let tmp = assets_dir.join(format!(".{}.tmp", meta.id));
            fs::write(&tmp, data)?;
            fs::rename(&tmp, &path)?;
        }
    }
    let mut text = String::new();
    let records = assets.iter().map(|(m, _)| Record::Asset(m.clone()))
        .chain(todos.iter().cloned().map(Record::Todo))
        .chain(docs.iter().cloned().map(Record::Doc))
        .chain(inbox.iter().cloned().map(Record::Inbox));
    for record in records {
        text.push_str(&serde_json::to_string(&record)?);
        text.push('\n');
    }
    let mut out = OpenOptions::new().create(true).append(true).open(file)?;
    out.write_all(text.as_bytes())?;
    out.sync_all()?;
    if out.metadata()?.len() > COMPACT_THRESHOLD {
        compact(conn, file)?;
    }
    // 只清除导出时的版本；导出期间又被修改的行保持待导出
    for t in &todos {
        conn.execute("UPDATE todos SET dirty = 0 WHERE id = ?1 AND updated_at = ?2", params![t.id, t.updated_at]).db()?;
    }
    for d in &docs {
        conn.execute("UPDATE docs SET dirty = 0 WHERE id = ?1 AND updated_at = ?2", params![d.id, d.updated_at]).db()?;
    }
    for e in &inbox {
        conn.execute("UPDATE inbox SET dirty = 0 WHERE id = ?1 AND updated_at = ?2", params![e.id, e.updated_at]).db()?;
    }
    for (meta, _) in &assets {
        conn.execute("UPDATE assets SET dirty = 0 WHERE id = ?1", params![meta.id]).db()?;
    }
    Ok(todos.len() + docs.len() + inbox.len() + assets.len())
}

/// 本设备日志超过该大小时整理（每次同步追加的是整行，文档反复修改会让日志不断变长）。
pub const COMPACT_THRESHOLD: u64 = 8 * 1024 * 1024;

/// 把本设备的日志重写为“本设备修改的每条记录的最新版本”。
/// 其他设备发现文件变短后会从头重读，按修改时间合并，不会重复生效。
fn compact(conn: &Connection, file: &Path) -> Result<()> {
    let me: String = conn.query_row("SELECT value FROM meta WHERE key = 'device_id'", [], |r| r.get(0)).db()?;
    let mut text = serde_json::to_string(&Record::Header { generation: new_id() })?;
    text.push('\n');
    {
        let mut stmt = conn.prepare("SELECT id, mime, created_at FROM assets WHERE data IS NOT NULL").db()?;
        let assets = stmt.query_map([], |r| Ok(AssetMeta { id: r.get(0)?, mime: r.get(1)?, created_at: r.get(2)? })).db()?;
        for meta in assets {
            text.push_str(&serde_json::to_string(&Record::Asset(meta.db()?))?);
            text.push('\n');
        }
    }
    {
        let mut stmt = conn.prepare(&format!("SELECT {} FROM todos WHERE updated_by = ?1", crate::TODO_COLUMNS)).db()?;
        for todo in stmt.query_map(params![me], crate::todo_from_row).db()? {
            text.push_str(&serde_json::to_string(&Record::Todo(todo.db()?))?);
            text.push('\n');
        }
    }
    {
        let mut stmt = conn.prepare(&format!("SELECT {} FROM docs WHERE updated_by = ?1", crate::DOC_COLUMNS)).db()?;
        for doc in stmt.query_map(params![me], crate::doc_from_row).db()? {
            text.push_str(&serde_json::to_string(&Record::Doc(doc.db()?))?);
            text.push('\n');
        }
    }
    {
        let mut stmt = conn.prepare(&format!("SELECT {} FROM inbox WHERE updated_by = ?1", crate::INBOX_COLUMNS)).db()?;
        for entry in stmt.query_map(params![me], crate::inbox_from_row).db()? {
            text.push_str(&serde_json::to_string(&Record::Inbox(entry.db()?))?);
            text.push('\n');
        }
    }
    let tmp = file.with_extension("jsonl.tmp");
    fs::write(&tmp, text)?;
    fs::rename(&tmp, file)?;
    Ok(())
}

/// 读取另一台设备新增的记录并合并，返回 (合并条数, 冲突副本数)。
fn import(conn: &Connection, device: &str, file: &Path, assets_dir: &Path, me: &str) -> Result<(usize, usize)> {
    let (mut offset, seen_generation): (u64, String) = conn
        .query_row("SELECT offset, generation FROM sync_cursors WHERE device = ?1", params![device], |r| {
            Ok((r.get::<_, i64>(0)? as u64, r.get(1)?))
        })
        .optional()
        .db()?
        .unwrap_or((0, String::new()));
    let mut f = fs::File::open(file)?;
    let len = f.metadata()?.len();
    let generation = read_generation(&mut f)?;
    if generation != seen_generation || len < offset {
        // 文件被整理（重写）过：从头读，按修改时间合并不会重复生效
        offset = 0;
    }
    f.seek(SeekFrom::Start(offset))?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;
    // 只处理完整的行；最后一行可能还在同步中
    let Some(last_newline) = buf.iter().rposition(|b| *b == b'\n') else { return Ok((0, 0)) };
    let chunk = &buf[..=last_newline];

    let tx = conn.unchecked_transaction().db()?;
    let (mut imported, mut conflicts) = (0, 0);
    for line in chunk.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
        // 无法识别的行（例如新版本写入的类型）跳过
        let Ok(record) = serde_json::from_slice::<Record>(line) else { continue };
        match record {
            Record::Header { .. } => {}
            Record::Todo(incoming) => {
                let local = load_todo(&tx, &incoming.id)?;
                if local.as_ref().is_none_or(|l| newer(incoming.updated_at, &incoming.updated_by, l.updated_at, &l.updated_by)) {
                    write_todo(&tx, &incoming, false)?;
                    imported += 1;
                }
            }
            Record::Doc(incoming) => {
                let local = load_doc(&tx, &incoming.id)?;
                let wins = local.as_ref().is_none_or(|l| newer(incoming.updated_at, &incoming.updated_by, l.updated_at, &l.updated_by));
                if !wins {
                    // 本地版本较新；若两边是各自修改的，由传来版本所在的设备在合并时保存它的副本
                    continue;
                }
                if let Some(local) = &local
                    // 传来的版本不是在本地当前版本上修改的 → 两台设备各自改过
                    && incoming.base_at != local.updated_at
                    // 只由本地版本的作者保存副本，避免每台设备各存一份
                    && local.updated_by == me
                    && !local.deleted
                    && !incoming.deleted
                    && local.content != incoming.content
                {
                    let now = now_ms();
                    let copy = Doc {
                        id: new_id(),
                        title: format!("{}（冲突副本）", if local.title.is_empty() { "无标题" } else { &local.title }),
                        // 日记的副本作为普通笔记保存，避免占用同一天
                        kind: if local.kind == "daily" { "note".into() } else { local.kind.clone() },
                        day: None,
                        created_at: now,
                        updated_at: now,
                        updated_by: me.to_string(),
                        base_at: 0,
                        ..local.clone()
                    };
                    write_doc(&tx, &copy, true)?;
                    conflicts += 1;
                }
                write_doc(&tx, &incoming, false)?;
                imported += 1;
            }
            Record::Inbox(incoming) => {
                let local = load_inbox(&tx, &incoming.id)?;
                if local.as_ref().is_none_or(|l| newer(incoming.updated_at, &incoming.updated_by, l.updated_at, &l.updated_by)) {
                    write_inbox(&tx, &incoming, false)?;
                    imported += 1;
                }
            }
            Record::Asset(meta) => {
                let data = fs::read(assets_dir.join(&meta.id)).ok();
                tx.execute(
                    "INSERT OR IGNORE INTO assets (id, mime, data, created_at, dirty) VALUES (?1, ?2, ?3, ?4, 0)",
                    params![meta.id, meta.mime, data, meta.created_at],
                )
                .db()?;
            }
        }
    }
    tx.execute(
        "INSERT OR REPLACE INTO sync_cursors (device, offset, generation) VALUES (?1, ?2, ?3)",
        params![device, (offset + chunk.len() as u64) as i64, generation],
    )
    .db()?;
    tx.commit().db()?;
    Ok((imported, conflicts))
}

/// 文件第一行的整理代号；从未整理过的文件为空。
fn read_generation(f: &mut fs::File) -> Result<String> {
    let mut head = vec![0u8; 256];
    let n = f.read(&mut head)?;
    head.truncate(n);
    let first = head.split(|b| *b == b'\n').next().unwrap_or_default();
    Ok(match serde_json::from_slice::<Record>(first) {
        Ok(Record::Header { generation }) => generation,
        _ => String::new(),
    })
}

/// 补上之前同步时内容尚未到达的图片。
fn fill_assets(conn: &Connection, assets_dir: &Path) -> Result<()> {
    let missing: Vec<String> = {
        let mut stmt = conn.prepare("SELECT id FROM assets WHERE data IS NULL").db()?;
        stmt.query_map([], |r| r.get(0)).db()?.collect::<rusqlite::Result<_>>().db()?
    };
    for id in missing {
        if let Ok(data) = fs::read(assets_dir.join(&id)) {
            conn.execute("UPDATE assets SET data = ?1 WHERE id = ?2", params![data, id]).db()?;
        }
    }
    Ok(())
}

/// 修改时间相同时按设备 id 决定，保证各设备得到相同的结果。
fn newer(a_time: i64, a_device: &str, b_time: i64, b_device: &str) -> bool {
    (a_time, a_device) > (b_time, b_device)
}
