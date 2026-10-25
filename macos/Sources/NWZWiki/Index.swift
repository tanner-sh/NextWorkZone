import Foundation
import NWZCore

public struct IndexedWikiPage: Sendable {
    public var id: String
    public var kind: String
    public var spaceKey: String
    public var spaceName: String
    public var title: String
    public var ancestors: [WikiAncestor]
    public var author: String
    public var authorName: String
    public var modified: String
    public var version: Int
    public var storage: String
    public init(id: String, kind: String = "page", spaceKey: String = "", spaceName: String = "", title: String, ancestors: [WikiAncestor] = [], author: String = "", authorName: String = "", modified: String = "", version: Int = 0, storage: String) {
        self.id = id; self.kind = kind; self.spaceKey = spaceKey; self.spaceName = spaceName; self.title = title; self.ancestors = ancestors; self.author = author; self.authorName = authorName; self.modified = modified; self.version = version; self.storage = storage
    }
    public init?(raw: JSONDocument) {
        guard let id = raw["id"].string else { return nil }
        self.init(id: id, kind: raw["type"].string ?? "page", spaceKey: raw["space"]["key"].text, spaceName: raw["space"]["name"].text, title: raw["title"].text, ancestors: WikiBrowse.ancestors(raw["ancestors"]), author: raw["version"]["by"]["userKey"].text, authorName: raw["version"]["by"]["displayName"].text, modified: raw["version"]["when"].text, version: raw["version"]["number"].int, storage: raw["body"]["storage"]["value"].text)
    }
}
public struct WikiIndexStats: Sendable {
    public var count: Int
    public var spaces: [WikiIndexSpace]
    public var lastSync: String?
}
public struct AssignedWikiTask: Sendable {
    public var pageId: String
    public var pageTitle: String
    public var task: InlineTask
}

