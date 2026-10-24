import Foundation

// 与 Rust 应用层命令的参数、结果一一对应（字段名为 camelCase）。与 src/api.ts 中的类型相同。

enum Service: String, Codable, CaseIterable, Hashable, Sendable {
    case jira, confluence, gitlab

    var label: String {
        switch self {
        case .jira: "Jira"
        case .confluence: "Wiki"
        case .gitlab: "GitLab"
        }
    }
}

// MARK: - 设置

struct ServiceSettings: Codable, Hashable {
    var service: Service
    var label: String
    var baseUrl: String
    var hasToken: Bool
    var supportsWebLogin: Bool
    var webUsername: String
    var hasWebPassword: Bool
}

struct Settings: Codable, Hashable {
    var proxy: String
    var services: [ServiceSettings]
    var weeklyPageId: String
    var weeklyPersonName: String
}

struct WebAccountInput: Codable, Hashable {
    var username: String
    var password: String
}

struct SettingsInput: Codable {
    var proxy: String
    var baseUrls: [String: String]
    var tokens: [String: String]
    var weeklyPage: String
    var weeklyPersonName: String
    var webAccounts: [String: WebAccountInput]
}

/// 访问附件、图片等网页路径的方式：Token 即可 / 已网页登录 / 需要网页登录。
enum WebAccess: String, Codable, Hashable {
    case token, session, loginRequired
}

struct ConnectionInfo: Codable, Hashable {
    var service: Service
    var username: String
    var displayName: String
    var serverVersion: String?
}

// MARK: - Jira

struct JiraStatus: Codable, Hashable {
    var name: String
    /// new / indeterminate / done
    var category: String
}

struct Named: Codable, Hashable {
    var name: String
    var iconUrl: String?
}

struct IssueSummary: Codable, Hashable, Identifiable {
    var key: String
    var summary: String
    var status: JiraStatus
    var issueType: Named
    var priority: Named?
    var project: Named
    var assignee: String?
    var assigneeName: String?
    var reporter: String?
    var reporterName: String?
    var lastViewed: String?
    var resolution: String?
    var created: String
    var updated: String
    var dueDate: String?
    var extra: [String: String]?
    var id: String { key }
}

struct FieldInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var custom: Bool
    var kind: String
}

struct SearchResult: Codable, Hashable {
    var total: Int
    var issues: [IssueSummary]
}

struct DisplayField: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var text: String
    var html: String?
    var issueKey: String?
    var hidden: Bool
}

struct IssueRef: Codable, Hashable, Identifiable {
    var key: String
    var summary: String
    var status: JiraStatus?
    var issueType: Named?
    var id: String { key }
}

struct IssueLink: Codable, Hashable, Identifiable {
    var id: String
    var key: String
    var summary: String
    var status: JiraStatus?
    var issueType: Named?
    var relation: String
}

struct TimeTracking: Codable, Hashable {
    var originalEstimate: String?
    var remainingEstimate: String?
    var timeSpent: String?
    var originalEstimateSeconds: Int?
    var remainingEstimateSeconds: Int?
    var timeSpentSeconds: Int?
}

struct Attachment: Codable, Hashable, Identifiable {
    var id: String
    var filename: String
    var size: Int
    var mimeType: String
    var contentUrl: String
    var thumbnailUrl: String?
    var author: String
    var created: String
}

struct CommentVisibility: Codable, Hashable {
    /// role / group
    var type: String
    var value: String
}

struct Comment: Codable, Hashable, Identifiable {
    var id: String
    var author: String
    var authorName: String
    var mine: Bool
    var created: String
    var updated: String
    var body: String
    var bodyHtml: String
    var visibility: CommentVisibility?
}

struct CommentLevel: Codable, Hashable {
    var visibility: CommentVisibility
    var label: String
}

struct Watchers: Codable, Hashable {
    var watching: Bool
    var count: Int
}

struct BriefComment: Codable, Hashable {
    var author: String
    var authorName: String
    var created: String
    var body: String
}

struct HitSnippet: Codable, Hashable {
    /// description / comment
    var source: String
    var author: String?
    var text: String
}

