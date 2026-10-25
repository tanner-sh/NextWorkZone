import Foundation

public struct ActivityEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var issueKey: String
    public var issueSummary: String
    public var issueTypeIcon: String?
    public var kind: String
    public var actor: String
    public var at: String
    public var text: String
    public var read: Bool
    /// jira / wiki
    public var system: String
    public init(id: String = "", issueKey: String = "", issueSummary: String = "", issueTypeIcon: String? = nil, kind: String = "", actor: String = "", at: String = "", text: String = "", read: Bool = false, system: String = "") {
        self.id = id
        self.issueKey = issueKey
        self.issueSummary = issueSummary
        self.issueTypeIcon = issueTypeIcon
        self.kind = kind
        self.actor = actor
        self.at = at
        self.text = text
        self.read = read
        self.system = system
    }
}

public struct ActivityFeed: Codable, Hashable, Sendable {
    public var events: [ActivityEvent]
    public var unread: Int
    public var lastCheck: String?
    public init(events: [ActivityEvent], unread: Int, lastCheck: String? = nil) { self.events = events; self.unread = unread; self.lastCheck = lastCheck }
}
public struct ActivityPoll: Codable, Hashable, Sendable {
    public var feed: ActivityFeed
    public var fresh: [ActivityEvent]
    public init(feed: ActivityFeed, fresh: [ActivityEvent]) { self.feed = feed; self.fresh = fresh }
}
public struct MyAction: Codable, Hashable, Sendable {
    public var at: String
    public var kind: String
    public var key: String
    public var summary: String
    public var detail: String
}
