import NWZWiki
import NWZJira
import NWZPreview
import Foundation
import NWZCore
import NWZServices
import NWZWorkspace

// 与 Rust 应用层命令的参数、结果一一对应（字段名为 camelCase）。与 src/api.ts 中的类型相同。

typealias Service = NWZCore.Service

// MARK: - 设置

typealias ServiceSettings = NWZServices.ServiceSettings
typealias Settings = NWZServices.Settings
typealias WebAccountInput = NWZServices.WebAccountInput
typealias SettingsInput = NWZServices.SettingsInput
typealias ConnectionInfo = NWZCore.ConnectionInfo

/// 访问附件、图片等网页路径的方式：Token 即可 / 已网页登录 / 需要网页登录。
enum WebAccess: String, Codable, Hashable {
    case token, session, loginRequired
}

// MARK: - Jira

typealias JiraStatus = NWZJira.JiraStatus

typealias Named = NWZJira.Named

typealias IssueSummary = NWZJira.IssueSummary

typealias FieldInfo = NWZJira.FieldInfo

typealias SearchResult = NWZJira.SearchResult

typealias DisplayField = NWZJira.DisplayField

typealias IssueRef = NWZJira.IssueRef

typealias IssueLink = NWZJira.IssueLink

typealias TimeTracking = NWZJira.TimeTracking

typealias Attachment = NWZJira.Attachment

typealias CommentVisibility = NWZJira.CommentVisibility

typealias Comment = NWZJira.Comment

typealias CommentLevel = NWZJira.CommentLevel

typealias Watchers = NWZJira.Watchers

typealias BriefComment = NWZJira.BriefComment

typealias HitSnippet = NWZJira.HitSnippet

/// 本机问题库的搜索结果、相似问题。
typealias IssueHit = NWZJira.IssueHit

typealias SimilarIssues = NWZJira.SimilarIssues

typealias IndexQuery = NWZJira.IndexQuery

typealias IndexProject = NWZJira.IndexProject

typealias IndexProgress = NWZJira.IndexProgress

typealias IndexStatus = NWZJira.IndexStatus

typealias JiraToolsSettings = NWZJira.JiraToolsSettings

typealias Reminder = NWZJira.Reminder

typealias DueFieldRef = NWZJira.DueFieldRef

typealias Reminders = NWZJira.Reminders

typealias ActivityEvent = NWZServices.ActivityEvent

typealias ActivityFeed = NWZJira.ActivityFeed

typealias ActivityPoll = NWZJira.ActivityPoll

typealias PreviewSheet = NWZPreview.PreviewSheet
typealias ArchiveEntry = NWZPreview.ArchiveEntry
typealias AttachmentPreview = NWZPreview.AttachmentPreview

typealias JiraFilter = NWZJira.JiraFilter

typealias Priority = NWZJira.Priority

typealias IssueDetail = NWZJira.IssueDetail

typealias FieldOption = NWZJira.FieldOption

typealias UserRef = NWZJira.UserRef

typealias IssueChoice = NWZJira.IssueChoice

typealias FieldMeta = NWZJira.FieldMeta

typealias Transition = NWZJira.Transition

typealias CreateIssueType = NWZJira.CreateIssueType

typealias CreateProject = NWZJira.CreateProject

typealias CreatedIssue = NWZJira.CreatedIssue

typealias LinkType = NWZJira.LinkType

typealias Worklog = NWZJira.Worklog

typealias WorklogInput = NWZJira.WorklogInput

typealias WorklogSum = NWZJira.WorklogSum

typealias HistoryItem = NWZJira.HistoryItem

typealias HistoryEntry = NWZJira.HistoryEntry

typealias Viewed = NWZJira.Viewed

// MARK: - 周报

typealias OutlineItem = NWZWiki.OutlineItem

typealias SectionInfo = NWZWiki.SectionInfo

typealias WeekEntry = NWZWiki.WeekEntry

typealias WeeklyView = NWZWiki.WeeklyView

typealias SaveResult = NWZWiki.SaveResult

typealias DraftItem = NWZWiki.DraftItem

typealias DraftGroup = NWZWiki.DraftGroup

typealias CarryOver = NWZWiki.CarryOver

typealias WeeklyDraft = NWZWiki.WeeklyDraft

typealias WeeklySaveInput = NWZWiki.WeeklySaveInput

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

typealias ChecklistItem = NWZWorkspace.ChecklistItem

typealias Todo = NWZWorkspace.Todo

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

typealias InboxMr = NWZServices.InboxMr

typealias InboxItem = NWZServices.InboxItem

typealias InboxView = NWZServices.InboxView

typealias InboxHandleInput = NWZServices.InboxHandleInput

typealias WorkEvent = NWZServices.WorkEvent

typealias WorkLog = NWZServices.WorkLog

/// note / daily / page，以及模板 jira-template
typealias DocKind = String

typealias Doc = NWZWorkspace.Doc

typealias DocSummary = NWZWorkspace.DocSummary

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

typealias TagCount = NWZWorkspace.TagCount

typealias Backlink = NWZWorkspace.Backlink

typealias WorkspaceHit = NWZWorkspace.SearchHit

typealias SyncReport = NWZWorkspace.SyncReport

typealias WorkspaceSettings = NWZServices.WorkspaceSettings

typealias JiraTodoSync = NWZWorkspace.JiraTodoSync

typealias SavedAsset = NWZWorkspace.AssetMeta

typealias WsWikiPage = NWZServices.WsWikiPage

typealias PublishResult = NWZServices.PublishResult

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

typealias WikiSpace = NWZWiki.WikiSpace

typealias WikiNode = NWZWiki.WikiNode

typealias WikiAncestor = NWZWiki.WikiAncestor

typealias WikiPageDetail = NWZWiki.WikiPageDetail

typealias WikiRecent = NWZWiki.WikiRecent

typealias WikiVersion = NWZWiki.WikiVersion

typealias WikiComment = NWZWiki.WikiComment

typealias WikiPageHit = NWZWiki.WikiPageHit

typealias WikiQuery = NWZWiki.WikiQuery

typealias WikiSearchResult = NWZWiki.WikiSearchResult

typealias WikiTemplate = NWZWiki.WikiTemplate

typealias WikiEditSession = NWZWiki.WikiEditSession

typealias WikiSavePreview = NWZWiki.WikiSavePreview

typealias WikiIndexSpace = NWZWiki.WikiIndexSpace

typealias WikiIndexProgress = NWZWiki.WikiIndexProgress

typealias WikiIndexStatus = NWZWiki.WikiIndexStatus

typealias WikiToolsSettings = NWZWiki.WikiToolsSettings

typealias WikiPageVersionInfo = NWZWiki.WikiPageVersionInfo

// MARK: - 全局搜索

typealias WikiHit = NWZWiki.WikiHit

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

extension TodoInput {
    var serviceInput: NWZWorkspace.TodoInput {
        .init(id: id, title: title, notes: notes ?? "", done: done ?? false, due: due ?? nil, priority: priority ?? 0, refSystem: refSystem ?? nil, refKey: refKey ?? nil, refTitle: refTitle ?? nil, remindAt: remindAt ?? nil, repeat: self.repeat ?? nil, checklist: checklist ?? [])
    }
}
extension DocInput {
    var serviceInput: NWZWorkspace.DocInput {
        .init(id: id, kind: kind, title: title, content: content, parentId: parentId, tags: tags ?? [], pinned: pinned ?? false, sourceSystem: sourceSystem, sourceKey: sourceKey, sourceUrl: sourceUrl)
    }
}
