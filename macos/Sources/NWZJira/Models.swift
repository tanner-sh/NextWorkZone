import Foundation
import NWZCore

public struct JiraStatus: Codable, Hashable, Sendable {
    public var name: String
    /// new / indeterminate / done
    public var category: String
    public init(name: String, category: String) {
        self.name = name
        self.category = category
    }
}

public struct Named: Codable, Hashable, Sendable {
    public var name: String
    public var iconUrl: String?
    public init(name: String, iconUrl: String? = nil) {
        self.name = name
        self.iconUrl = iconUrl
    }
}

public struct IssueSummary: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var summary: String
    public var status: JiraStatus
    public var issueType: Named
    public var priority: Named?
    public var project: Named
    public var assignee: String?
    public var assigneeName: String?
    public var reporter: String?
    public var reporterName: String?
    public var lastViewed: String?
    public var resolution: String?
    public var created: String
    public var updated: String
    public var dueDate: String?
    public var extra: [String: String]?
    public var id: String { key }
    public init(key: String, summary: String, status: JiraStatus, issueType: Named, priority: Named? = nil, project: Named, assignee: String? = nil, assigneeName: String? = nil, reporter: String? = nil, reporterName: String? = nil, lastViewed: String? = nil, resolution: String? = nil, created: String, updated: String, dueDate: String? = nil, extra: [String: String]? = nil) {
        self.key = key
        self.summary = summary
        self.status = status
        self.issueType = issueType
        self.priority = priority
        self.project = project
        self.assignee = assignee
        self.assigneeName = assigneeName
        self.reporter = reporter
        self.reporterName = reporterName
        self.lastViewed = lastViewed
        self.resolution = resolution
        self.created = created
        self.updated = updated
        self.dueDate = dueDate
        self.extra = extra
    }
}

public struct FieldInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var custom: Bool
    public var kind: String
    public init(id: String, name: String, custom: Bool, kind: String) {
        self.id = id
        self.name = name
        self.custom = custom
        self.kind = kind
    }
}

public struct SearchResult: Codable, Hashable, Sendable {
    public var total: Int
    public var issues: [IssueSummary]
    public init(total: Int, issues: [IssueSummary]) {
        self.total = total
        self.issues = issues
    }
}

public struct DisplayField: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var text: String
    public var html: String?
    public var issueKey: String?
    public var hidden: Bool
    public init(id: String, name: String, text: String, html: String? = nil, issueKey: String? = nil, hidden: Bool) {
        self.id = id
        self.name = name
        self.text = text
        self.html = html
        self.issueKey = issueKey
        self.hidden = hidden
    }
}

public struct IssueRef: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var summary: String
    public var status: JiraStatus?
    public var issueType: Named?
    public var id: String { key }
    public init(key: String, summary: String, status: JiraStatus? = nil, issueType: Named? = nil) {
        self.key = key
        self.summary = summary
        self.status = status
        self.issueType = issueType
    }
}

public struct IssueLink: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var key: String
    public var summary: String
    public var status: JiraStatus?
    public var issueType: Named?
    public var relation: String
    public init(id: String, key: String, summary: String, status: JiraStatus? = nil, issueType: Named? = nil, relation: String) {
        self.id = id
        self.key = key
        self.summary = summary
        self.status = status
        self.issueType = issueType
        self.relation = relation
    }
}

public struct TimeTracking: Codable, Hashable, Sendable {
    public var originalEstimate: String?
    public var remainingEstimate: String?
    public var timeSpent: String?
    public var originalEstimateSeconds: Int?
    public var remainingEstimateSeconds: Int?
    public var timeSpentSeconds: Int?
    public init(originalEstimate: String? = nil, remainingEstimate: String? = nil, timeSpent: String? = nil, originalEstimateSeconds: Int? = nil, remainingEstimateSeconds: Int? = nil, timeSpentSeconds: Int? = nil) {
        self.originalEstimate = originalEstimate
        self.remainingEstimate = remainingEstimate
        self.timeSpent = timeSpent
        self.originalEstimateSeconds = originalEstimateSeconds
        self.remainingEstimateSeconds = remainingEstimateSeconds
        self.timeSpentSeconds = timeSpentSeconds
    }
}

