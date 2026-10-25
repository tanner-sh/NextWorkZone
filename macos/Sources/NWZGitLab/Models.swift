import Foundation

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public init(id: Int = 0, name: String = "", pathWithNamespace: String = "", description: String? = nil, defaultBranch: String? = nil, webUrl: String = "", lastActivityAt: String = "", removeSourceBranchAfterMerge: Bool? = nil, squashOption: String? = nil) {
        self.id = id; self.name = name; self.pathWithNamespace = pathWithNamespace; self.description = description; self.defaultBranch = defaultBranch; self.webUrl = webUrl; self.lastActivityAt = lastActivityAt; self.removeSourceBranchAfterMerge = removeSourceBranchAfterMerge; self.squashOption = squashOption
    }
    public var id: Int
    public var name: String
    public var pathWithNamespace: String
    public var description: String?
    public var defaultBranch: String?
    public var webUrl: String
    public var lastActivityAt: String
    public var removeSourceBranchAfterMerge: Bool?
    public var squashOption: String?
}

public struct Commit: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", shortId: String = "", title: String = "", message: String = "", authorName: String = "", authoredDate: String = "", webUrl: String? = nil) {
        self.id = id; self.shortId = shortId; self.title = title; self.message = message; self.authorName = authorName; self.authoredDate = authoredDate; self.webUrl = webUrl
    }
    public var id: String
    public var shortId: String
    public var title: String
    public var message: String
    public var authorName: String
    public var authoredDate: String
    public var webUrl: String?
}

public struct CodeRefSource: Codable, Hashable, Sendable {
    public init(kind: String = "", author: String? = nil, at: String? = nil, commentId: String? = nil) {
        self.kind = kind; self.author = author; self.at = at; self.commentId = commentId
    }
    /// description / comment / mrSearch / commitSearch
    public var kind: String
    public var author: String?
    public var at: String?
    public var commentId: String?
}

public struct CodeRef: Codable, Hashable, Sendable {
    public init(kind: String = "", url: String = "", projectId: Int? = nil, projectPath: String = "", projectName: String = "", branch: String? = nil, sha: String? = nil, iid: Int? = nil, title: String = "", state: String? = nil, pipeline: String? = nil, author: String? = nil, at: String? = nil, commits: [Commit] = [], unavailable: String? = nil, sources: [CodeRefSource] = []) {
        self.kind = kind; self.url = url; self.projectId = projectId; self.projectPath = projectPath; self.projectName = projectName; self.branch = branch; self.sha = sha; self.iid = iid; self.title = title; self.state = state; self.pipeline = pipeline; self.author = author; self.at = at; self.commits = commits; self.unavailable = unavailable; self.sources = sources
    }
    /// mr / branch / commit / external
    public var kind: String
    public var url: String
    public var projectId: Int?
    public var projectPath: String
    public var projectName: String
    public var branch: String?
    public var sha: String?
    public var iid: Int?
    public var title: String
    public var state: String?
    public var pipeline: String?
    public var author: String?
    public var at: String?
    public var commits: [Commit]
    public var unavailable: String?
    public var sources: [CodeRefSource]
}

public struct IssueText: Codable, Hashable, Sendable {
    public init(source: String = "", commentId: String? = nil, author: String? = nil, at: String? = nil, html: String = "") {
        self.source = source; self.commentId = commentId; self.author = author; self.at = at; self.html = html
    }
    /// description / comment
    public var source: String
    public var commentId: String?
    public var author: String?
    public var at: String?
    public var html: String
}

public struct CodeTarget: Codable, Hashable, Sendable {
    public init(projectPath: String = "", branch: String? = nil, sha: String? = nil, iid: Int? = nil, text: String = "") {
        self.projectPath = projectPath; self.branch = branch; self.sha = sha; self.iid = iid; self.text = text
    }
    public var projectPath: String
    public var branch: String?
    public var sha: String?
    public var iid: Int?
    public var text: String
}

public struct Branch: Codable, Hashable, Sendable, Identifiable {
    public init(name: String = "", `default`: Bool = false, protected: Bool = false, merged: Bool = false, commit: Commit = Commit()) {
        self.name = name; self.`default` = `default`; self.protected = protected; self.merged = merged; self.commit = commit
    }
    public var name: String
    public var `default`: Bool
    public var protected: Bool
    public var merged: Bool
    public var commit: Commit
    public var id: String { name }
}

public struct TreeEntry: Codable, Hashable, Sendable, Identifiable {
    public init(name: String = "", path: String = "", kind: String = "") {
        self.name = name; self.path = path; self.kind = kind
    }
    public var name: String
    public var path: String
    /// tree / blob / commit
    public var kind: String
    public var id: String { path }
}

public struct FileContent: Codable, Hashable, Sendable {
    public init(path: String = "", size: Int = 0, text: String? = nil, imageDataUrl: String? = nil, tooLarge: Bool = false, binary: Bool = false) {
        self.path = path; self.size = size; self.text = text; self.imageDataUrl = imageDataUrl; self.tooLarge = tooLarge; self.binary = binary
    }
    public var path: String
    public var size: Int
    public var text: String?
    public var imageDataUrl: String?
    public var tooLarge: Bool
    public var binary: Bool
}

