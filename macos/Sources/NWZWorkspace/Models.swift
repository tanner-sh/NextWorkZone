import Foundation

public struct Todo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var notes: String
    public var done: Bool
    public var completedAt: Int64?
    public var due: String?
    public var priority: Int
    public var sort: Double
    public var refSystem: String?
    public var refKey: String?
    public var refTitle: String?
    public var source: String?
    public var autoDone: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public var updatedBy: String
    public var deleted: Bool
    public var remindAt: Int64?
    public var `repeat`: String?
    public var checklist: [ChecklistItem]
    /// 重复的待办完成时生成的下一次；标记为未完成时据此撤回
    public var nextId: String?
    /// 自动同步的待办上次从来源取到的标题、截止日期（"" 表示没有）：待办的值与之相同说明没有手动改过，来源变化时跟着更新
    public var sourceTitle: String?
    public var sourceDue: String?
    public init(id: String = "", title: String = "", notes: String = "", done: Bool = false, completedAt: Int64? = nil, due: String? = nil, priority: Int = 0, sort: Double = 0, refSystem: String? = nil, refKey: String? = nil, refTitle: String? = nil, source: String? = nil, autoDone: Bool = false, createdAt: Int64 = 0, updatedAt: Int64 = 0, updatedBy: String = "", deleted: Bool = false, remindAt: Int64? = nil, `repeat`: String? = nil, checklist: [ChecklistItem] = [], nextId: String? = nil, sourceTitle: String? = nil, sourceDue: String? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.done = done
        self.completedAt = completedAt
        self.due = due
        self.priority = priority
        self.sort = sort
        self.refSystem = refSystem
        self.refKey = refKey
        self.refTitle = refTitle
        self.source = source
        self.autoDone = autoDone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deleted = deleted
        self.remindAt = remindAt
        self.`repeat` = `repeat`
        self.checklist = checklist
        self.nextId = nextId
        self.sourceTitle = sourceTitle
        self.sourceDue = sourceDue
    }
    private enum CodingKeys: String, CodingKey { case id, title, notes, done, completedAt, due, priority, sort, refSystem, refKey, refTitle, source, autoDone, createdAt, updatedAt, updatedBy, deleted, remindAt, `repeat`, checklist, nextId, sourceTitle, sourceDue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        completedAt = try c.decodeIfPresent(Int64.self, forKey: .completedAt)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        sort = try c.decodeIfPresent(Double.self, forKey: .sort) ?? 0
        refSystem = try c.decodeIfPresent(String.self, forKey: .refSystem)
        refKey = try c.decodeIfPresent(String.self, forKey: .refKey)
        refTitle = try c.decodeIfPresent(String.self, forKey: .refTitle)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        autoDone = try c.decodeIfPresent(Bool.self, forKey: .autoDone) ?? false
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        remindAt = try c.decodeIfPresent(Int64.self, forKey: .remindAt)
        `repeat` = try c.decodeIfPresent(String.self, forKey: .`repeat`)
        checklist = try c.decodeIfPresent([ChecklistItem].self, forKey: .checklist) ?? []
        nextId = try c.decodeIfPresent(String.self, forKey: .nextId)
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle)
        sourceDue = try c.decodeIfPresent(String.self, forKey: .sourceDue)
    }
}