/// 本机问题库的搜索结果、相似问题。
struct IssueHit: Codable, Hashable, Identifiable {
    var key: String
    var summary: String
    var status: JiraStatus
    var issueType: Named
    var priority: Named?
    var project: Named
    var assignee: String?
    var assigneeName: String?
    var reporter: String?
    var reporterName: String?
    var lastViewed: String?
    var resolution: String?
    var created: String
    var updated: String
    var dueDate: String?
    var extra: [String: String]?
    var resolved: String?
    var commentCount: Int
    var snippet: HitSnippet?
    var lastComments: [BriefComment]
    /// 代码关联的问题：key / link
    var via: String?
    var id: String { key }

    var summaryValue: IssueSummary {
        IssueSummary(key: key, summary: summary, status: status, issueType: issueType, priority: priority, project: project, assignee: assignee, assigneeName: assigneeName, reporter: reporter, reporterName: reporterName, lastViewed: lastViewed, resolution: resolution, created: created, updated: updated, dueDate: dueDate, extra: extra)
    }
}

struct SimilarIssues: Codable, Hashable {
    var jql: String?
    /// local / jira
    var source: String
    var issues: [IssueHit]
}

struct IndexQuery: Codable, Hashable {
    var text: String
    var project: String
    /// all / unresolved / resolved
    var state: String
    var mine: Bool
    var limit: Int?
}

struct IndexProject: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var count: Int
    var id: String { key }
}

struct IndexProgress: Codable, Hashable {
    var scope: String
    var done: Int
    var total: Int
    var finished: Int
    var scopes: Int
}

struct IndexStatus: Codable, Hashable {
    var enabled: Bool
    var count: Int
    var projects: [IndexProject]
    var lastSync: String?
    var running: Bool
    var progress: IndexProgress?
    var error: String?
}

struct JiraToolsSettings: Codable, Hashable {
    var indexEnabled: Bool
    var indexJql: String
    var indexDays: Int
    var dueField: String
    var dueSoonDays: Int
    var staleDays: Int
    var remind: Bool
}

struct Reminder: Codable, Hashable, Identifiable {
    var key: String
    var summary: String
    var status: JiraStatus
    var issueType: Named
    var priority: Named?
    var project: Named
    var assignee: String?
    var assigneeName: String?
    var reporter: String?
    var reporterName: String?
    var lastViewed: String?
    var resolution: String?
    var created: String
    var updated: String
    var dueDate: String?
    var extra: [String: String]?
    /// overdue / today / soon / stale
    var kind: String
    var due: String?
    var days: Int
    var id: String { key }
}

struct DueFieldRef: Codable, Hashable {
    var id: String
    var name: String
}

struct Reminders: Codable, Hashable {
    var dueField: DueFieldRef?
    var items: [Reminder]
    var dueDates: [String: String]
    var remind: Bool
}

struct ActivityEvent: Codable, Hashable, Identifiable {
    var id: String
    var issueKey: String
    var issueSummary: String
    var issueTypeIcon: String?
    var kind: String
    var actor: String
    var at: String
    var text: String
    var read: Bool
    /// jira / wiki
    var system: String
}

struct ActivityFeed: Codable, Hashable {
    var events: [ActivityEvent]
    var unread: Int
    var lastCheck: String?
}

struct ActivityPoll: Codable, Hashable {
    var feed: ActivityFeed
    var fresh: [ActivityEvent]
}

struct PreviewSheet: Codable, Hashable {
    var name: String
    var rows: [[String]]
    var totalRows: Int
    var totalCols: Int
}

struct ArchiveEntry: Codable, Hashable {
    var name: String
    var size: Int
    var dir: Bool
}

enum AttachmentPreview: Decodable, Hashable {
    case text(text: String, truncated: Bool, encoding: String)
    case sheet([PreviewSheet])
    case document(paragraphs: [String], truncated: Bool)
    case archive(entries: [ArchiveEntry], truncated: Bool)
    case unsupported(String)

    private enum Keys: String, CodingKey { case kind, text, truncated, encoding, sheets, paragraphs, entries, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "text": self = .text(text: try c.decode(String.self, forKey: .text), truncated: try c.decode(Bool.self, forKey: .truncated), encoding: try c.decode(String.self, forKey: .encoding))
        case "sheet": self = .sheet(try c.decode([PreviewSheet].self, forKey: .sheets))
        case "document": self = .document(paragraphs: try c.decode([String].self, forKey: .paragraphs), truncated: try c.decode(Bool.self, forKey: .truncated))
        case "archive": self = .archive(entries: try c.decode([ArchiveEntry].self, forKey: .entries), truncated: try c.decode(Bool.self, forKey: .truncated))
        default: self = .unsupported((try? c.decode(String.self, forKey: .reason)) ?? "不支持预览")
        }
    }
}