public struct FileDiff: Codable, Hashable, Sendable, Identifiable {
    public init(oldPath: String = "", newPath: String = "", diff: String = "", newFile: Bool = false, deletedFile: Bool = false, renamedFile: Bool = false) {
        self.oldPath = oldPath; self.newPath = newPath; self.diff = diff; self.newFile = newFile; self.deletedFile = deletedFile; self.renamedFile = renamedFile
    }
    public var oldPath: String
    public var newPath: String
    public var diff: String
    public var newFile: Bool
    public var deletedFile: Bool
    public var renamedFile: Bool
    public var id: String { oldPath + "→" + newPath }
}

public struct CommitDetail: Codable, Hashable, Sendable {
    public init(commit: Commit = Commit(), diffs: [FileDiff] = []) {
        self.commit = commit; self.diffs = diffs
    }
    public var commit: Commit
    public var diffs: [FileDiff]
}

public struct Comparison: Codable, Hashable, Sendable {
    public init(commits: [Commit] = [], diffs: [FileDiff] = []) {
        self.commits = commits; self.diffs = diffs
    }
    public var commits: [Commit]
    public var diffs: [FileDiff]
}

public struct MrChanges: Codable, Hashable, Sendable {
    public init(diffs: [FileDiff] = [], overflow: Bool = false) {
        self.diffs = diffs; self.overflow = overflow
    }
    public var diffs: [FileDiff]
    public var overflow: Bool
}

public struct GlUser: Codable, Hashable, Sendable, Identifiable {
    public init(id: Int = 0, username: String = "", name: String = "") {
        self.id = id; self.username = username; self.name = name
    }
    public var id: Int
    public var username: String
    public var name: String
}

public struct DiffRefs: Codable, Hashable, Sendable {
    public init(baseSha: String = "", headSha: String = "", startSha: String = "") {
        self.baseSha = baseSha; self.headSha = headSha; self.startSha = startSha
    }
    public var baseSha: String
    public var headSha: String
    public var startSha: String
}

public struct Pipeline: Codable, Hashable, Sendable {
    public init(id: Int = 0, status: String = "", webUrl: String? = nil) {
        self.id = id; self.status = status; self.webUrl = webUrl
    }
    public var id: Int
    public var status: String
    public var webUrl: String?
}

public struct MergeRequest: Codable, Hashable, Sendable, Identifiable {
    public init(id: Int = 0, iid: Int = 0, projectId: Int = 0, title: String = "", description: String = "", state: String = "", draft: Bool = false, author: GlUser = GlUser(), assignees: [GlUser] = [], reviewers: [GlUser] = [], sourceBranch: String = "", targetBranch: String = "", sourceProjectId: Int? = nil, createdAt: String = "", updatedAt: String = "", mergedAt: String? = nil, mergedBy: GlUser? = nil, closedAt: String? = nil, closedBy: GlUser? = nil, mergeStatus: String = "", hasConflicts: Bool = false, userNotesCount: Int = 0, upvotes: Int = 0, labels: [String] = [], webUrl: String = "", reference: String = "", changesCount: String? = nil, sha: String? = nil, diffRefs: DiffRefs? = nil, headPipeline: Pipeline? = nil, squash: Bool = false, forceRemoveSourceBranch: Bool? = nil, blockingDiscussionsResolved: Bool = false, mergeError: String? = nil, mergeWhenPipelineSucceeds: Bool = false, canMerge: Bool = false) {
        self.id = id; self.iid = iid; self.projectId = projectId; self.title = title; self.description = description; self.state = state; self.draft = draft; self.author = author; self.assignees = assignees; self.reviewers = reviewers; self.sourceBranch = sourceBranch; self.targetBranch = targetBranch; self.sourceProjectId = sourceProjectId; self.createdAt = createdAt; self.updatedAt = updatedAt; self.mergedAt = mergedAt; self.mergedBy = mergedBy; self.closedAt = closedAt; self.closedBy = closedBy; self.mergeStatus = mergeStatus; self.hasConflicts = hasConflicts; self.userNotesCount = userNotesCount; self.upvotes = upvotes; self.labels = labels; self.webUrl = webUrl; self.reference = reference; self.changesCount = changesCount; self.sha = sha; self.diffRefs = diffRefs; self.headPipeline = headPipeline; self.squash = squash; self.forceRemoveSourceBranch = forceRemoveSourceBranch; self.blockingDiscussionsResolved = blockingDiscussionsResolved; self.mergeError = mergeError; self.mergeWhenPipelineSucceeds = mergeWhenPipelineSucceeds; self.canMerge = canMerge
    }
    public var id: Int
    public var iid: Int
    public var projectId: Int
    public var title: String
    public var description: String
    /// opened / merged / closed / locked
    public var state: String
    public var draft: Bool
    public var author: GlUser
    public var assignees: [GlUser]
    public var reviewers: [GlUser]
    public var sourceBranch: String
    public var targetBranch: String
    public var sourceProjectId: Int?
    public var createdAt: String
    public var updatedAt: String
    public var mergedAt: String?
    public var mergedBy: GlUser?
    public var closedAt: String?
    public var closedBy: GlUser?
    public var mergeStatus: String
    public var hasConflicts: Bool
    public var userNotesCount: Int
    public var upvotes: Int
    public var labels: [String]
    public var webUrl: String
    public var reference: String
    public var changesCount: String?
    public var sha: String?
    public var diffRefs: DiffRefs?
    public var headPipeline: Pipeline?
    public var squash: Bool
    public var forceRemoveSourceBranch: Bool?
    public var blockingDiscussionsResolved: Bool
    public var mergeError: String?
    public var mergeWhenPipelineSucceeds: Bool
    public var canMerge: Bool
}

