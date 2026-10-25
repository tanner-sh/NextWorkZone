import Foundation

public struct OutlineItem: Codable, Hashable, Sendable {
    public init(level: Int = 0, text: String = "") {
        self.level = level; self.text = text
    }
    public var level: Int
    public var text: String
}

public struct SectionInfo: Codable, Hashable, Sendable {
    public init(title: String = "", coversToday: Bool = false) {
        self.title = title; self.coversToday = coversToday
    }
    public var title: String
    public var coversToday: Bool
}

public struct WeekEntry: Codable, Hashable, Sendable {
    public init(sectionTitle: String = "", rowFound: Bool = false, content: [OutlineItem] = [], risk: [OutlineItem] = [], contentRaw: String = "", riskRaw: String = "", lossy: Bool = false) {
        self.sectionTitle = sectionTitle; self.rowFound = rowFound; self.content = content; self.risk = risk; self.contentRaw = contentRaw; self.riskRaw = riskRaw; self.lossy = lossy
    }
    public var sectionTitle: String
    public var rowFound: Bool
    public var content: [OutlineItem]
    public var risk: [OutlineItem]
    public var contentRaw: String
    public var riskRaw: String
    public var lossy: Bool
}

public struct WeeklyView: Codable, Hashable, Sendable {
    public init(pageId: String = "", pageTitle: String = "", pageUrl: String = "", version: Int = 0, modifiedBy: String = "", modifiedAt: String = "", personName: String = "", sections: [SectionInfo] = [], currentWeekTitle: String = "", currentWeekExists: Bool = false, entry: WeekEntry? = nil) {
        self.pageId = pageId; self.pageTitle = pageTitle; self.pageUrl = pageUrl; self.version = version; self.modifiedBy = modifiedBy; self.modifiedAt = modifiedAt; self.personName = personName; self.sections = sections; self.currentWeekTitle = currentWeekTitle; self.currentWeekExists = currentWeekExists; self.entry = entry
    }
    public var pageId: String
    public var pageTitle: String
    public var pageUrl: String
    public var version: Int
    public var modifiedBy: String
    public var modifiedAt: String
    public var personName: String
    public var sections: [SectionInfo]
    public var currentWeekTitle: String
    public var currentWeekExists: Bool
    public var entry: WeekEntry?
}

public struct SaveResult: Codable, Hashable, Sendable {
    public init(changed: Bool = false, version: Int = 0) {
        self.changed = changed; self.version = version
    }
    public var changed: Bool
    public var version: Int
}

public struct DraftItem: Codable, Hashable, Sendable {
    public init(text: String = "", key: String? = nil, evidence: [String] = [], lastWeek: String? = nil) {
        self.text = text; self.key = key; self.evidence = evidence; self.lastWeek = lastWeek
    }
    public var text: String
    public var key: String?
    public var evidence: [String]
    public var lastWeek: String?
}

public struct DraftGroup: Codable, Hashable, Sendable {
    public init(title: String = "", source: String = "", items: [DraftItem] = []) {
        self.title = title; self.source = source; self.items = items
    }
    public var title: String
    /// jira / worklog / gitlab / wiki / todo / daily
    public var source: String
    public var items: [DraftItem]
}

public struct CarryOver: Codable, Hashable, Sendable {
    public init(group: String = "", text: String = "", progress: String? = nil, thisWeek: String? = nil) {
        self.group = group; self.text = text; self.progress = progress; self.thisWeek = thisWeek
    }
    public var group: String
    public var text: String
    public var progress: String?
    public var thisWeek: String?
}

public struct WeeklyDraft: Codable, Hashable, Sendable {
    public init(from: String = "", to: String = "", groups: [DraftGroup] = [], carryOver: [CarryOver] = [], lastWeekTitle: String? = nil, separator: String = "", notes: [String] = []) {
        self.from = from; self.to = to; self.groups = groups; self.carryOver = carryOver; self.lastWeekTitle = lastWeekTitle; self.separator = separator; self.notes = notes
    }
    public var from: String
    public var to: String
    public var groups: [DraftGroup]
    public var carryOver: [CarryOver]
    public var lastWeekTitle: String?
    public var separator: String
    public var notes: [String]
}