struct JiraFilter: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var jql: String
}

struct Priority: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var iconUrl: String?
}

struct IssueDetail: Codable, Hashable, Identifiable {
    var id: String
    var key: String
    var summary: String
    var status: JiraStatus
    var issueType: Named
    var priority: Named?
    var project: Named
    var assignee: String?
    var assigneeName: String?
    var reporter: String?
    var reporterName: String?
    var lastViewed: String?
    var resolution: String?
    var created: String
    var updated: String
    var dueDate: String?
    var extra: [String: String]?
    var descriptionHtml: String?
    var fields: [DisplayField]
    var timeTracking: TimeTracking?
    var parent: IssueRef?
    var subtasks: [IssueRef]
    var links: [IssueLink]
    var attachments: [Attachment]
    var comments: [Comment]

    var summaryValue: IssueSummary {
        IssueSummary(key: key, summary: summary, status: status, issueType: issueType, priority: priority, project: project, assignee: assignee, assigneeName: assigneeName, reporter: reporter, reporterName: reporterName, lastViewed: lastViewed, resolution: resolution, created: created, updated: updated, dueDate: dueDate, extra: extra)
    }
}

struct FieldOption: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var children: [FieldOption]?
    var disabled: Bool
}

struct UserRef: Codable, Hashable, Identifiable {
    var name: String
    var displayName: String
    var id: String { name }
}

struct IssueChoice: Codable, Hashable {
    var key: String
    var summary: String
}

struct FieldMeta: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var required: Bool
    /// text / textarea / number / date / datetime / select / multiselect / cascading / user / multiuser / labels / timetracking / epic / parent / unsupported
    var kind: String
    var options: [FieldOption]
    var value: JSONValue?
    var id: String { key }
}

struct Transition: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var to: JiraStatus
    var fields: [FieldMeta]
}

struct CreateIssueType: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var iconUrl: String?
    var subtask: Bool
}

struct CreateProject: Codable, Hashable, Identifiable {
    var id: String
    var key: String
    var name: String
    var issueTypes: [CreateIssueType]
}

struct CreatedIssue: Codable, Hashable {
    var key: String
    var attachmentError: String?
}

struct LinkType: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var inward: String
    var outward: String
}

struct Worklog: Codable, Hashable, Identifiable {
    var id: String
    var author: String
    var mine: Bool
    var started: String
    var timeSpent: String
    var timeSpentSeconds: Int
    var comment: String
}

struct WorklogInput: Codable, Hashable {
    var started: String
    var timeSpent: String
    var comment: String
}

struct WorklogSum: Codable, Hashable {
    var key: String
    var summary: String
    var seconds: Int
}

struct HistoryItem: Codable, Hashable {
    var fieldId: String
    var field: String
    var from: String?
    var to: String?
}

struct HistoryEntry: Codable, Hashable, Identifiable {
    var id: String
    var author: String
    var authorName: String
    var created: String
    var items: [HistoryItem]
}

struct Viewed: Codable, Hashable {
    var viewed: [String: Int64]
    var baseline: Int64
}

// MARK: - 周报

struct OutlineItem: Codable, Hashable {
    var level: Int
    var text: String
}

struct SectionInfo: Codable, Hashable {
    var title: String
    var coversToday: Bool
}

struct WeekEntry: Codable, Hashable {
    var sectionTitle: String
    var rowFound: Bool
    var content: [OutlineItem]
    var risk: [OutlineItem]
    var contentRaw: String
    var riskRaw: String
    var lossy: Bool
}

struct WeeklyView: Codable, Hashable {
    var pageId: String
    var pageTitle: String
    var pageUrl: String
    var version: Int
    var modifiedBy: String
    var modifiedAt: String
    var personName: String
    var sections: [SectionInfo]
    var currentWeekTitle: String
    var currentWeekExists: Bool
    var entry: WeekEntry?
}

struct SaveResult: Codable, Hashable {
    var changed: Bool
    var version: Int
}

struct DraftItem: Codable, Hashable {
    var text: String
    var key: String?
    var evidence: [String]
    var lastWeek: String?
}