public struct Attachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var filename: String
    public var size: Int
    public var mimeType: String
    public var contentUrl: String
    public var thumbnailUrl: String?
    public var author: String
    public var created: String
    public init(id: String, filename: String, size: Int, mimeType: String, contentUrl: String, thumbnailUrl: String? = nil, author: String, created: String) {
        self.id = id
        self.filename = filename
        self.size = size
        self.mimeType = mimeType
        self.contentUrl = contentUrl
        self.thumbnailUrl = thumbnailUrl
        self.author = author
        self.created = created
    }
}

public struct CommentVisibility: Codable, Hashable, Sendable {
    /// role / group
    public var type: String
    public var value: String
    public init(type: String, value: String) {
        self.type = type
        self.value = value
    }
}

public struct Comment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var authorName: String
    public var mine: Bool
    public var created: String
    public var updated: String
    public var body: String
    public var bodyHtml: String
    public var visibility: CommentVisibility?
    public init(id: String, author: String, authorName: String, mine: Bool, created: String, updated: String, body: String, bodyHtml: String, visibility: CommentVisibility? = nil) {
        self.id = id
        self.author = author
        self.authorName = authorName
        self.mine = mine
        self.created = created
        self.updated = updated
        self.body = body
        self.bodyHtml = bodyHtml
        self.visibility = visibility
    }
}

public struct CommentLevel: Codable, Hashable, Sendable {
    public var visibility: CommentVisibility
    public var label: String
    public init(visibility: CommentVisibility, label: String) {
        self.visibility = visibility
        self.label = label
    }
}

public struct Watchers: Codable, Hashable, Sendable {
    public var watching: Bool
    public var count: Int
    public init(watching: Bool, count: Int) {
        self.watching = watching
        self.count = count
    }
}

public struct BriefComment: Codable, Hashable, Sendable {
    public var author: String
    public var authorName: String
    public var created: String
    public var body: String
    public init(author: String, authorName: String, created: String, body: String) {
        self.author = author
        self.authorName = authorName
        self.created = created
        self.body = body
    }
}

public struct HitSnippet: Codable, Hashable, Sendable {
    /// description / comment
    public var source: String
    public var author: String?
    public var text: String
    public init(source: String, author: String? = nil, text: String) {
        self.source = source
        self.author = author
        self.text = text
    }
}

public struct IssueHit: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var summary: String
    public var status: JiraStatus
    public var issueType: Named
    public var priority: Named?
    public var project: Named
    public var assignee: String?
    public var assigneeName: String?
    public var reporter: String?
    public var reporterName: String?
    public var lastViewed: String?
    public var resolution: String?
    public var created: String
    public var updated: String
    public var dueDate: String?
    public var extra: [String: String]?
    public var resolved: String?
    public var commentCount: Int
    public var snippet: HitSnippet?
    public var lastComments: [BriefComment]
    /// 代码关联的问题：key / link
    public var via: String?
    public var id: String { key }

    public var summaryValue: IssueSummary {
        IssueSummary(key: key, summary: summary, status: status, issueType: issueType, priority: priority, project: project, assignee: assignee, assigneeName: assigneeName, reporter: reporter, reporterName: reporterName, lastViewed: lastViewed, resolution: resolution, created: created, updated: updated, dueDate: dueDate, extra: extra)
    }
    public init(key: String, summary: String, status: JiraStatus, issueType: Named, priority: Named? = nil, project: Named, assignee: String? = nil, assigneeName: String? = nil, reporter: String? = nil, reporterName: String? = nil, lastViewed: String? = nil, resolution: String? = nil, created: String, updated: String, dueDate: String? = nil, extra: [String: String]? = nil, resolved: String? = nil, commentCount: Int, snippet: HitSnippet? = nil, lastComments: [BriefComment], via: String? = nil) {
        self.key = key
        self.summary = summary
        self.status = status
        self.issueType = issueType
        self.priority = priority
        self.project = project
        self.assignee = assignee
        self.assigneeName = assigneeName
        self.reporter = reporter
        self.reporterName = reporterName
        self.lastViewed = lastViewed
        self.resolution = resolution
        self.created = created
        self.updated = updated
        self.dueDate = dueDate
        self.extra = extra
        self.resolved = resolved
        self.commentCount = commentCount
        self.snippet = snippet
        self.lastComments = lastComments
        self.via = via
    }
}