public struct WeeklySaveInput: Codable, Hashable, Sendable {
    public init(section: String = "", contentRaw: String = "", riskRaw: String = "", content: [OutlineItem] = [], risk: [OutlineItem] = []) {
        self.section = section; self.contentRaw = contentRaw; self.riskRaw = riskRaw; self.content = content; self.risk = risk
    }
    public var section: String
    public var contentRaw: String
    public var riskRaw: String
    public var content: [OutlineItem]
    public var risk: [OutlineItem]
}

public struct WikiSpace: Codable, Hashable, Sendable, Identifiable {
    public init(key: String = "", name: String = "", homepageId: String? = nil, description: String = "") {
        self.key = key; self.name = name; self.homepageId = homepageId; self.description = description
    }
    public var key: String
    public var name: String
    public var homepageId: String?
    public var description: String
    public var id: String { key }
}

public struct WikiNode: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", title: String = "", hasChildren: Bool = false) {
        self.id = id; self.title = title; self.hasChildren = hasChildren
    }
    public var id: String
    public var title: String
    public var hasChildren: Bool
}

public struct WikiAncestor: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", title: String = "") {
        self.id = id; self.title = title
    }
    public var id: String
    public var title: String
}

public struct WikiPageDetail: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", kind: String = "", title: String = "", spaceKey: String = "", spaceName: String = "", version: Int = 0, modifiedBy: String = "", modified: String = "", versionMessage: String = "", createdBy: String = "", created: String = "", ancestors: [WikiAncestor] = [], labels: [String] = [], html: String = "", url: String = "", canEdit: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.spaceKey = spaceKey; self.spaceName = spaceName; self.version = version; self.modifiedBy = modifiedBy; self.modified = modified; self.versionMessage = versionMessage; self.createdBy = createdBy; self.created = created; self.ancestors = ancestors; self.labels = labels; self.html = html; self.url = url; self.canEdit = canEdit
    }
    public var id: String
    /// page / blogpost
    public var kind: String
    public var title: String
    public var spaceKey: String
    public var spaceName: String
    public var version: Int
    public var modifiedBy: String
    public var modified: String
    public var versionMessage: String
    public var createdBy: String
    public var created: String
    public var ancestors: [WikiAncestor]
    public var labels: [String]
    public var html: String
    public var url: String
    public var canEdit: Bool
}

public struct WikiRecent: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", title: String = "", space: String = "", at: Int64 = 0, source: String = "") {
        self.id = id; self.title = title; self.space = space; self.at = at; self.source = source
    }
    public var id: String
    public var title: String
    public var space: String
    public var at: Int64
    /// app / web
    public var source: String
}

public struct WikiVersion: Codable, Hashable, Sendable, Identifiable {
    public init(number: Int = 0, by: String = "", when: String = "", message: String = "", minorEdit: Bool = false) {
        self.number = number; self.by = by; self.when = when; self.message = message; self.minorEdit = minorEdit
    }
    public var number: Int
    public var by: String
    public var when: String
    public var message: String
    public var minorEdit: Bool
    public var id: Int { number }
}

public struct WikiComment: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", author: String = "", created: String = "", html: String = "", parentId: String? = nil, inlineText: String? = nil, version: Int = 0) {
        self.id = id; self.author = author; self.created = created; self.html = html; self.parentId = parentId; self.inlineText = inlineText; self.version = version
    }
    public var id: String
    public var author: String
    public var created: String
    public var html: String
    public var parentId: String?
    public var inlineText: String?
    public var version: Int
}

public struct WikiPageHit: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", kind: String = "", title: String = "", spaceKey: String = "", spaceName: String = "", ancestors: [WikiAncestor] = [], authorName: String = "", modified: String = "", snippet: String = "") {
        self.id = id; self.kind = kind; self.title = title; self.spaceKey = spaceKey; self.spaceName = spaceName; self.ancestors = ancestors; self.authorName = authorName; self.modified = modified; self.snippet = snippet
    }
    public var id: String
    public var kind: String
    public var title: String
    public var spaceKey: String
    public var spaceName: String
    public var ancestors: [WikiAncestor]
    public var authorName: String
    public var modified: String
    public var snippet: String
}