struct DraftGroup: Codable, Hashable {
    var title: String
    /// jira / worklog / gitlab / wiki / todo / daily
    var source: String
    var items: [DraftItem]
}

struct CarryOver: Codable, Hashable {
    var group: String
    var text: String
    var progress: String?
    var thisWeek: String?
}

struct WeeklyDraft: Codable, Hashable {
    var from: String
    var to: String
    var groups: [DraftGroup]
    var carryOver: [CarryOver]
    var lastWeekTitle: String?
    var separator: String
    var notes: [String]
}

struct WeeklySaveInput: Codable, Hashable {
    var section: String
    var contentRaw: String
    var riskRaw: String
    var content: [OutlineItem]
    var risk: [OutlineItem]
}

// MARK: - GitLab

struct Project: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var pathWithNamespace: String
    var description: String?
    var defaultBranch: String?
    var webUrl: String
    var lastActivityAt: String
    var removeSourceBranchAfterMerge: Bool?
    var squashOption: String?
}

struct Commit: Codable, Hashable, Identifiable {
    var id: String
    var shortId: String
    var title: String
    var message: String
    var authorName: String
    var authoredDate: String
    var webUrl: String?
}

struct CodeRefSource: Codable, Hashable {
    /// description / comment / mrSearch / commitSearch
    var kind: String
    var author: String?
    var at: String?
    var commentId: String?
}

struct CodeRef: Codable, Hashable {
    /// mr / branch / commit / external
    var kind: String
    var url: String
    var projectId: Int?
    var projectPath: String
    var projectName: String
    var branch: String?
    var sha: String?
    var iid: Int?
    var title: String
    var state: String?
    var pipeline: String?
    var author: String?
    var at: String?
    var commits: [Commit]
    var unavailable: String?
    var sources: [CodeRefSource]
}

struct IssueText: Codable, Hashable {
    /// description / comment
    var source: String
    var commentId: String?
    var author: String?
    var at: String?
    var html: String
}

struct CodeTarget: Codable, Hashable {
    var projectPath: String
    var branch: String?
    var sha: String?
    var iid: Int?
    var text: String
}

struct Branch: Codable, Hashable, Identifiable {
    var name: String
    var `default`: Bool
    var protected: Bool
    var merged: Bool
    var commit: Commit
    var id: String { name }
}

struct TreeEntry: Codable, Hashable, Identifiable {
    var name: String
    var path: String
    /// tree / blob / commit
    var kind: String
    var id: String { path }
}

struct FileContent: Codable, Hashable {
    var path: String
    var size: Int
    var text: String?
    var imageDataUrl: String?
    var tooLarge: Bool
    var binary: Bool
}

struct FileDiff: Codable, Hashable, Identifiable {
    var oldPath: String
    var newPath: String
    var diff: String
    var newFile: Bool
    var deletedFile: Bool
    var renamedFile: Bool
    var id: String { oldPath + "→" + newPath }
}

struct CommitDetail: Codable, Hashable {
    var commit: Commit
    var diffs: [FileDiff]
}

struct Comparison: Codable, Hashable {
    var commits: [Commit]
    var diffs: [FileDiff]
}

struct MrChanges: Codable, Hashable {
    var diffs: [FileDiff]
    var overflow: Bool
}

struct GlUser: Codable, Hashable, Identifiable {
    var id: Int
    var username: String
    var name: String
}

struct DiffRefs: Codable, Hashable {
    var baseSha: String
    var headSha: String
    var startSha: String
}

struct Pipeline: Codable, Hashable {
    var id: Int
    var status: String
    var webUrl: String?
}

struct MergeRequest: Codable, Hashable, Identifiable {
    var id: Int
    var iid: Int
    var projectId: Int
    var title: String
    var description: String
    /// opened / merged / closed / locked
    var state: String
    var draft: Bool
    var author: GlUser
    var assignees: [GlUser]
    var reviewers: [GlUser]
    var sourceBranch: String
    var targetBranch: String
    var sourceProjectId: Int?
    var createdAt: String
    var updatedAt: String
    var mergedAt: String?
    var mergedBy: GlUser?
    var closedAt: String?
    var closedBy: GlUser?
    var mergeStatus: String
    var hasConflicts: Bool
    var userNotesCount: Int
    var upvotes: Int
    var labels: [String]
    var webUrl: String
    var reference: String
    var changesCount: String?
    var sha: String?
    var diffRefs: DiffRefs?
    var headPipeline: Pipeline?
    var squash: Bool
    var forceRemoveSourceBranch: Bool?
    var blockingDiscussionsResolved: Bool
    var mergeError: String?
    var mergeWhenPipelineSucceeds: Bool
    var canMerge: Bool
}