public struct SimilarIssues: Codable, Hashable, Sendable {
    public var jql: String?
    /// local / jira
    public var source: String
    public var issues: [IssueHit]
    public init(jql: String? = nil, source: String, issues: [IssueHit]) {
        self.jql = jql
        self.source = source
        self.issues = issues
    }
}

public struct IndexQuery: Codable, Hashable, Sendable {
    public var text: String
    public var project: String
    /// all / unresolved / resolved
    public var state: String
    public var mine: Bool
    public var limit: Int?
    public init(text: String, project: String, state: String, mine: Bool, limit: Int? = nil) {
        self.text = text
        self.project = project
        self.state = state
        self.mine = mine
        self.limit = limit
    }
}

public struct IndexProject: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var count: Int
    public var id: String { key }
    public init(key: String, name: String, count: Int) {
        self.key = key
        self.name = name
        self.count = count
    }
}

public struct IndexProgress: Codable, Hashable, Sendable {
    public var scope: String
    public var done: Int
    public var total: Int
    public var finished: Int
    public var scopes: Int
    public init(scope: String, done: Int, total: Int, finished: Int, scopes: Int) {
        self.scope = scope
        self.done = done
        self.total = total
        self.finished = finished
        self.scopes = scopes
    }
}

public struct IndexStatus: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var count: Int
    public var projects: [IndexProject]
    public var lastSync: String?
    public var running: Bool
    public var progress: IndexProgress?
    public var error: String?
    public init(enabled: Bool, count: Int, projects: [IndexProject], lastSync: String? = nil, running: Bool, progress: IndexProgress? = nil, error: String? = nil) {
        self.enabled = enabled
        self.count = count
        self.projects = projects
        self.lastSync = lastSync
        self.running = running
        self.progress = progress
        self.error = error
    }
}

public struct JiraToolsSettings: Codable, Hashable, Sendable {
    public var indexEnabled: Bool
    public var indexJql: String
    public var indexDays: Int
    public var dueField: String
    public var dueSoonDays: Int
    public var staleDays: Int
    public var remind: Bool
    public init(indexEnabled: Bool, indexJql: String, indexDays: Int, dueField: String, dueSoonDays: Int, staleDays: Int, remind: Bool) {
        self.indexEnabled = indexEnabled
        self.indexJql = indexJql
        self.indexDays = indexDays
        self.dueField = dueField
        self.dueSoonDays = dueSoonDays
        self.staleDays = staleDays
        self.remind = remind
    }
}

public struct Reminder: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var summary: String
    public var status: JiraStatus
    public var issueType: Named
    public var priority: Named?
    public var project: Named
    public var assignee: String?
    public var assigneeName: String?
    public var reporter: String?
    public var reporterName: String?
    public var lastViewed: String?
    public var resolution: String?
    public var created: String
    public var updated: String
    public var dueDate: String?
    public var extra: [String: String]?
    /// overdue / today / soon / stale
    public var kind: String
    public var due: String?
    public var days: Int
    public var id: String { key }
    public init(key: String, summary: String, status: JiraStatus, issueType: Named, priority: Named? = nil, project: Named, assignee: String? = nil, assigneeName: String? = nil, reporter: String? = nil, reporterName: String? = nil, lastViewed: String? = nil, resolution: String? = nil, created: String, updated: String, dueDate: String? = nil, extra: [String: String]? = nil, kind: String, due: String? = nil, days: Int) {
        self.key = key
        self.summary = summary
        self.status = status
        self.issueType = issueType
        self.priority = priority
        self.project = project
        self.assignee = assignee
        self.assigneeName = assigneeName
        self.reporter = reporter
        self.reporterName = reporterName
        self.lastViewed = lastViewed
        self.resolution = resolution
        self.created = created
        self.updated = updated
        self.dueDate = dueDate
        self.extra = extra
        self.kind = kind
        self.due = due
        self.days = days
    }
}