public struct WikiQuery: Codable, Hashable, Sendable {
    public init(text: String = "", space: String? = nil, mine: Bool? = nil, days: Int? = nil, kind: String? = nil, limit: Int? = nil) {
        self.text = text; self.space = space; self.mine = mine; self.days = days; self.kind = kind; self.limit = limit
    }
    public var text: String
    public var space: String?
    public var mine: Bool?
    public var days: Int?
    public var kind: String?
    public var limit: Int?
}

public struct WikiSearchResult: Codable, Hashable, Sendable {
    public init(source: String = "", total: Int = 0, hits: [WikiPageHit] = []) {
        self.source = source; self.total = total; self.hits = hits
    }
    /// local / server
    public var source: String
    public var total: Int
    public var hits: [WikiPageHit]
}

public struct WikiTemplate: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", name: String = "", description: String = "", spaceKey: String? = nil) {
        self.id = id; self.name = name; self.description = description; self.spaceKey = spaceKey
    }
    public var id: String
    public var name: String
    public var description: String
    public var spaceKey: String?
}

public struct WikiEditSession: Codable, Hashable, Sendable {
    public init(pageId: String? = nil, title: String = "", spaceKey: String = "", version: Int = 0, html: String = "", fragments: [String] = [], users: [String] = []) {
        self.pageId = pageId; self.title = title; self.spaceKey = spaceKey; self.version = version; self.html = html; self.fragments = fragments; self.users = users
    }
    public var pageId: String?
    public var title: String
    public var spaceKey: String
    public var version: Int
    public var html: String
    public var fragments: [String]
    public var users: [String]
}

public struct WikiSavePreview: Codable, Hashable, Sendable {
    public init(storage: String = "", diff: String = "", changed: Bool = false) {
        self.storage = storage; self.diff = diff; self.changed = changed
    }
    public var storage: String
    public var diff: String
    public var changed: Bool
}

public struct WikiIndexSpace: Codable, Hashable, Sendable, Identifiable {
    public init(key: String = "", name: String = "", count: Int = 0) {
        self.key = key; self.name = name; self.count = count
    }
    public var key: String
    public var name: String
    public var count: Int
    public var id: String { key }
}

public struct WikiIndexProgress: Codable, Hashable, Sendable {
    public init(done: Int = 0, total: Int = 0) {
        self.done = done; self.total = total
    }
    public var done: Int
    public var total: Int
}

public struct WikiIndexStatus: Codable, Hashable, Sendable {
    public init(enabled: Bool = false, count: Int = 0, spaces: [WikiIndexSpace] = [], lastSync: String? = nil, running: Bool = false, progress: WikiIndexProgress? = nil, error: String? = nil) {
        self.enabled = enabled; self.count = count; self.spaces = spaces; self.lastSync = lastSync; self.running = running; self.progress = progress; self.error = error
    }
    public var enabled: Bool
    public var count: Int
    public var spaces: [WikiIndexSpace]
    public var lastSync: String?
    public var running: Bool
    public var progress: WikiIndexProgress?
    public var error: String?
}

public struct WikiToolsSettings: Codable, Hashable, Sendable {
    public init(indexEnabled: Bool = false, indexSpaces: [String] = [], taskTodos: Bool = false, activity: Bool = false, mutedPages: [String] = []) {
        self.indexEnabled = indexEnabled; self.indexSpaces = indexSpaces; self.taskTodos = taskTodos; self.activity = activity; self.mutedPages = mutedPages
    }
    public var indexEnabled: Bool
    public var indexSpaces: [String]
    public var taskTodos: Bool
    public var activity: Bool
    public var mutedPages: [String]
}

public struct WikiPageVersionInfo: Codable, Hashable, Sendable {
    public init(title: String = "", version: Int = 0, by: String = "", when: String = "") {
        self.title = title; self.version = version; self.by = by; self.when = when
    }
    public var title: String
    public var version: Int
    public var by: String
    public var when: String
}

public struct WikiHit: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", title: String = "", space: String = "", url: String = "", excerpt: String = "") {
        self.id = id; self.title = title; self.space = space; self.url = url; self.excerpt = excerpt
    }
    public var id: String
    public var title: String
    public var space: String
    public var url: String
    public var excerpt: String
}