struct NotePosition: Codable, Hashable {
    var baseSha: String
    var startSha: String
    var headSha: String
    var oldPath: String
    var newPath: String
    var oldLine: Int?
    var newLine: Int?
}

struct MrNote: Codable, Hashable, Identifiable {
    var id: Int
    var body: String
    var author: GlUser
    var createdAt: String
    var updatedAt: String?
    var system: Bool
    var resolvable: Bool
    var resolved: Bool
    var resolvedBy: GlUser?
    var position: NotePosition?
}

struct Discussion: Codable, Hashable, Identifiable {
    var id: String
    var individualNote: Bool
    var notes: [MrNote]
}

struct Approvals: Codable, Hashable {
    var approved: Bool
    var userHasApproved: Bool
    var userCanApprove: Bool
    var approvedBy: [GlUser]
}

struct MrQuery: Codable, Hashable {
    /// opened / merged / closed / all
    var state: String?
    var search: String?
    var sourceBranch: String?
    var page: Int?
}

// MARK: - 工作空间

struct ChecklistItem: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    var done: Bool
}

struct Todo: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var notes: String
    var done: Bool
    var completedAt: Int64?
    /// YYYY-MM-DD
    var due: String?
    /// 0 无、1 低、2 中、3 高
    var priority: Int
    var sort: Double
    var refSystem: String?
    var refKey: String?
    var refTitle: String?
    var source: String?
    var autoDone: Bool
    var createdAt: Int64
    var updatedAt: Int64
    var remindAt: Int64?
    /// daily / weekdays / weekly / monthly
    var `repeat`: String?
    var checklist: [ChecklistItem]
}

struct TodoInput: Codable, Hashable {
    var id: String?
    var title: String
    var notes: String?
    var done: Bool?
    var due: String??
    var priority: Int?
    var refSystem: String??
    var refKey: String??
    var refTitle: String??
    var remindAt: Int64??
    var `repeat`: String??
    var checklist: [ChecklistItem]?

    /// 只编码设置了的字段；双重可选中的 `.some(nil)` 编码为 `null`（清除）。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(done, forKey: .done)
        if let due { try c.encode(due, forKey: .due) }
        try c.encodeIfPresent(priority, forKey: .priority)
        if let refSystem { try c.encode(refSystem, forKey: .refSystem) }
        if let refKey { try c.encode(refKey, forKey: .refKey) }
        if let refTitle { try c.encode(refTitle, forKey: .refTitle) }
        if let remindAt { try c.encode(remindAt, forKey: .remindAt) }
        if let `repeat` { try c.encode(`repeat`, forKey: .repeat) }
        try c.encodeIfPresent(checklist, forKey: .checklist)
    }

    init(id: String? = nil, title: String, notes: String? = nil, done: Bool? = nil, due: String?? = nil, priority: Int? = nil, refSystem: String?? = nil, refKey: String?? = nil, refTitle: String?? = nil, remindAt: Int64?? = nil, repeat: String?? = nil, checklist: [ChecklistItem]? = nil) {
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
        self.repeat = `repeat`
        self.checklist = checklist
    }

    /// 由已有的待办构造（保存时带上全部字段）。
    init(_ todo: Todo) {
        self.init(id: todo.id, title: todo.title, notes: todo.notes, done: todo.done, due: .some(todo.due), priority: todo.priority, refSystem: .some(todo.refSystem), refKey: .some(todo.refKey), refTitle: .some(todo.refTitle), remindAt: .some(todo.remindAt), repeat: .some(todo.repeat), checklist: todo.checklist)
    }
}

struct InboxMr: Codable, Hashable {
    var projectId: Int
    var iid: Int
    var reference: String
}

struct InboxItem: Codable, Hashable, Identifiable {
    var id: String
    /// activity / due / mr
    var source: String
    var title: String
    var detail: String
    var at: Int64
    var system: String?
    var key: String?
    var url: String?
    var mr: InboxMr?
    var events: [ActivityEvent]
    var dueKind: String?
    var dueDays: Int?
    var snoozeUntil: Int64?
}