public struct DueFieldRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Reminders: Codable, Hashable, Sendable {
    public var dueField: DueFieldRef?
    public var items: [Reminder]
    public var dueDates: [String: String]
    public var remind: Bool
    public init(dueField: DueFieldRef? = nil, items: [Reminder], dueDates: [String: String], remind: Bool) {
        self.dueField = dueField
        self.items = items
        self.dueDates = dueDates
        self.remind = remind
    }
}

public struct JiraFilter: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var jql: String
    public init(id: String, name: String, jql: String) {
        self.id = id
        self.name = name
        self.jql = jql
    }
}

public struct Priority: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var iconUrl: String?
    public init(id: String, name: String, iconUrl: String? = nil) {
        self.id = id
        self.name = name
        self.iconUrl = iconUrl
    }
}

public struct IssueDetail: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var key: String
    public var summary: String
    public var status: JiraStatus
    public var issueType: Named
    public var priority: Named?
    public var project: Named
    public var assignee: String?
    public var assigneeName: String?
    public var reporter: String?
    public var reporterName: String?
    public var lastViewed: String?
    public var resolution: String?
    public var created: String
    public var updated: String
    public var dueDate: String?
    public var extra: [String: String]?
    public var descriptionHtml: String?
    public var fields: [DisplayField]
    public var timeTracking: TimeTracking?
    public var parent: IssueRef?
    public var subtasks: [IssueRef]
    public var links: [IssueLink]
    public var attachments: [Attachment]
    public var comments: [Comment]

    public var summaryValue: IssueSummary {
        IssueSummary(key: key, summary: summary, status: status, issueType: issueType, priority: priority, project: project, assignee: assignee, assigneeName: assigneeName, reporter: reporter, reporterName: reporterName, lastViewed: lastViewed, resolution: resolution, created: created, updated: updated, dueDate: dueDate, extra: extra)
    }
    public init(id: String, key: String, summary: String, status: JiraStatus, issueType: Named, priority: Named? = nil, project: Named, assignee: String? = nil, assigneeName: String? = nil, reporter: String? = nil, reporterName: String? = nil, lastViewed: String? = nil, resolution: String? = nil, created: String, updated: String, dueDate: String? = nil, extra: [String: String]? = nil, descriptionHtml: String? = nil, fields: [DisplayField], timeTracking: TimeTracking? = nil, parent: IssueRef? = nil, subtasks: [IssueRef], links: [IssueLink], attachments: [Attachment], comments: [Comment]) {
        self.id = id
        self.key = key
        self.summary = summary
        self.status = status
        self.issueType = issueType
        self.priority = priority
        self.project = project
        self.assignee = assignee
        self.assigneeName = assigneeName
        self.reporter = reporter
        self.reporterName = reporterName
        self.lastViewed = lastViewed
        self.resolution = resolution
        self.created = created
        self.updated = updated
        self.dueDate = dueDate
        self.extra = extra
        self.descriptionHtml = descriptionHtml
        self.fields = fields
        self.timeTracking = timeTracking
        self.parent = parent
        self.subtasks = subtasks
        self.links = links
        self.attachments = attachments
        self.comments = comments
    }
}

public struct FieldOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var children: [FieldOption]?
    public var disabled: Bool
    public init(id: String, name: String, children: [FieldOption]? = nil, disabled: Bool) {
        self.id = id
        self.name = name
        self.children = children
        self.disabled = disabled
    }
}

