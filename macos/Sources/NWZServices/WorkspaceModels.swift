import NWZJira
import Foundation
import NWZWorkspace

public typealias ActivityEvent = NWZJira.ActivityEvent

public struct InboxMr: Codable, Hashable, Sendable {
    public var projectId: Int
    public var iid: Int
    public var reference: String
    public init(projectId: Int = 0, iid: Int = 0, reference: String = "") {
        self.projectId = projectId
        self.iid = iid
        self.reference = reference
    }
}

public struct InboxItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// activity / due / mr
    public var source: String
    public var title: String
    public var detail: String
    public var at: Int64
    public var system: String?
    public var key: String?
    public var url: String?
    public var mr: InboxMr?
    public var events: [ActivityEvent]
    public var dueKind: String?
    public var dueDays: Int?
    public var snoozeUntil: Int64?
    public init(id: String = "", source: String = "", title: String = "", detail: String = "", at: Int64 = 0, system: String? = nil, key: String? = nil, url: String? = nil, mr: InboxMr? = nil, events: [ActivityEvent] = [], dueKind: String? = nil, dueDays: Int? = nil, snoozeUntil: Int64? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.detail = detail
        self.at = at
        self.system = system
        self.key = key
        self.url = url
        self.mr = mr
        self.events = events
        self.dueKind = dueKind
        self.dueDays = dueDays
        self.snoozeUntil = snoozeUntil
    }
}

public struct InboxView: Codable, Hashable, Sendable {
    public var items: [InboxItem]
    public var snoozed: [InboxItem]
    public var notes: [String]
    public init(items: [InboxItem] = [], snoozed: [InboxItem] = [], notes: [String] = []) {
        self.items = items
        self.snoozed = snoozed
        self.notes = notes
    }
}

public struct InboxHandleInput: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var eventIds: [String]?
    public init(id: String = "", title: String = "", eventIds: [String]? = nil) {
        self.id = id
        self.title = title
        self.eventIds = eventIds
    }
}

public struct WorkEvent: Codable, Hashable, Sendable {
    public var at: Int64
    /// jira / gitlab / wiki / todo
    public var system: String
    public var kind: String
    public var title: String
    public var key: String?
    public var detail: String
    public var projectId: Int?
    public init(at: Int64 = 0, system: String = "", kind: String = "", title: String = "", key: String? = nil, detail: String = "", projectId: Int? = nil) {
        self.at = at
        self.system = system
        self.kind = kind
        self.title = title
        self.key = key
        self.detail = detail
        self.projectId = projectId
    }
}

public struct WorkLog: Codable, Hashable, Sendable {
    public var day: String
    public var events: [WorkEvent]
    public var notes: [String]
    public init(day: String = "", events: [WorkEvent] = [], notes: [String] = []) {
        self.day = day
        self.events = events
        self.notes = notes
    }
}

public struct WorkspaceSettings: Codable, Hashable, Sendable {
    public var syncDir: String
    public var jiraTodos: Bool
    public var deviceId: String
    public var lastSync: SyncReport?
    public var lastError: String?
    public var captureShortcut: String
    public var captureError: String?
    public init(syncDir: String = "", jiraTodos: Bool = false, deviceId: String = "", lastSync: SyncReport? = nil, lastError: String? = nil, captureShortcut: String = "", captureError: String? = nil) {
        self.syncDir = syncDir
        self.jiraTodos = jiraTodos
        self.deviceId = deviceId
        self.lastSync = lastSync
        self.lastError = lastError
        self.captureShortcut = captureShortcut
        self.captureError = captureError
    }
}