struct InboxView: Codable, Hashable {
    var items: [InboxItem]
    var snoozed: [InboxItem]
    var notes: [String]
}

struct InboxHandleInput: Codable, Hashable {
    var id: String
    var title: String
    var eventIds: [String]?
}

struct WorkEvent: Codable, Hashable {
    var at: Int64
    /// jira / gitlab / wiki / todo
    var system: String
    var kind: String
    var title: String
    var key: String?
    var detail: String
    var projectId: Int?
}

struct WorkLog: Codable, Hashable {
    var day: String
    var events: [WorkEvent]
    var notes: [String]
}

/// note / daily / page，以及模板 jira-template
typealias DocKind = String

struct Doc: Codable, Hashable, Identifiable {
    var id: String
    var kind: DocKind
    var title: String
    var content: String
    var parentId: String?
    var sort: Double
    var tags: [String]
    var day: String?
    var pinned: Bool
    var sourceSystem: String?
    var sourceKey: String?
    var sourceUrl: String?
    var publishedUrl: String?
    var createdAt: Int64
    var updatedAt: Int64
}

struct DocSummary: Codable, Hashable, Identifiable {
    var id: String
    var kind: DocKind
    var title: String
    var excerpt: String
    var parentId: String?
    var sort: Double
    var tags: [String]
    var day: String?
    var pinned: Bool
    var sourceSystem: String?
    var sourceKey: String?
    var publishedUrl: String?
    var updatedAt: Int64
}

struct DocInput: Codable, Hashable {
    var id: String?
    var kind: DocKind
    var title: String
    var content: String
    var parentId: String?
    var tags: [String]?
    var pinned: Bool?
    var sourceSystem: String?
    var sourceKey: String?
    var sourceUrl: String?
}

struct TagCount: Codable, Hashable, Identifiable {
    var name: String
    var count: Int
    var id: String { name }
}

struct Backlink: Codable, Hashable, Identifiable {
    /// todo / doc
    var itemType: String
    var id: String
    var kind: String
    var title: String
    var done: Bool
    var updatedAt: Int64
}

struct WorkspaceHit: Codable, Hashable, Identifiable {
    var itemType: String
    var id: String
    var kind: String
    var title: String
    var snippet: String
    var done: Bool
}

struct SyncReport: Codable, Hashable {
    var exported: Int
    var imported: Int
    var conflicts: Int
    var devices: Int
    var finishedAt: Int64
}

struct WorkspaceSettings: Codable, Hashable {
    var syncDir: String
    var jiraTodos: Bool
    var deviceId: String
    var lastSync: SyncReport?
    var lastError: String?
    var captureShortcut: String
    var captureError: String?
}

struct JiraTodoSync: Codable, Hashable {
    var added: Int
    var completed: Int
    var reopened: Int
}

struct SavedAsset: Codable, Hashable {
    var id: String
    var mime: String
}

struct WsWikiPage: Codable, Hashable {
    var id: String
    var title: String
    var spaceKey: String
    var url: String
    var html: String
    var version: Int
}

struct PublishResult: Codable, Hashable {
    var url: String
    var updated: Bool
    var doc: Doc?
}

// MARK: - 剪贴板

struct ClipImage: Codable, Hashable {
    var width: Int
    var height: Int
    var bytes: Int
}

struct ClipItem: Codable, Hashable, Identifiable {
    var id: String
    /// text / link / code / color / image / file
    var kind: String
    var text: String
    var textLength: Int
    var hasHtml: Bool
    var title: String
    var image: ClipImage?
    var files: [String]
    var appId: String?
    var appName: String?
    var appColor: String?
    var appIcon: Bool
    var createdAt: Int64
    var copiedAt: Int64
    var copyCount: Int
    var pinboard: String?
}

struct ClipQuery: Codable, Hashable {
    var text: String?
    var kind: String?
    var pinboard: String?
    var app: String?
    var before: Int64?
    var limit: Int?
}

struct Pinboard: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var color: String
    var sort: Double
    var count: Int
}

struct IgnoredApp: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct ClipboardConfig: Codable, Hashable {
    var enabled: Bool
    var shortcut: String
    var autoPaste: Bool
    var plainText: Bool
    var keepDays: Int
    var maxItems: Int
    var saveImages: Bool
    var maxImageMb: Int
    var skipSecrets: Bool
    var ignoredApps: [IgnoredApp]
}