public struct UserRef: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var displayName: String
    public var id: String { name }
    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }
}

public struct IssueChoice: Codable, Hashable, Sendable {
    public var key: String
    public var summary: String
    public init(key: String, summary: String) {
        self.key = key
        self.summary = summary
    }
}

public struct FieldMeta: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var required: Bool
    /// text / textarea / number / date / datetime / select / multiselect / cascading / user / multiuser / labels / timetracking / epic / parent / unsupported
    public var kind: String
    public var options: [FieldOption]
    public var value: JSONValue?
    public var id: String { key }
    public init(key: String, name: String, required: Bool, kind: String, options: [FieldOption], value: JSONValue? = nil) {
        self.key = key
        self.name = name
        self.required = required
        self.kind = kind
        self.options = options
        self.value = value
    }
}

public struct Transition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var to: JiraStatus
    public var fields: [FieldMeta]
    public init(id: String, name: String, to: JiraStatus, fields: [FieldMeta]) {
        self.id = id
        self.name = name
        self.to = to
        self.fields = fields
    }
}

public struct CreateIssueType: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var iconUrl: String?
    public var subtask: Bool
    public init(id: String, name: String, iconUrl: String? = nil, subtask: Bool) {
        self.id = id
        self.name = name
        self.iconUrl = iconUrl
        self.subtask = subtask
    }
}

public struct CreateProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var key: String
    public var name: String
    public var issueTypes: [CreateIssueType]
    public init(id: String, key: String, name: String, issueTypes: [CreateIssueType]) {
        self.id = id
        self.key = key
        self.name = name
        self.issueTypes = issueTypes
    }
}

public struct CreatedIssue: Codable, Hashable, Sendable {
    public var key: String
    public var attachmentError: String?
    public init(key: String, attachmentError: String? = nil) {
        self.key = key
        self.attachmentError = attachmentError
    }
}

public struct LinkType: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var inward: String
    public var outward: String
    public init(id: String, name: String, inward: String, outward: String) {
        self.id = id
        self.name = name
        self.inward = inward
        self.outward = outward
    }
}

public struct Worklog: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var mine: Bool
    public var started: String
    public var timeSpent: String
    public var timeSpentSeconds: Int
    public var comment: String
    public init(id: String, author: String, mine: Bool, started: String, timeSpent: String, timeSpentSeconds: Int, comment: String) {
        self.id = id
        self.author = author
        self.mine = mine
        self.started = started
        self.timeSpent = timeSpent
        self.timeSpentSeconds = timeSpentSeconds
        self.comment = comment
    }
}

public struct WorklogInput: Codable, Hashable, Sendable {
    public var started: String
    public var timeSpent: String
    public var comment: String
    public init(started: String, timeSpent: String, comment: String) {
        self.started = started
        self.timeSpent = timeSpent
        self.comment = comment
    }
}

public struct WorklogSum: Codable, Hashable, Sendable {
    public var key: String
    public var summary: String
    public var seconds: Int
    public init(key: String, summary: String, seconds: Int) {
        self.key = key
        self.summary = summary
        self.seconds = seconds
    }
}

public struct HistoryItem: Codable, Hashable, Sendable {
    public var fieldId: String
    public var field: String
    public var from: String?
    public var to: String?
    public init(fieldId: String, field: String, from: String? = nil, to: String? = nil) {
        self.fieldId = fieldId
        self.field = field
        self.from = from
        self.to = to
    }
}

public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var authorName: String
    public var created: String
    public var items: [HistoryItem]
    public init(id: String, author: String, authorName: String, created: String, items: [HistoryItem]) {
        self.id = id
        self.author = author
        self.authorName = authorName
        self.created = created
        self.items = items
    }
}

public struct Viewed: Codable, Hashable, Sendable {
    public var viewed: [String: Int64]
    public var baseline: Int64
    public init(viewed: [String: Int64], baseline: Int64) {
        self.viewed = viewed
        self.baseline = baseline
    }
}
