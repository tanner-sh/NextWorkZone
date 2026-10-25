import Foundation
import NWZCore

extension Workspace {
    public func inbox() async throws -> [InboxEntry] {
        try await database.transaction { db in try Store.list(InboxEntry.self, table: "inbox", order: "created_at DESC", db: db) }
    }
    public func capture(title: String, body: String, url: String? = nil) async throws -> InboxEntry {
        try await database.transaction { db in
            let time = Self.now()
            let entry = InboxEntry(id: Self.newID(), kind: "capture", title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: body.trimmingCharacters(in: .whitespacesAndNewlines), url: url.flatMap { $0.isEmpty ? nil : $0 }, createdAt: time, updatedAt: time, updatedBy: self.deviceID)
            try Store.write(entry, db: db)
            return entry
        }
    }
    public func capturesToTodos() async throws -> Int {
        try await database.transaction { db in
            let entries = try Store.list(InboxEntry.self, table: "inbox", db: db).filter { $0.kind == "capture" && $0.handledAt == nil }
            for var entry in entries {
                var notes = entry.body
                if let url = entry.url, !notes.contains(url) { notes = [notes, url].filter { !$0.isEmpty }.joined(separator: "\n") }
                _ = try Self.saveTodo(.init(title: entry.title, notes: notes), device: self.deviceID, db: db)
                entry.deleted = true; entry.updatedAt = Self.stamp(entry.updatedAt); entry.updatedBy = self.deviceID
                try Store.write(entry, db: db)
            }
            return entries.count
        }
    }
    public func setInboxState(_ id: String, title: String, handledAt: Int64?, snoozeUntil: Int64?) async throws -> InboxEntry {
        try await database.transaction { db in
            let old = try Store.load(InboxEntry.self, table: "inbox", id: id, db: db)
            let time = Self.stamp(old?.updatedAt ?? 0)
            var entry = old ?? InboxEntry(id: id, kind: "state", title: title, createdAt: time)
            entry.handledAt = handledAt; entry.snoozeUntil = snoozeUntil; entry.deleted = false
            entry.updatedAt = time; entry.updatedBy = self.deviceID
            try Store.write(entry, db: db)
            return entry
        }
    }
    public func deleteInbox(_ id: String) async throws {
        try await database.transaction { db in
            guard var entry = try Store.load(InboxEntry.self, table: "inbox", id: id, db: db) else { return }
            entry.deleted = true; entry.updatedAt = Self.stamp(entry.updatedAt); entry.updatedBy = self.deviceID
            try Store.write(entry, db: db)
        }
    }
    public func takeDueAlerts(_ now: Int64) async throws -> [DueAlert] {
        try await database.transaction { db in
            var candidates: [(Int64, DueAlert)] = []
            for todo in try Store.list(Todo.self, table: "todo", db: db) where !todo.done {
                if let at = todo.remindAt, at <= now { candidates.append((at, .init(itemType: "todo", id: todo.id, title: todo.title))) }
            }
            for entry in try Store.list(InboxEntry.self, table: "inbox", db: db) where entry.handledAt == nil {
                if let at = entry.snoozeUntil, at <= now { candidates.append((at, .init(itemType: "inbox", id: entry.id, title: entry.title))) }
            }
            var alerts: [DueAlert] = []
            for (at, alert) in candidates {
                let id = alert.itemType + ":" + alert.id
                let previous = try db.query("SELECT at FROM fired_alerts WHERE id=?", [.text(id)]).first?["at"]?.integer
                if previous == at { continue }
                try db.execute("INSERT OR REPLACE INTO fired_alerts VALUES (?,?)", [.text(id), .integer(at)])
                if now - at <= 12 * 3_600_000 { alerts.append(alert) }
            }
            return alerts
        }
    }
}
