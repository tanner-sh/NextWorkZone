import Foundation
import NWZCore
import NWZJira
import NWZWorkspace

public protocol WikiActivitySource: Sendable {
    func events(since: Date, first: Bool) async throws -> [ActivityEvent]
}

public actor JiraService {
    public nonisolated let index: IssueIndex
    public nonisolated let activities: ActivityStore
    public nonisolated let attachments: AttachmentService
    let settings: SettingsService
    let host: any AppHost
    let wikiActivity: (any WikiActivitySource)?
    let cache: FileCache
    var username: (String, String)?
    var indexLoop: Task<Void, Never>?
    var indexTask: Task<Void, Never>?
    var polling: Task<ActivityPoll, Error>?
    var indexRunning = false, indexProgress: IndexProgress?, indexError: String?

    public init(settings: SettingsService, host: any AppHost, web: any WebResourceSource, wikiActivity: (any WikiActivitySource)? = nil) throws {
        self.settings = settings; self.host = host; self.wikiActivity = wikiActivity
        index = try IssueIndex(path: settings.paths.cache.appendingPathComponent("jira-index.sqlite").path)
        activities = try ActivityStore(path: settings.paths.cache.appendingPathComponent("activity.sqlite").path)
        attachments = AttachmentService(settings: settings, web: web, host: host)
        cache = FileCache(directory: settings.paths.cache.appendingPathComponent("responses", isDirectory: true))
    }
    deinit { indexLoop?.cancel(); indexTask?.cancel(); polling?.cancel() }
    public func client() async throws -> JiraClient { try await JiraClient(rest: settings.restClient(.jira)) }
    public func me() async throws -> String {
        let client = try await client(), identity = client.rest.cacheIdentity
        if let (cachedIdentity, name) = username, identity == cachedIdentity { return name }
        let name = try await client.myUsername(); username = (identity, name); return name
    }
    func cacheKey(_ key: String) async throws -> String { try await client().rest.cacheIdentity + ":" + key }
    public func cachedSearch(_ jql: String, fields: [String]) async throws -> SearchResult? {
        await cache.get(try cacheKey("search:" + jql + "|" + fields.joined(separator: ",")), as: SearchResult.self)
    }
    public func search(_ jql: String, startAt: Int, maxResults: Int, fields: [String]) async throws -> SearchResult {
        let result = try await client().search(jql, startAt: startAt, maxResults: maxResults, fields: fields)
        if startAt == 0 { await cache.put(try cacheKey("search:" + jql + "|" + fields.joined(separator: ",")), value: result) }
        return result
    }
    public func fields(refresh: Bool = false) async throws -> [FieldInfo] {
        let key = try await cacheKey("fields")
        if !refresh, let fields = await cache.get(key, as: [FieldInfo].self) { return fields }
        let fields = try await client().listFields(); await cache.put(key, value: fields); return fields
    }
    public func issue(_ key: String) async throws -> IssueDetail {
        async let loaded = client().issue(key)
        async let name = try? me()
        var issue = try await loaded
        let me = await name ?? ""
        for index in issue.comments.indices { issue.comments[index].markMine(me) }
        return issue
    }
    public func transition(_ key: String, transitionID: String, fields: [String: JSONValue], comment: String?, visibility: CommentVisibility?) async throws -> IssueDetail {
        let client = try await client()
        try await client.transition(key, transitionID: transitionID, fields: fields)
        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty { _ = try await client.saveComment(key, body: comment, visibility: visibility) }
        return try await issue(key)
    }
    public func saveComment(_ key: String, id: String? = nil, body: String, visibility: CommentVisibility?) async throws -> Comment {
        var comment = try await client().saveComment(key, id: id, body: body, visibility: visibility)
        comment.markMine((try? await me()) ?? ""); return comment
    }
    public func commentLevels(_ key: String) async throws -> [CommentLevel] {
        let cacheKey = try await cacheKey("comment-levels:" + JiraIndexText.project(key))
        if let levels = await cache.get(cacheKey, as: [CommentLevel].self) { return levels }
        let id = try await client().get(JiraClient.issuePath(key), query: [("fields", "summary")])["id"].text
        do {
            let (data, _) = try await attachments.fetch(service: .jira, url: "/secure/AddComment!default.jspa?id=" + RESTClient.component(id))
            let levels = JiraForms.commentLevels(String(decoding: data, as: UTF8.self))
            if !levels.isEmpty { await cache.put(cacheKey, value: levels) }; return levels
        } catch NWZError.sessionRequired { return [] }
    }
    public func suggestedAssignees(_ key: String) async throws -> [UserRef] {
        let id = try await client().get(JiraClient.issuePath(key), query: [("fields", "summary")])["id"].text
        do {
            let (data, _) = try await attachments.fetch(service: .jira, url: "/secure/AssignIssue!default.jspa?id=" + RESTClient.component(id))
            return JiraForms.suggestedAssignees(String(decoding: data, as: UTF8.self))
        } catch NWZError.sessionRequired { return [] }
    }
    public func assign(_ key: String, assignee: String?) async throws -> IssueDetail { try await client().assign(key, username: assignee); return try await issue(key) }
    public func setWatching(_ key: String, watching: Bool) async throws -> Watchers {
        let client = try await client(); try await client.setWatching(key, me: me(), watching: watching); return try await client.watchers(key)
    }
    public func priorities() async throws -> [Priority] {
        let key = try await cacheKey("priorities")
        if let priorities = await cache.get(key, as: [Priority].self) { return priorities }
        let priorities = try await client().priorities(); await cache.put(key, value: priorities); return priorities
    }
    public func updateIssue(_ key: String, fields: [String: JSONValue]) async throws -> IssueDetail { try await client().updateIssue(key, fields: fields); return try await issue(key) }
    public func uploadAttachments(_ key: String, paths: [String]) async throws -> [Attachment] {
        let client = try await client()
        return try await UploadProgress.sequence(paths.map(UploadProgress.fileSize)) { try await client.uploadAttachment(key, file: URL(fileURLWithPath: paths[$0])) }.flatMap { $0 }
    }
    public func cachedCreateProjects() async throws -> [CreateProject]? { await cache.get(try cacheKey("createProjects"), as: [CreateProject].self) }
    public func createProjects() async throws -> [CreateProject] {
        let result = try await client().createProjects(); await cache.put(try cacheKey("createProjects"), value: result); return result
    }
    public func createIssue(fields: [String: JSONValue], attachments: [String]) async throws -> CreatedIssue {
        let client = try await client(), key = try await client.createIssue(fields: fields)
        for path in attachments {
            do { _ = try await client.uploadAttachment(key, file: URL(fileURLWithPath: path)) }
            catch { return CreatedIssue(key: key, attachmentError: URL(fileURLWithPath: path).lastPathComponent + "：" + error.localizedDescription) }
        }
        return CreatedIssue(key: key)
    }
    public func addLink(_ key: String, typeID: String, other: String, outward: Bool) async throws -> IssueDetail { try await client().addLink(key, typeID: typeID, other: other, outward: outward); return try await issue(key) }
    public func deleteLink(_ key: String, linkID: String) async throws -> IssueDetail { try await client().deleteLink(linkID); return try await issue(key) }
    public func saveWorklog(_ key: String, id: String?, input: WorklogInput) async throws -> [Worklog] { let client = try await client(); try await client.saveWorklog(key, id: id, input: input); return try await client.worklogs(key) }
    public func deleteWorklog(_ key: String, id: String) async throws -> [Worklog] { let client = try await client(); try await client.deleteWorklog(key, id: id); return try await client.worklogs(key) }
    public func myWorklogs(from: String, to: String) async throws -> [WorklogSum] {
        try await client().myWorklogs(me: me(), from: from, to: to).map { WorklogSum(key: $0.0.key, summary: $0.0.summary, seconds: $0.1.reduce(0) { $0 + $1.timeSpentSeconds }) }
    }
    public func refreshTodos(in workspace: Workspace) async throws -> JiraTodoSync? {
        guard settings.configuration.snapshot().workspace.jiraTodos else { return nil }
        let result = try await client().search("assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC", maxResults: 500)
        guard result.issues.count >= result.total else { throw NWZError.other("分配给我的问题有 \(result.total) 个，超过一次能获取的数量") }
        return try await workspace.syncJiraTodos(result.issues.map { AssignedIssue(key: $0.key, summary: $0.summary, due: $0.dueDate) })
    }
}