public struct ChecklistItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var done: Bool
    public init(id: String = "", text: String = "", done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
    private enum CodingKeys: String, CodingKey { case id, text, done }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

public struct TodoInput: Codable, Hashable, Sendable, Identifiable {
    public var id: String?
    public var title: String
    public var notes: String
    public var done: Bool
    public var due: String?
    public var priority: Int
    public var refSystem: String?
    public var refKey: String?
    public var refTitle: String?
    public var remindAt: Int64?
    public var `repeat`: String?
    public var checklist: [ChecklistItem]
    public init(id: String? = nil, title: String = "", notes: String = "", done: Bool = false, due: String? = nil, priority: Int = 0, refSystem: String? = nil, refKey: String? = nil, refTitle: String? = nil, remindAt: Int64? = nil, `repeat`: String? = nil, checklist: [ChecklistItem] = []) {
        self.id = id
        self.title = title
        self.notes = notes
        self.done = done
        self.due = due
        self.priority = priority
        self.refSystem = refSystem
        self.refKey = refKey
        self.refTitle = refTitle
        self.remindAt = remindAt
        self.`repeat` = `repeat`
        self.checklist = checklist
    }
    private enum CodingKeys: String, CodingKey { case id, title, notes, done, due, priority, refSystem, refKey, refTitle, remindAt, `repeat`, checklist }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        due = try c.decodeIfPresent(String.self, forKey: .due)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        refSystem = try c.decodeIfPresent(String.self, forKey: .refSystem)
        refKey = try c.decodeIfPresent(String.self, forKey: .refKey)
        refTitle = try c.decodeIfPresent(String.self, forKey: .refTitle)
        remindAt = try c.decodeIfPresent(Int64.self, forKey: .remindAt)
        `repeat` = try c.decodeIfPresent(String.self, forKey: .`repeat`)
        checklist = try c.decodeIfPresent([ChecklistItem].self, forKey: .checklist) ?? []
    }
}

public struct InboxEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var body: String
    public var url: String?
    public var handledAt: Int64?
    public var snoozeUntil: Int64?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var updatedBy: String
    public var deleted: Bool
    public init(id: String = "", kind: String = "", title: String = "", body: String = "", url: String? = nil, handledAt: Int64? = nil, snoozeUntil: Int64? = nil, createdAt: Int64 = 0, updatedAt: Int64 = 0, updatedBy: String = "", deleted: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
        self.handledAt = handledAt
        self.snoozeUntil = snoozeUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deleted = deleted
    }
    private enum CodingKeys: String, CodingKey { case id, kind, title, body, url, handledAt, snoozeUntil, createdAt, updatedAt, updatedBy, deleted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        handledAt = try c.decodeIfPresent(Int64.self, forKey: .handledAt)
        snoozeUntil = try c.decodeIfPresent(Int64.self, forKey: .snoozeUntil)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

public struct DueAlert: Codable, Hashable, Sendable, Identifiable {
    public var itemType: String
    public var id: String
    public var title: String
    public init(itemType: String = "", id: String = "", title: String = "") {
        self.itemType = itemType
        self.id = id
        self.title = title
    }
    private enum CodingKeys: String, CodingKey { case itemType, id, title }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemType = try c.decodeIfPresent(String.self, forKey: .itemType) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    }
}

public struct Doc: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var content: String
    public var parentId: String?
    public var sort: Double
    public var tags: [String]
    public var day: String?
    public var pinned: Bool
    public var sourceSystem: String?
    public var sourceKey: String?
    public var sourceUrl: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var updatedBy: String
    public var baseAt: Int64
    public var deleted: Bool
    public var publishedUrl: String?
    public init(id: String = "", kind: String = "", title: String = "", content: String = "", parentId: String? = nil, sort: Double = 0, tags: [String] = [], day: String? = nil, pinned: Bool = false, sourceSystem: String? = nil, sourceKey: String? = nil, sourceUrl: String? = nil, createdAt: Int64 = 0, updatedAt: Int64 = 0, updatedBy: String = "", baseAt: Int64 = 0, deleted: Bool = false, publishedUrl: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.parentId = parentId
        self.sort = sort
        self.tags = tags
        self.day = day
        self.pinned = pinned
        self.sourceSystem = sourceSystem
        self.sourceKey = sourceKey
        self.sourceUrl = sourceUrl
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.baseAt = baseAt
        self.deleted = deleted
        self.publishedUrl = publishedUrl
    }
    private enum CodingKeys: String, CodingKey { case id, kind, title, content, parentId, sort, tags, day, pinned, sourceSystem, sourceKey, sourceUrl, createdAt, updatedAt, updatedBy, baseAt, deleted, publishedUrl }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        sort = try c.decodeIfPresent(Double.self, forKey: .sort) ?? 0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        day = try c.decodeIfPresent(String.self, forKey: .day)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        sourceSystem = try c.decodeIfPresent(String.self, forKey: .sourceSystem)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
        baseAt = try c.decodeIfPresent(Int64.self, forKey: .baseAt) ?? 0
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        publishedUrl = try c.decodeIfPresent(String.self, forKey: .publishedUrl)
    }
}