public actor WikiIndex {
    let database: Database
    public init(path: String = ":memory:") throws {
        database = try Database(path: path, migrations: [.init(version: 1, sql: Self.schema)])
    }
    private static let deleteTrigger = """
        CREATE TRIGGER pages_fts_delete AFTER DELETE ON pages BEGIN
            INSERT INTO pages_fts(pages_fts,rowid,title_lc,text_lc) VALUES('delete',old.rowid,old.title_lc,old.text_lc);
        END
        """
    private static let schema = """
        CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE pages(id TEXT PRIMARY KEY,kind TEXT NOT NULL,space_key TEXT NOT NULL,space_name TEXT NOT NULL,title TEXT NOT NULL,title_lc TEXT NOT NULL,ancestors TEXT NOT NULL,author TEXT NOT NULL,author_name TEXT NOT NULL,modified TEXT NOT NULL,modified_ms INTEGER NOT NULL,version INTEGER NOT NULL,text TEXT NOT NULL,text_lc TEXT NOT NULL,jira_keys TEXT NOT NULL);
        CREATE INDEX pages_space ON pages(space_key);
        CREATE INDEX pages_modified ON pages(modified_ms);
        CREATE TABLE tasks(page_id TEXT NOT NULL,task_id TEXT NOT NULL,done INTEGER NOT NULL,text TEXT NOT NULL,assignees TEXT NOT NULL,due TEXT,PRIMARY KEY(page_id,task_id));
        CREATE TABLE viewed(id TEXT PRIMARY KEY,title TEXT NOT NULL,space_key TEXT NOT NULL,at INTEGER NOT NULL);
        CREATE VIRTUAL TABLE pages_fts USING fts5(title_lc,text_lc,content='pages',content_rowid='rowid',tokenize='trigram',detail='none');
        CREATE TRIGGER pages_fts_replace BEFORE INSERT ON pages BEGIN DELETE FROM pages WHERE id=new.id; END;
        CREATE TRIGGER pages_fts_insert AFTER INSERT ON pages BEGIN
            INSERT INTO pages_fts(rowid,title_lc,text_lc) VALUES(new.rowid,new.title_lc,new.text_lc);
        END;
        \(deleteTrigger);
        CREATE TRIGGER pages_fts_update AFTER UPDATE ON pages BEGIN
            INSERT INTO pages_fts(pages_fts,rowid,title_lc,text_lc) VALUES('delete',old.rowid,old.title_lc,old.text_lc);
            INSERT INTO pages_fts(rowid,title_lc,text_lc) VALUES(new.rowid,new.title_lc,new.text_lc);
        END;
        """
    public static func time(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }
    public static func fold(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { String($0).lowercased().unicodeScalars.first ?? $0 }))
    }
    static func terms(_ text: String) -> [String] {
        var out: [String] = []
        for t in text.split(whereSeparator: \.isWhitespace).map({ fold(String($0)) }) where !out.contains(t) && out.count < 8 { out.append(t) }
        return out
    }
    private static func deletePages(_ db: isolated Database) throws {
        // 大批重建先清空 FTS，避免逐页读取正文更新倒排索引。这里不能执行 VACUUM 改变 rowid。
        try db.execute("INSERT INTO pages_fts(pages_fts) VALUES('delete-all')")
        try db.execute("DROP TRIGGER pages_fts_delete")
        try db.execute("DELETE FROM pages")
        try db.execute("DELETE FROM tasks")
        try db.execute(deleteTrigger)
    }
    public func ensureScope(base: String, spaces: [String], identity: String? = nil) async throws {
        let scope = base + "|" + spaces.joined(separator: ",") + "|" + (identity ?? "")
        try await database.transaction { db in
            let old = try db.query("SELECT value FROM meta WHERE key='scope'").first?["value"]?.string
            guard old != scope else { return }
            try Self.deletePages(db)
            try db.execute("DELETE FROM meta WHERE key IN ('cursor','last_sync','last_prune')")
            if old?.components(separatedBy: "|").first != base { try db.execute("DELETE FROM viewed") }
            try db.execute("INSERT OR REPLACE INTO meta(key,value) VALUES('scope',?)", [.text(scope)])
        }
    }
    public func clear() async throws {
        try await database.transaction { db in
            try Self.deletePages(db)
            try db.execute("DELETE FROM meta WHERE key IN ('cursor','last_sync','last_prune')")
        }
    }
    func get(_ key: String) async throws -> String? { try await database.query("SELECT value FROM meta WHERE key=?", [.text(key)]).first?["value"]?.string }
    func put(_ key: String, _ value: String) async throws { try await database.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [.text(key), .text(value)]) }

    public func upsert(_ pages: [IndexedWikiPage]) async throws {
        // 解析可能包含几十万字的页面时让出 actor，搜索不必等待解析，也不占用数据库事务。
        let parsed: [([SQLValue], [[SQLValue]])] = try await Task.detached(priority: .utility) {
            try pages.map { p in
                let text = String(WikiText.readableLines(p.storage).joined(separator: "\n").unicodeScalars.prefix(200_000))
                let keys = WikiText.jiraKeys(storage: p.storage, text: text), tasks = WikiText.inlineTasks(p.storage)
                let ancestors = String(decoding: try JSONEncoder().encode(p.ancestors), as: UTF8.self)
                let row: [SQLValue] = [.text(p.id), .text(p.kind), .text(p.spaceKey), .text(p.spaceName), .text(p.title), .text(Self.fold(p.title)), .text(ancestors), .text(p.author), .text(p.authorName), .text(p.modified), .integer(Int64((Self.time(p.modified)?.timeIntervalSince1970 ?? 0) * 1000)), .integer(Int64(p.version)), .text(text), .text(Self.fold(text)), .text(" " + keys.joined(separator: " ") + " ")]
                return (row, tasks.map { [.text(p.id), .text($0.taskId), .integer($0.done ? 1 : 0), .text($0.text), .text(" " + $0.assignees.joined(separator: " ") + " "), $0.due.map(SQLValue.text) ?? .null] })
            }
        }.value
        try Task.checkCancellation()
        try await database.transaction { db in
            for (row, tasks) in parsed {
                try db.execute("INSERT OR REPLACE INTO pages(id,kind,space_key,space_name,title,title_lc,ancestors,author,author_name,modified,modified_ms,version,text,text_lc,jira_keys) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", row)
                try db.execute("DELETE FROM tasks WHERE page_id=?", [row[0]])
                for task in tasks { try db.execute("INSERT OR REPLACE INTO tasks(page_id,task_id,done,text,assignees,due) VALUES(?,?,?,?,?,?)", task) }
            }
        }
    }
    public func prune(alive: Set<String>) async throws -> Int {
        try await database.transaction { db in
            let ids = try db.query("SELECT id FROM pages").compactMap { $0["id"]?.string }.filter { !alive.contains($0) }
            for id in ids {
                try db.execute("DELETE FROM pages WHERE id=?", [.text(id)])
                try db.execute("DELETE FROM tasks WHERE page_id=?", [.text(id)])
            }
            return ids.count
        }
    }
    public func stats() async throws -> WikiIndexStats {
        let spaces = try await database.query("SELECT space_key,MAX(space_name) AS name,COUNT(*) AS n FROM pages GROUP BY space_key ORDER BY n DESC").map { WikiIndexSpace(key: $0["space_key"]?.string ?? "", name: $0["name"]?.string ?? "", count: Int($0["n"]?.integer ?? 0)) }
        return try await WikiIndexStats(count: spaces.reduce(0) { $0 + $1.count }, spaces: spaces, lastSync: get("last_sync"))
    }
    public func isEmpty() async throws -> Bool { try await database.query("SELECT COUNT(*) AS n FROM pages").first?["n"]?.integer == 0 }
    public func search(_ query: WikiQuery, me: String = "", now: Date = Date()) async throws -> [WikiPageHit] {
        try await search(query, me: me, now: now, shortcut: true)
    }
    /// `shortcut` 为假时总是做完整查询（测试中用来核对两种查法的结果相同）。
    func search(_ query: WikiQuery, me: String = "", now: Date = Date(), shortcut: Bool) async throws -> [WikiPageHit] {
        let terms = Self.terms(query.text)
        if shortcut, terms.count == 1, terms[0].unicodeScalars.count < 3, let hits = try await searchShort(terms[0], query, me: me, now: now) { return hits }
        var args: [SQLValue] = [], conditions: [String] = [], scores: [String] = [], parameters: [String] = []
        func arg(_ value: SQLValue) -> String { args.append(value); return "?\(args.count)" }
        for term in terms {
            let p = arg(.text(term)); parameters.append(p)
            if term.unicodeScalars.count >= 3, !term.contains("%"), !term.contains("_") {
                let like = arg(.text("%" + term + "%"))
                conditions.append("rowid IN (SELECT rowid FROM pages_fts WHERE title_lc LIKE \(like) OR text_lc LIKE \(like))")
            }
            conditions.append("(instr(title_lc,\(p)) OR instr(text_lc,\(p)))")
            scores.append("(instr(title_lc,\(p))>0)*10")
        }
        if let space = query.space, !space.isEmpty { conditions.append("space_key=\(arg(.text(space)))") }
        if let kind = query.kind, !kind.isEmpty { conditions.append("kind=\(arg(.text(kind)))") }
        if query.mine == true, !me.isEmpty { conditions.append("author=\(arg(.text(me)))") }
        if let days = query.days, days > 0 { conditions.append("modified_ms>=\(arg(.integer(Int64(now.timeIntervalSince1970 * 1000 - Double(days) * 86_400_000))))") }
        let limit = min(300, max(1, query.limit == nil || query.limit == 0 ? 50 : query.limit!))
        let score = scores.isEmpty ? "0" : "(" + scores.joined(separator: " + ") + ")"
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "WITH top AS (SELECT rowid AS r,\(score) AS score,modified_ms FROM pages \(filter) ORDER BY score DESC,modified_ms DESC LIMIT \(limit)) SELECT \(Self.hitColumns),\(Self.snippetColumns(parameters)) FROM top JOIN pages ON pages.rowid=top.r ORDER BY top.score DESC,top.modified_ms DESC"
        return try await database.query(sql, args).map(Self.hit)
    }
    /// 一两个字的单个关键词：用不上 trigram 索引，完整的查询要逐页查找全部正文（几千个页面约 50 毫秒）。
    /// 结果的顺序是标题含关键词的在前、各自按修改时间排列，所以分两步：先取标题匹配的；不够时再按修改时间
    /// 倒序逐页找正文匹配的，找够就停。常用词很快就能找够。结果与完整查询相同。
    private func searchShort(_ term: String, _ query: WikiQuery, me: String, now: Date) async throws -> [WikiPageHit]? {
        var args: [SQLValue] = [.text(term)], conditions: [String] = []
        func arg(_ value: SQLValue) -> String { args.append(value); return "?\(args.count)" }
        if let space = query.space, !space.isEmpty { conditions.append("space_key=\(arg(.text(space)))") }
        if let kind = query.kind, !kind.isEmpty { conditions.append("kind=\(arg(.text(kind)))") }
        if query.mine == true, !me.isEmpty { conditions.append("author=\(arg(.text(me)))") }
        if let days = query.days, days > 0 { conditions.append("modified_ms>=\(arg(.integer(Int64(now.timeIntervalSince1970 * 1000 - Double(days) * 86_400_000))))") }
        let limit = min(300, max(1, query.limit == nil || query.limit == 0 ? 50 : query.limit!))
        let extra = conditions.map { " AND " + $0 }.joined()
        let columns = "\(Self.hitColumns),\(Self.snippetColumns(["?1"]))"
        let titled = try await database.query("SELECT \(columns) FROM pages WHERE instr(title_lc,?1)>0\(extra) ORDER BY modified_ms DESC LIMIT \(limit)", args)
        guard titled.count < limit else { return titled.map(Self.hit) }
        let rest = try await database.query("SELECT \(columns) FROM pages INDEXED BY pages_modified WHERE instr(title_lc,?1)=0 AND instr(text_lc,?1)>0\(extra) ORDER BY modified_ms DESC LIMIT \(limit - titled.count)", args)
        return (titled + rest).map(Self.hit)
    }
    public func pagesWithIssue(_ key: String, limit: Int) async throws -> [WikiPageHit] {
        try await database.query("SELECT \(Self.hitColumns),\(Self.snippetColumns(["?2"])) FROM pages WHERE instr(jira_keys,?1)>0 ORDER BY modified_ms DESC LIMIT \(max(0, limit))", [.text(" " + key + " "), .text(Self.fold(key))]).map(Self.hit)
    }
    public func titles(_ ids: [String]) async throws -> [(id: String, title: String, space: String)] {
        var result: [(String, String, String)] = []
        for id in ids {
            if let row = try await database.query("SELECT title,space_name FROM pages WHERE id=?", [.text(id)]).first { result.append((id, row["title"]?.string ?? "", row["space_name"]?.string ?? "")) }
        }
        return result
    }
    public func assignedTasks(_ user: String) async throws -> [AssignedWikiTask] {
        try await database.query("SELECT t.page_id,p.title,t.task_id,t.done,t.text,t.assignees,t.due FROM tasks t JOIN pages p ON p.id=t.page_id WHERE instr(t.assignees,?1)>0 AND t.done=0 ORDER BY p.modified_ms DESC", [.text(" " + user + " ")]).map { r in
            AssignedWikiTask(pageId: r["page_id"]?.string ?? "", pageTitle: r["title"]?.string ?? "", task: InlineTask(taskId: r["task_id"]?.string ?? "", done: r["done"]?.integer == 1, text: r["text"]?.string ?? "", assignees: (r["assignees"]?.string ?? "").split(whereSeparator: \.isWhitespace).map(String.init), due: r["due"]?.string))
        }
    }
    public func setTaskDone(page: String, task: String, done: Bool) async throws { try await database.execute("UPDATE tasks SET done=?3 WHERE page_id=?1 AND task_id=?2", [.text(page), .text(task), .integer(done ? 1 : 0)]) }
    public func markViewed(_ id: String, title: String, space: String) async throws {
        try await database.transaction { db in
            let last = try db.query("SELECT MAX(at) AS at FROM viewed").first?["at"]?.integer ?? 0
            let now = max(Int64(Date().timeIntervalSince1970 * 1000), last + 1)
            try db.execute("INSERT OR REPLACE INTO viewed(id,title,space_key,at) VALUES(?,?,?,?)", [.text(id), .text(title), .text(space), .integer(now)])
            try db.execute("DELETE FROM viewed WHERE id NOT IN (SELECT id FROM viewed ORDER BY at DESC LIMIT 200)")
        }
    }
    public func recent(limit: Int) async throws -> [WikiRecent] {
        try await database.query("SELECT id,title,space_key,at FROM viewed ORDER BY at DESC LIMIT \(max(0, limit))").map { WikiRecent(id: $0["id"]?.string ?? "", title: $0["title"]?.string ?? "", space: $0["space_key"]?.string ?? "", at: $0["at"]?.integer ?? 0, source: "app") }
    }
    func checkIntegrity() async throws { try await database.execute("INSERT INTO pages_fts(pages_fts,rank) VALUES('integrity-check',1)") }
    private static let hitColumns = "id,kind,title,space_key,space_name,ancestors,author_name,modified"
    private static func snippetColumns(_ parameters: [String]) -> String {
        let from = parameters.isEmpty ? "0" : "max(COALESCE(" + parameters.map { "NULLIF(instr(text_lc,\($0)),0)" }.joined(separator: ",") + ",0)-31,0)"
        return "\(from) AS snippet_start,substr(text,\(from)+1,120) AS snippet"
    }
    private static func hit(_ row: [String: SQLValue]) -> WikiPageHit {
        func s(_ key: String) -> String { row[key]?.string ?? "" }
        let ancestors = (try? JSONDecoder().decode([WikiAncestor].self, from: Data(s("ancestors").utf8))) ?? []
        let snippet = ((row["snippet_start"]?.integer ?? 0) > 0 ? "…" : "") + WikiStorage.collapseWhitespace(s("snippet"))
        return WikiPageHit(id: s("id"), kind: s("kind"), title: s("title"), spaceKey: s("space_key"), spaceName: s("space_name"), ancestors: ancestors, authorName: s("author_name"), modified: s("modified"), snippet: snippet)
    }
}