struct ClipStats: Codable, Hashable {
    var items: Int
    var pinned: Int
    var imageBytes: Int64
}

struct ClipSettings: Codable, Hashable {
    var config: ClipboardConfig
    var builtinIgnored: [IgnoredApp]
    var stats: ClipStats
    /// ready / needsPermission / unsupported
    var pasteSupport: String
    var pasteNote: String?
    var pausedUntil: Int64?
    var shortcutError: String?
    var dataDir: String
}

struct ClipApp: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var color: String?
    var icon: Bool
    var count: Int
}

struct ClipText: Codable, Hashable {
    var text: String
    var html: String?
}

// MARK: - Wiki

struct WikiSpace: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var homepageId: String?
    var description: String
    var id: String { key }
}

struct WikiNode: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var hasChildren: Bool
}

struct WikiAncestor: Codable, Hashable, Identifiable {
    var id: String
    var title: String
}

struct WikiPageDetail: Codable, Hashable, Identifiable {
    var id: String
    /// page / blogpost
    var kind: String
    var title: String
    var spaceKey: String
    var spaceName: String
    var version: Int
    var modifiedBy: String
    var modified: String
    var versionMessage: String
    var createdBy: String
    var created: String
    var ancestors: [WikiAncestor]
    var labels: [String]
    var html: String
    var url: String
    var canEdit: Bool
}

struct WikiRecent: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var space: String
    var at: Int64
    /// app / web
    var source: String
}

struct WikiVersion: Codable, Hashable, Identifiable {
    var number: Int
    var by: String
    var when: String
    var message: String
    var minorEdit: Bool
    var id: Int { number }
}

struct WikiComment: Codable, Hashable, Identifiable {
    var id: String
    var author: String
    var created: String
    var html: String
    var parentId: String?
    var inlineText: String?
    var version: Int
}

struct WikiPageHit: Codable, Hashable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var spaceKey: String
    var spaceName: String
    var ancestors: [WikiAncestor]
    var authorName: String
    var modified: String
    var snippet: String
}

struct WikiQuery: Codable, Hashable {
    var text: String
    var space: String?
    var mine: Bool?
    var days: Int?
    var kind: String?
    var limit: Int?
}

struct WikiSearchResult: Codable, Hashable {
    /// local / server
    var source: String
    var total: Int
    var hits: [WikiPageHit]
}

struct WikiTemplate: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String
    var spaceKey: String?
}

struct WikiEditSession: Codable, Hashable {
    var pageId: String?
    var title: String
    var spaceKey: String
    var version: Int
    var html: String
    var fragments: [String]
    var users: [String]
}

struct WikiSavePreview: Codable, Hashable {
    var storage: String
    var diff: String
    var changed: Bool
}

struct WikiIndexSpace: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var count: Int
    var id: String { key }
}

struct WikiIndexProgress: Codable, Hashable {
    var done: Int
    var total: Int
}

struct WikiIndexStatus: Codable, Hashable {
    var enabled: Bool
    var count: Int
    var spaces: [WikiIndexSpace]
    var lastSync: String?
    var running: Bool
    var progress: WikiIndexProgress?
    var error: String?
}

struct WikiToolsSettings: Codable, Hashable {
    var indexEnabled: Bool
    var indexSpaces: [String]
    var taskTodos: Bool
    var activity: Bool
    var mutedPages: [String]
}

struct WikiPageVersionInfo: Codable, Hashable {
    var title: String
    var version: Int
    var by: String
    var when: String
}

// MARK: - 全局搜索

struct WikiHit: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var space: String
    var url: String
    var excerpt: String
}

struct SearchResults: Codable, Hashable {
    var issues: [IssueHit]
    var issuesSource: String?
    var projects: [Project]
    var mergeRequests: [MergeRequest]
    var pages: [WikiHit]
    var workspace: [WorkspaceHit]
    var clips: [ClipItem]
    var errors: [String]
}

struct SearchOptions: Codable, Hashable {
    /// local / remote
    var phase: String?
    var limit: Int?
}

/// 打开登录窗口所需的信息。
struct WebLoginInfo: Codable, Hashable {
    var url: String
    var baseUrl: String
    var title: String
    var autofill: String?
}

/// 空结果（命令返回 `null` 或不关心结果）。
struct Nothing: Decodable {
    init(from decoder: Decoder) throws {}
    init() {}
}