public struct DocSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var excerpt: String
    public var parentId: String?
    public var sort: Double
    public var tags: [String]
    public var day: String?
    public var pinned: Bool
    public var sourceSystem: String?
    public var sourceKey: String?
    public var publishedUrl: String?
    public var updatedAt: Int64
    public init(id: String = "", kind: String = "", title: String = "", excerpt: String = "", parentId: String? = nil, sort: Double = 0, tags: [String] = [], day: String? = nil, pinned: Bool = false, sourceSystem: String? = nil, sourceKey: String? = nil, publishedUrl: String? = nil, updatedAt: Int64 = 0) {
        self.id = id
        self.kind = kind
        self.title = title
        self.excerpt = excerpt
        self.parentId = parentId
        self.sort = sort
        self.tags = tags
        self.day = day
        self.pinned = pinned
        self.sourceSystem = sourceSystem
        self.sourceKey = sourceKey
        self.publishedUrl = publishedUrl
        self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case id, kind, title, excerpt, parentId, sort, tags, day, pinned, sourceSystem, sourceKey, publishedUrl, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        sort = try c.decodeIfPresent(Double.self, forKey: .sort) ?? 0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        day = try c.decodeIfPresent(String.self, forKey: .day)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        sourceSystem = try c.decodeIfPresent(String.self, forKey: .sourceSystem)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        publishedUrl = try c.decodeIfPresent(String.self, forKey: .publishedUrl)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }
}

public struct DocInput: Codable, Hashable, Sendable, Identifiable {
    public var id: String?
    public var kind: String
    public var title: String
    public var content: String
    public var parentId: String?
    public var tags: [String]
    public var pinned: Bool
    public var sourceSystem: String?
    public var sourceKey: String?
    public var sourceUrl: String?
    public var publishedUrl: String?
    public init(id: String? = nil, kind: String = "", title: String = "", content: String = "", parentId: String? = nil, tags: [String] = [], pinned: Bool = false, sourceSystem: String? = nil, sourceKey: String? = nil, sourceUrl: String? = nil, publishedUrl: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.parentId = parentId
        self.tags = tags
        self.pinned = pinned
        self.sourceSystem = sourceSystem
        self.sourceKey = sourceKey
        self.sourceUrl = sourceUrl
        self.publishedUrl = publishedUrl
    }
    private enum CodingKeys: String, CodingKey { case id, kind, title, content, parentId, tags, pinned, sourceSystem, sourceKey, sourceUrl, publishedUrl }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        sourceSystem = try c.decodeIfPresent(String.self, forKey: .sourceSystem)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        publishedUrl = try c.decodeIfPresent(String.self, forKey: .publishedUrl)
    }
}

public struct Backlink: Codable, Hashable, Sendable, Identifiable {
    public var itemType: String
    public var id: String
    public var kind: String
    public var title: String
    public var done: Bool
    public var updatedAt: Int64
    public init(itemType: String = "", id: String = "", kind: String = "", title: String = "", done: Bool = false, updatedAt: Int64 = 0) {
        self.itemType = itemType
        self.id = id
        self.kind = kind
        self.title = title
        self.done = done
        self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case itemType, id, kind, title, done, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemType = try c.decodeIfPresent(String.self, forKey: .itemType) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }
}

