import Foundation
import NWZCore

public actor IssueIndex {
    private let database: Database
    public init(path: String = ":memory:") throws {
        database = try Database(path: path, migrations: [.init(version: 1, sql: """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE issues (key TEXT PRIMARY KEY, project TEXT NOT NULL, project_name TEXT NOT NULL, updated_ms INTEGER NOT NULL, resolved INTEGER NOT NULL, summary_lc TEXT NOT NULL, description_lc TEXT NOT NULL, comments_lc TEXT NOT NULL, participants TEXT NOT NULL, data TEXT NOT NULL);
            CREATE INDEX issues_project ON issues(project);
            CREATE TABLE cursors (scope TEXT PRIMARY KEY, cursor TEXT NOT NULL);
            CREATE TABLE viewed (key TEXT PRIMARY KEY, at INTEGER NOT NULL);
            CREATE TABLE boilerplate (prefix TEXT PRIMARY KEY, n INTEGER NOT NULL);
            """)])
    }
    public func ensureBase(_ base: String) async throws {
        try await database.transaction { db in
            let old = try db.query("SELECT value FROM meta WHERE key = 'base_url'").first?["value"]?.string
            if let old, old != base {
                for table in ["issues", "cursors", "viewed", "boilerplate", "meta"] { try db.execute("DELETE FROM \(table)") }
            }
            try db.execute("INSERT OR REPLACE INTO meta (key,value) VALUES ('base_url',?)", [.text(base)])
        }
    }
    public func clear() async throws {
        try await database.transaction { db in
            for table in ["issues", "cursors", "boilerplate"] { try db.execute("DELETE FROM \(table)") }
            try db.execute("DELETE FROM meta WHERE key = 'last_sync'")
        }
    }
    public func cursor(_ scope: String) async throws -> String? { try await database.query("SELECT cursor FROM cursors WHERE scope = ?", [.text(scope)]).first?["cursor"]?.string }
    public func setCursor(_ scope: String, cursor: String) async throws { try await database.execute("INSERT OR REPLACE INTO cursors (scope,cursor) VALUES (?,?)", [.text(scope), .text(cursor)]) }
    public func finishSync(changed: Int) async throws {
        try await database.transaction { db in
            let count = try db.query("SELECT COUNT(*) AS n FROM boilerplate").first?["n"]?.integer ?? 0
            if changed > 0 || count == 0 {
                try db.execute("DELETE FROM boilerplate")
                try db.execute("""
                    INSERT INTO boilerplate (prefix,n)
                    SELECT p,COUNT(DISTINCT k) FROM (SELECT issues.key AS k,substr(json_extract(c.value,'$.body'),1,20) AS p FROM issues,json_each(issues.data,'$.comments') AS c)
                    WHERE length(p)>0 GROUP BY p HAVING COUNT(DISTINCT k)>=20
                    """)
            }
            try db.execute("INSERT OR REPLACE INTO meta (key,value) VALUES ('last_sync',?)", [.text(Date().ISO8601Format())])
        }
    }
    public func upsert(_ issues: [IndexedIssue]) async throws {
        // 编码和正文处理在数据库事务之外完成，同步大批数据时不占用连接。
        let values: [[SQLValue]] = try issues.map { item in
            let issue = item.issue, data = try JSONEncoder().encode(item)
            let names = ([issue.assigneeName, issue.reporterName].compactMap { $0 } + item.comments.map(\.authorName)).filter { !$0.isEmpty }
            let participants = " " + Set(names).sorted().joined(separator: " ") + " "
            let milliseconds = Int64((JiraActivity.time(issue.updated)?.timeIntervalSince1970 ?? 0) * 1000)
            return [.text(issue.key), .text(JiraIndexText.project(issue.key)), .text(issue.project.name), .integer(milliseconds), .integer(issue.resolution == nil ? 0 : 1), .text(JiraIndexText.fold(issue.summary)), .text(JiraIndexText.fold(item.description)), .text(JiraIndexText.fold(item.comments.map(\.body).joined(separator: "\n"))), .text(participants), .text(String(decoding: data, as: UTF8.self))]
        }
        try await database.transaction { db in
            for value in values { try db.execute("INSERT OR REPLACE INTO issues (key,project,project_name,updated_ms,resolved,summary_lc,description_lc,comments_lc,participants,data) VALUES (?,?,?,?,?,?,?,?,?,?)", value) }
        }
    }
    public func isEmpty() async throws -> Bool { try await database.query("SELECT 1 AS found FROM issues LIMIT 1").isEmpty }
    public func stats() async throws -> (count: Int, projects: [IndexProject], lastSync: String?) {
        let projects = try await database.query("SELECT project,MAX(project_name) AS name,COUNT(*) AS n FROM issues GROUP BY project ORDER BY n DESC").map { IndexProject(key: $0["project"]?.string ?? "", name: $0["name"]?.string ?? "", count: Int($0["n"]?.integer ?? 0)) }
        let lastSync = try await database.query("SELECT value FROM meta WHERE key = 'last_sync'").first?["value"]?.string
        return (projects.reduce(0) { $0 + $1.count }, projects, lastSync)
    }
    public func search(_ query: IndexQuery, me: String) async throws -> [IssueHit] {
        let terms = JiraIndexText.terms(query.text)
        var arguments: [SQLValue] = [], conditions: [String] = [], scores: [String] = []
        func bind(_ value: String) -> String { arguments.append(.text(value)); return "?\(arguments.count)" }
        for term in terms {
            let parameter = bind(term)
            var matches = "instr(summary_lc,\(parameter)) OR instr(description_lc,\(parameter)) OR instr(comments_lc,\(parameter))"
            if JiraQueries.looksLikeKey(term) { let key = bind(term.uppercased()); matches += " OR key=\(key)"; scores.append("(key=\(key))*100") }
            conditions.append("(\(matches))")
            scores.append("(instr(summary_lc,\(parameter))>0)*10+(instr(description_lc,\(parameter))>0)*3+(instr(comments_lc,\(parameter))>0)")
        }
        if !query.project.isEmpty { conditions.append("project=\(bind(query.project))") }
        if query.state == "unresolved" { conditions.append("resolved=0") }
        if query.state == "resolved" { conditions.append("resolved=1") }
        if query.mine && !me.isEmpty { conditions.append("instr(participants,\(bind(" " + me + " ")))>0") }
        let limit = min(500, max(1, query.limit == nil || query.limit == 0 ? 100 : query.limit!))
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let order = scores.isEmpty ? "" : "(" + scores.joined(separator: " + ") + ") DESC,"
        let rows = try await database.query("SELECT data FROM issues \(filter) ORDER BY \(order) updated_ms DESC LIMIT \(limit)", arguments)
        return Self.decode(rows).map { $0.hit(terms: terms) }
    }
    public func byKeys(_ keys: [String]) async throws -> [IssueHit] {
        var result: [IssueHit] = []
        for key in keys { result += Self.decode(try await database.query("SELECT data FROM issues WHERE key=?", [.text(key.uppercased())])).map { $0.hit() } }
        return result
    }
    public func mentioning(_ needles: [String], accept: @Sendable (String) -> Bool, limit: Int) async throws -> [IssueHit] {
        guard !needles.isEmpty else { return [] }
        let condition = (1...needles.count).map { "instr(description_lc,?\($0)) OR instr(comments_lc,?\($0))" }.joined(separator: " OR ")
        let rows = try await database.query("SELECT data FROM issues WHERE \(condition) ORDER BY updated_ms DESC LIMIT 200", needles.map(SQLValue.text))
        return Self.decode(rows).filter { ([ $0.description ] + $0.comments.map(\.body)).contains(where: accept) }.prefix(max(0, limit)).map { $0.hit(terms: needles) }
    }
    public func similar(key: String, summary: String, resolvedOnly: Bool, limit: Int) async throws -> [IssueHit]? {
        let indexed = try await database.query("SELECT COUNT(*) AS n FROM issues WHERE project=?", [.text(JiraIndexText.project(key))]).first?["n"]?.integer ?? 0
        guard indexed > 0 else { return nil }
        let terms = JiraQueries.summaryTerms(summary).map(JiraIndexText.fold)
        guard !terms.isEmpty else { return [] }
        let total = try await database.query("SELECT COUNT(*) AS n FROM issues").first?["n"]?.integer ?? 0
        let columns = terms.indices.map { "COALESCE(SUM(instr(summary_lc,?\($0 + 1))>0),0) AS n\($0)" }.joined(separator: ",")
        let counts = try await database.query("SELECT \(columns) FROM issues", terms.map(SQLValue.text)).first ?? [:]
        var scores: [String] = [], matches: [String] = []
        for index in terms.indices {
            let count = counts["n\(index)"]?.integer ?? 0
            if count == 0 { continue }
            let weight = max(0.05, log((Double(total) + 1) / (Double(count) + 1))), parameter = "?\(index + 1)"
            scores.append("(instr(summary_lc,\(parameter))>0)*\(weight * 3)+(instr(substr(description_lc,1,1000),\(parameter))>0)*\(weight)")
            matches.append("instr(summary_lc,\(parameter))")
        }
        guard !matches.isEmpty else { return [] }
        let sql = "SELECT data FROM issues WHERE key!=?\(terms.count + 1) AND (\(matches.joined(separator: " OR ")))\(resolvedOnly ? " AND resolved=1" : "") ORDER BY (\(scores.joined(separator: " + "))) DESC,updated_ms DESC LIMIT \(min(500, max(1, limit)))"
        let rows = try await database.query(sql, (terms + [key]).map(SQLValue.text))
        let boilerplate = Set(try await database.query("SELECT prefix FROM boilerplate").compactMap { $0["prefix"]?.string })
        return Self.decode(rows).map { $0.hit(boilerplate: boilerplate) }
    }
    public func viewed(_ keys: [String]) async throws -> Viewed {
        try await database.transaction { db in
            let previous = try db.query("SELECT value FROM meta WHERE key='viewed_baseline'").first?["value"]?.string.flatMap(Int64.init)
            let baseline = previous ?? Int64(Date().timeIntervalSince1970 * 1000)
            if previous == nil { try db.execute("INSERT OR REPLACE INTO meta (key,value) VALUES ('viewed_baseline',?)", [.text(String(baseline))]) }
            var map: [String: Int64] = [:]
            for key in keys { map[key] = try db.query("SELECT at FROM viewed WHERE key=?", [.text(key)]).first?["at"]?.integer }
            return Viewed(viewed: map, baseline: baseline)
        }
    }
    public func markViewed(_ key: String, at: Int64) async throws -> Int64? {
        try await database.transaction { db in
            let previous = try db.query("SELECT at FROM viewed WHERE key=?", [.text(key)]).first?["at"]?.integer
            try db.execute("INSERT OR REPLACE INTO viewed (key,at) VALUES (?,?)", [.text(key), .integer(max(at, previous ?? 0))])
            return previous
        }
    }
    private static func decode(_ rows: [[String: SQLValue]]) -> [IndexedIssue] {
        rows.compactMap { $0["data"]?.string }.compactMap { try? JSONDecoder().decode(IndexedIssue.self, from: Data($0.utf8)) }
    }
}
