import Foundation
import NWZCore

/// JSON 保留完整同步记录，查询列和派生索引与记录在同一事务内写入。
/// 所有连接操作都由 Database actor 串行执行，业务事务中没有挂起点。
public actor Workspace {
    let database: Database
    public nonisolated let deviceID: String
    /// 正在进行的同步：同时发起的同步依次执行（见 sync(at:)）
    var syncing: Task<SyncReport, Error>?

    public init(path: String = ":memory:") async throws {
        let database = try Database(path: path, migrations: [.init(version: 1, sql: Self.schema)])
        self.deviceID = try await database.transaction { db in
            if let value = try db.query("SELECT value FROM meta WHERE key='device_id'").first?["value"]?.string { return value }
            let value = UUID().uuidString.lowercased()
            try db.execute("INSERT INTO meta VALUES ('device_id',?)", [.text(value)])
            return value
        }
        self.database = database
    }

    public nonisolated static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    nonisolated static func stamp(_ previous: Int64 = 0) -> Int64 { max(now(), previous + 1) }
    nonisolated static func newID() -> String { UUID().uuidString.lowercased() }
    public func getMeta(_ key: String) async throws -> String? {
        try await database.query("SELECT value FROM meta WHERE key=?", [.text(key)]).first?["value"]?.string
    }
    public func setMeta(_ key: String, value: String) async throws {
        try await database.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", [.text(key), .text(value)])
    }

    private static let schema = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE records (
        type TEXT NOT NULL, id TEXT NOT NULL, json TEXT NOT NULL,
        title TEXT NOT NULL, body TEXT NOT NULL, kind TEXT NOT NULL,
        sort REAL NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0,
        parent_id TEXT, day TEXT, pinned INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        updated_by TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1, base_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (type, id)
    );
    CREATE INDEX records_kind ON records(type, kind, deleted);
    CREATE INDEX records_parent ON records(parent_id, deleted);
    CREATE TABLE assets (id TEXT PRIMARY KEY, mime TEXT NOT NULL, data BLOB, created_at INTEGER NOT NULL, dirty INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE fired_alerts (id TEXT PRIMARY KEY, at INTEGER NOT NULL);
    CREATE TABLE refs (item_type TEXT NOT NULL, item_id TEXT NOT NULL, system TEXT NOT NULL, key TEXT NOT NULL, PRIMARY KEY(item_type,item_id,system,key));
    CREATE INDEX refs_target ON refs(system,key);
    CREATE VIRTUAL TABLE search USING fts5(item_type UNINDEXED, item_id UNINDEXED, title, body, tokenize='trigram');
    CREATE TABLE sync_cursors (device TEXT PRIMARY KEY, offset INTEGER NOT NULL, generation TEXT NOT NULL DEFAULT '');
    """
}

internal enum Store {
    static func load<T: Decodable>(_ type: T.Type, table: String, id: String, db: isolated Database) throws -> T? {
        guard let text = try db.query("SELECT json FROM records WHERE type=? AND id=?", [.text(table), .text(id)]).first?["json"]?.string else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
    static func list<T: Decodable>(_ type: T.Type, table: String, condition: String = "deleted=0", values: [SQLValue] = [], order: String = "updated_at DESC", db: isolated Database) throws -> [T] {
        try db.query("SELECT json FROM records WHERE type=? AND \(condition) ORDER BY \(order)", [.text(table)] + values).map { row in
            try JSONDecoder().decode(T.self, from: Data((row["json"]?.string ?? "").utf8))
        }
    }
    static func sort(_ type: String, kind: String? = nil, parent: String? = nil, db: isolated Database) throws -> Double {
        let rows = try db.query("SELECT COALESCE(\(type == "todo" ? "MIN" : "MAX")(sort),0) AS value FROM records WHERE type=? AND deleted=0" + (kind == nil ? "" : " AND kind=? AND parent_id IS ?"), [.text(type)] + (kind.map { [.text($0), value(parent)] } ?? []))
        let value: Double
        switch rows.first?["value"] { case .real(let n): value = n; case .integer(let n): value = Double(n); default: value = 0 }
        return value + (type == "todo" ? -1 : 1)
    }
    static func value(_ text: String?) -> SQLValue { text.map(SQLValue.text) ?? .null }
    static func write(_ todo: Todo, dirty: Bool = true, db: isolated Database) throws {
        var references = References.extract(todo.title + "\n" + todo.notes)
        if let system = todo.refSystem, let key = todo.refKey { references.append(.init(system: system, key: key)) }
        try writeRecord(todo, type: "todo", id: todo.id, title: todo.title, body: References.plainText(todo.notes), kind: "todo", sort: todo.sort, done: todo.done, created: todo.createdAt, updated: todo.updatedAt, device: todo.updatedBy, deleted: todo.deleted, dirty: dirty, references: references, db: db)
    }
    static func write(_ doc: Doc, dirty: Bool = true, db: isolated Database) throws {
        var references = References.extract(doc.title + "\n" + doc.content)
        if let system = doc.sourceSystem, let key = doc.sourceKey { references.append(.init(system: system, key: key)) }
        try writeRecord(doc, type: "doc", id: doc.id, title: doc.title, body: doc.tags.joined(separator: " ") + "\n" + References.plainText(doc.content), kind: doc.kind, sort: doc.sort, parent: doc.parentId, day: doc.day, pinned: doc.pinned, created: doc.createdAt, updated: doc.updatedAt, device: doc.updatedBy, deleted: doc.deleted, dirty: dirty, base: doc.baseAt, references: references, db: db)
    }
    static func write(_ entry: InboxEntry, dirty: Bool = true, db: isolated Database) throws {
        try writeRecord(entry, type: "inbox", id: entry.id, title: entry.title, body: entry.body, kind: entry.kind, created: entry.createdAt, updated: entry.updatedAt, device: entry.updatedBy, deleted: entry.deleted, dirty: dirty, references: [], db: db)
    }
    private static func writeRecord<T: Encodable>(_ record: T, type: String, id: String, title: String, body: String, kind: String, sort: Double = 0, done: Bool = false, parent: String? = nil, day: String? = nil, pinned: Bool = false, created: Int64, updated: Int64, device: String, deleted: Bool, dirty: Bool, base: Int64 = 0, references: [Reference], db: isolated Database) throws {
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        try db.execute("INSERT OR REPLACE INTO records (type,id,json,title,body,kind,sort,done,parent_id,day,pinned,created_at,updated_at,updated_by,deleted,dirty,base_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [.text(type), .text(id), .text(json), .text(title), .text(body), .text(kind), .real(sort), .integer(done ? 1 : 0), value(parent), value(day), .integer(pinned ? 1 : 0), .integer(created), .integer(updated), .text(device), .integer(deleted ? 1 : 0), .integer(dirty ? 1 : 0), .integer(base)])
        try db.execute("DELETE FROM refs WHERE item_type=? AND item_id=?", [.text(type), .text(id)])
        try db.execute("DELETE FROM search WHERE item_type=? AND item_id=?", [.text(type), .text(id)])
        guard !deleted, type != "inbox", kind != "jira-template" else { return }
        for reference in references {
            try db.execute("INSERT OR IGNORE INTO refs VALUES (?,?,?,?)", [.text(type), .text(id), .text(reference.system), .text(reference.key)])
        }
        try db.execute("INSERT INTO search VALUES (?,?,?,?)", [.text(type), .text(id), .text(title), .text(body)])
    }
}