public struct SearchHit: Codable, Hashable, Sendable, Identifiable {
    public var itemType: String
    public var id: String
    public var kind: String
    public var title: String
    public var snippet: String
    public var done: Bool
    public init(itemType: String = "", id: String = "", kind: String = "", title: String = "", snippet: String = "", done: Bool = false) {
        self.itemType = itemType
        self.id = id
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.done = done
    }
    private enum CodingKeys: String, CodingKey { case itemType, id, kind, title, snippet, done }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemType = try c.decodeIfPresent(String.self, forKey: .itemType) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

public struct AssetMeta: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var mime: String
    public var createdAt: Int64
    public init(id: String = "", mime: String = "", createdAt: Int64 = 0) {
        self.id = id
        self.mime = mime
        self.createdAt = createdAt
    }
    private enum CodingKeys: String, CodingKey { case id, mime, createdAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
    }
}

public struct SyncReport: Codable, Hashable, Sendable {
    public var exported: Int
    public var imported: Int
    public var conflicts: Int
    public var devices: Int
    public var finishedAt: Int64
    public init(exported: Int = 0, imported: Int = 0, conflicts: Int = 0, devices: Int = 0, finishedAt: Int64 = 0) {
        self.exported = exported
        self.imported = imported
        self.conflicts = conflicts
        self.devices = devices
        self.finishedAt = finishedAt
    }
    private enum CodingKeys: String, CodingKey { case exported, imported, conflicts, devices, finishedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exported = try c.decodeIfPresent(Int.self, forKey: .exported) ?? 0
        imported = try c.decodeIfPresent(Int.self, forKey: .imported) ?? 0
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        devices = try c.decodeIfPresent(Int.self, forKey: .devices) ?? 0
        finishedAt = try c.decodeIfPresent(Int64.self, forKey: .finishedAt) ?? 0
    }
}

public struct JiraTodoSync: Codable, Hashable, Sendable {
    public var added: Int
    public var completed: Int
    public var reopened: Int
    public init(added: Int = 0, completed: Int = 0, reopened: Int = 0) {
        self.added = added
        self.completed = completed
        self.reopened = reopened
    }
    private enum CodingKeys: String, CodingKey { case added, completed, reopened }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        completed = try c.decodeIfPresent(Int.self, forKey: .completed) ?? 0
        reopened = try c.decodeIfPresent(Int.self, forKey: .reopened) ?? 0
    }
}

public struct AssignedIssue: Codable, Hashable, Sendable {
    public var key: String
    public var summary: String
    public var due: String?
    public init(key: String = "", summary: String = "", due: String? = nil) {
        self.key = key
        self.summary = summary
        self.due = due
    }
    private enum CodingKeys: String, CodingKey { case key, summary, due }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due)
    }
}

public struct AssignedWikiTask: Codable, Hashable, Sendable {
    public var pageId: String
    public var pageTitle: String
    public var taskId: String
    public var text: String
    public var due: String?
    public init(pageId: String = "", pageTitle: String = "", taskId: String = "", text: String = "", due: String? = nil) {
        self.pageId = pageId
        self.pageTitle = pageTitle
        self.taskId = taskId
        self.text = text
        self.due = due
    }
    private enum CodingKeys: String, CodingKey { case pageId, pageTitle, taskId, text, due }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageId = try c.decodeIfPresent(String.self, forKey: .pageId) ?? ""
        pageTitle = try c.decodeIfPresent(String.self, forKey: .pageTitle) ?? ""
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due)
    }
}

extension TodoInput {
    public init(_ todo: Todo) {
        self.init(id: todo.id, title: todo.title, notes: todo.notes, done: todo.done, due: todo.due, priority: todo.priority, refSystem: todo.refSystem, refKey: todo.refKey, refTitle: todo.refTitle, remindAt: todo.remindAt, repeat: todo.repeat, checklist: todo.checklist)
    }
}

public struct TagCount: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var count: Int
    public var id: String { name }
    public init(name: String, count: Int) { self.name = name; self.count = count }
}