public struct NotePosition: Codable, Hashable, Sendable {
    public init(baseSha: String = "", startSha: String = "", headSha: String = "", oldPath: String = "", newPath: String = "", oldLine: Int? = nil, newLine: Int? = nil) {
        self.baseSha = baseSha; self.startSha = startSha; self.headSha = headSha; self.oldPath = oldPath; self.newPath = newPath; self.oldLine = oldLine; self.newLine = newLine
    }
    public var baseSha: String
    public var startSha: String
    public var headSha: String
    public var oldPath: String
    public var newPath: String
    public var oldLine: Int?
    public var newLine: Int?
}

public struct MrNote: Codable, Hashable, Sendable, Identifiable {
    public init(id: Int = 0, body: String = "", author: GlUser = GlUser(), createdAt: String = "", updatedAt: String? = nil, system: Bool = false, resolvable: Bool = false, resolved: Bool = false, resolvedBy: GlUser? = nil, position: NotePosition? = nil) {
        self.id = id; self.body = body; self.author = author; self.createdAt = createdAt; self.updatedAt = updatedAt; self.system = system; self.resolvable = resolvable; self.resolved = resolved; self.resolvedBy = resolvedBy; self.position = position
    }
    public var id: Int
    public var body: String
    public var author: GlUser
    public var createdAt: String
    public var updatedAt: String?
    public var system: Bool
    public var resolvable: Bool
    public var resolved: Bool
    public var resolvedBy: GlUser?
    public var position: NotePosition?
}

public struct Discussion: Codable, Hashable, Sendable, Identifiable {
    public init(id: String = "", individualNote: Bool = false, notes: [MrNote] = []) {
        self.id = id; self.individualNote = individualNote; self.notes = notes
    }
    public var id: String
    public var individualNote: Bool
    public var notes: [MrNote]
}

public struct Approvals: Codable, Hashable, Sendable {
    public init(approved: Bool = false, userHasApproved: Bool = false, userCanApprove: Bool = false, approvedBy: [GlUser] = []) {
        self.approved = approved; self.userHasApproved = userHasApproved; self.userCanApprove = userCanApprove; self.approvedBy = approvedBy
    }
    public var approved: Bool
    public var userHasApproved: Bool
    public var userCanApprove: Bool
    public var approvedBy: [GlUser]
}

public struct MrQuery: Codable, Hashable, Sendable {
    public init(state: String? = nil, search: String? = nil, sourceBranch: String? = nil, page: Int? = nil) {
        self.state = state; self.search = search; self.sourceBranch = sourceBranch; self.page = page
    }
    /// opened / merged / closed / all
    public var state: String?
    public var search: String?
    public var sourceBranch: String?
    public var page: Int?
}

public enum MrScope: String, Codable, Sendable {
    case createdByMe = "created_by_me", assignedToMe = "assigned_to_me", reviewer
}
public struct MergeOptions: Codable, Hashable, Sendable {
    public var squash: Bool
    public var removeSourceBranch: Bool
    public var sha: String?
    public init(squash: Bool, removeSourceBranch: Bool, sha: String? = nil) { self.squash = squash; self.removeSourceBranch = removeSourceBranch; self.sha = sha }
}
public struct MrUpdate: Codable, Hashable, Sendable {
    public var title: String?
    public var description: String?
    public var targetBranch: String?
    public var stateEvent: String?
    public var removeSourceBranch: Bool?
    public var squash: Bool?
    public init(title: String? = nil, description: String? = nil, targetBranch: String? = nil, stateEvent: String? = nil, removeSourceBranch: Bool? = nil, squash: Bool? = nil) {
        self.title = title; self.description = description; self.targetBranch = targetBranch; self.stateEvent = stateEvent; self.removeSourceBranch = removeSourceBranch; self.squash = squash
    }
}
public struct NewMergeRequest: Codable, Hashable, Sendable {
    public var sourceBranch: String
    public var targetBranch: String
    public var title: String
    public var description: String
    public var removeSourceBranch: Bool
    public var squash: Bool
    public init(sourceBranch: String, targetBranch: String, title: String, description: String, removeSourceBranch: Bool, squash: Bool) {
        self.sourceBranch = sourceBranch; self.targetBranch = targetBranch; self.title = title; self.description = description; self.removeSourceBranch = removeSourceBranch; self.squash = squash
    }
}
