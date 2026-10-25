import Foundation
import NWZCore
import NWZJira

public actor ActivityStore {
    private let database: Database
    public init(path: String = ":memory:") throws {
        database = try Database(path: path, migrations: [.init(version: 1, sql: """
            CREATE TABLE events (id TEXT PRIMARY KEY, system TEXT NOT NULL, at INTEGER NOT NULL, is_read INTEGER NOT NULL, data TEXT NOT NULL);
            CREATE INDEX events_at ON events(at DESC);
            CREATE TABLE sources (system TEXT PRIMARY KEY, identity TEXT NOT NULL, last_check TEXT);
            """)])
    }
    public func prepare(system: String, identity: String) async throws -> String? {
        try await database.transaction { db in
            let previous = try db.query("SELECT identity,last_check FROM sources WHERE system=?", [.text(system)]).first
            if previous?["identity"]?.string == identity { return previous?["last_check"]?.string }
            try db.execute("DELETE FROM events WHERE system=?", [.text(system)])
            try db.execute("INSERT OR REPLACE INTO sources (system,identity) VALUES (?,?)", [.text(system), .text(identity)])
            return nil
        }
    }
    public func merge(_ events: [ActivityEvent], checks: [String: String]) async throws -> ActivityPoll {
        try await database.transaction { db in
            var fresh: [ActivityEvent] = []
            for event in events {
                let exists = try db.query("SELECT 1 AS found FROM events WHERE id=?", [.text(event.id)]).first != nil
                if exists { continue }
                let data = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
                let at = Int64((JiraActivity.time(event.at)?.timeIntervalSince1970 ?? 0) * 1000)
                try db.execute("INSERT INTO events (id,system,at,is_read,data) VALUES (?,?,?,?,?)", [.text(event.id), .text(event.system), .integer(at), .integer(event.read ? 1 : 0), .text(data)])
                if !event.read { fresh.append(event) }
            }
            for (system, check) in checks { try db.execute("UPDATE sources SET last_check=? WHERE system=?", [.text(check), .text(system)]) }
            try db.execute("DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY at DESC LIMIT -1 OFFSET 300)")
            return ActivityPoll(feed: try Self.feed(db), fresh: fresh)
        }
    }
    public func feed() async throws -> ActivityFeed { try await database.transaction { try Self.feed($0) } }
    public func markRead(_ ids: [String]?) async throws -> ActivityFeed {
        try await database.transaction { db in
            if let ids { for id in ids { try db.execute("UPDATE events SET is_read=1 WHERE id=?", [.text(id)]) } }
            else { try db.execute("UPDATE events SET is_read=1") }
            return try Self.feed(db)
        }
    }
    private static func feed(_ db: isolated Database) throws -> ActivityFeed {
        let events = try db.query("SELECT data,is_read FROM events ORDER BY at DESC").compactMap { row -> ActivityEvent? in
            guard let data = row["data"]?.string, var event = try? JSONDecoder().decode(ActivityEvent.self, from: Data(data.utf8)) else { return nil }
            event.read = row["is_read"]?.integer == 1; return event
        }
        let last = try db.query("SELECT last_check FROM sources WHERE system='jira'").first?["last_check"]?.string
        return ActivityFeed(events: events, unread: events.filter { !$0.read }.count, lastCheck: last)
    }
}
