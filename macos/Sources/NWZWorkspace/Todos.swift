import Foundation
import NWZCore

extension Workspace {
    public func todos() async throws -> [Todo] {
        try await database.transaction { db in try Store.list(Todo.self, table: "todo", order: "done,sort,created_at", db: db) }
    }
    public func todo(_ id: String) async throws -> Todo? {
        try await database.transaction { db in try Store.load(Todo.self, table: "todo", id: id, db: db) }
    }
    public func saveTodo(_ input: TodoInput) async throws -> Todo {
        try await database.transaction { db in try Self.saveTodo(input, device: self.deviceID, db: db) }
    }
    static func saveTodo(_ input: TodoInput, device: String, db: isolated Database) throws -> Todo {
        let old = try input.id.flatMap { try Store.load(Todo.self, table: "todo", id: $0, db: db) }
        let time = stamp(old?.updatedAt ?? 0)
        var todo = try old ?? Todo(id: input.id ?? newID(), sort: Store.sort("todo", db: db), createdAt: time)
        todo.title = input.title; todo.notes = input.notes; todo.done = input.done
        todo.completedAt = input.done ? (old?.completedAt ?? time) : nil
        todo.due = input.due.flatMap { $0.isEmpty ? nil : $0 }; todo.priority = input.priority
        todo.refSystem = input.refSystem; todo.refKey = input.refKey; todo.refTitle = input.refTitle
        todo.autoDone = (old?.autoDone ?? false) && old?.done == input.done
        todo.remindAt = input.remindAt; todo.repeat = input.repeat.flatMap { $0.isEmpty ? nil : $0 }; todo.checklist = input.checklist
        todo.updatedAt = time; todo.updatedBy = device
        return try finish(todo, wasDone: old?.done ?? false, device: device, db: db)
    }
    private static func finish(_ value: Todo, wasDone: Bool, device: String, db: isolated Database) throws -> Todo {
        var todo = value
        if let rule = todo.repeat, todo.done && !wasDone && !todo.deleted, let due = nextOccurrence(todo.due, rule, today()) {
            var following = todo
            following.id = newID(); following.done = false; following.completedAt = nil; following.autoDone = false
            following.due = due; following.source = nil; following.createdAt = stamp(todo.updatedAt); following.updatedAt = following.createdAt; following.updatedBy = device
            if let previous = todo.due.flatMap(parseDay), let next = parseDay(due), let reminder = todo.remindAt {
                following.remindAt = reminder + Int64(next.timeIntervalSince(previous) / 86_400) * 86_400_000
            }
            following.checklist = todo.checklist.map { .init(id: $0.id, text: $0.text, done: false) }
            try Store.write(following, db: db)
            todo.repeat = nil
        }
        try Store.write(todo, db: db)
        return todo
    }
    public func setTodoDone(_ id: String, done: Bool) async throws -> Todo {
        try await database.transaction { db in
            guard var todo = try Store.load(Todo.self, table: "todo", id: id, db: db) else { throw NWZError.other("待办不存在") }
            let wasDone = todo.done
            todo.done = done; todo.updatedAt = Self.stamp(todo.updatedAt); todo.updatedBy = self.deviceID
            todo.completedAt = done ? todo.updatedAt : nil; todo.autoDone = false
            return try Self.finish(todo, wasDone: wasDone, device: self.deviceID, db: db)
        }
    }
    public func moveTodo(_ id: String, sort: Double) async throws {
        try await database.transaction { db in
            guard var todo = try Store.load(Todo.self, table: "todo", id: id, db: db) else { throw NWZError.other("待办不存在") }
            todo.sort = sort; todo.updatedAt = Self.stamp(todo.updatedAt); todo.updatedBy = self.deviceID
            try Store.write(todo, db: db)
        }
    }
    public func deleteTodo(_ id: String) async throws {
        try await database.transaction { db in
            guard var todo = try Store.load(Todo.self, table: "todo", id: id, db: db) else { return }
            todo.deleted = true; todo.updatedAt = Self.stamp(todo.updatedAt); todo.updatedBy = self.deviceID
            try Store.write(todo, db: db)
        }
    }

    private struct SourceTodo: Sendable {
        var id: String, key: String, reference: String, title: String
        var due: String?
    }
    public func syncJiraTodos(_ issues: [AssignedIssue]) async throws -> JiraTodoSync {
        try await syncSource("jira", items: issues.map { .init(id: "jira-" + $0.key, key: $0.key, reference: $0.summary, title: $0.summary, due: $0.due) })
    }
    public func syncWikiTodos(_ tasks: [AssignedWikiTask]) async throws -> JiraTodoSync {
        try await syncSource("wiki", items: tasks.map { .init(id: "wiki-\($0.pageId)-\($0.taskId)", key: $0.pageId, reference: $0.pageTitle, title: $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.pageTitle : $0.text, due: $0.due) })
    }
    private func syncSource(_ source: String, items: [SourceTodo]) async throws -> JiraTodoSync {
        try await database.transaction { db in
            var report = JiraTodoSync()
            for item in items {
                let old = try Store.load(Todo.self, table: "todo", id: item.id, db: db)
                if old?.deleted == true { continue }
                if var todo = old {
                    let reopen = todo.done && todo.autoDone
                    let title = source == "jira" && todo.refTitle == todo.title ? item.title : todo.title
                    if reopen || title != todo.title || todo.refTitle != item.reference {
                        todo.title = title; todo.refTitle = item.reference
                        if reopen { todo.done = false; todo.completedAt = nil; todo.autoDone = false; report.reopened += 1 }
                        todo.updatedAt = Self.stamp(todo.updatedAt); todo.updatedBy = self.deviceID
                        try Store.write(todo, db: db)
                    }
                } else {
                    let time = Self.now()
                    let todo = Todo(id: item.id, title: item.title, due: item.due, sort: try Store.sort("todo", db: db), refSystem: source, refKey: item.key, refTitle: item.reference, source: source, createdAt: time, updatedAt: time, updatedBy: self.deviceID)
                    try Store.write(todo, db: db); report.added += 1
                }
            }
            let current = Set(items.map(\.id))
            for var todo in try Store.list(Todo.self, table: "todo", db: db) where todo.source == source && !todo.done && !current.contains(todo.id) {
                todo.done = true; todo.autoDone = true; todo.updatedAt = Self.stamp(todo.updatedAt); todo.updatedBy = self.deviceID; todo.completedAt = todo.updatedAt
                try Store.write(todo, db: db); report.completed += 1
            }
            return report
        }
    }
}
