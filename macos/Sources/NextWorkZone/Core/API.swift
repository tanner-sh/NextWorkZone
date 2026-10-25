import Foundation
import NWZCore
import NWZServices
import NWZRich
import NWZWorkspace
import NWZPreview
import NWZJira

/// 命令失败时的错误，`message` 可以直接显示给用户。
struct APIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// 可以显示给用户的错误信息。
func errorMessage(_ error: Error) -> String {
    if let e = error as? APIError { return e.message }
    if let e = error as? CoreError, case .Failed(let message) = e { return message }
    return error.localizedDescription
}

/// 界面的类型化入口；已迁移领域直接调用 Swift 服务，其余领域暂时使用过渡桥。
final class API: @unchecked Sendable {
    nonisolated(unsafe) static var shared: API!

    let core: Core

    let settings: SettingsService
    let jira: JiraService
    let workspace: Task<WorkspaceService, Error>

    init(core: Core, settings: SettingsService, jira: JiraService, workspace: Task<WorkspaceService, Error>) {
        self.core = core
        self.settings = settings
        self.jira = jira
        self.workspace = workspace
    }

    /// 调用命令，返回原始 JSON 文本。
    func raw(_ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Data {
        if JiraService.readOnlyCommands.contains(cmd) { return try await jira.readOnly(cmd, arguments: args) }
        if cmd == "get_settings" { return try JSONEncoder().encode(await settings.getSettings()) }
        if cmd == "test_connection" {
            guard let name = args["service"]?.string, let service = Service(rawValue: name) else { throw APIError(message: "缺少系统名称") }
            return try JSONEncoder().encode(await settings.testConnection(service))
        }
        if cmd == "rich_edit_load" { return try JSONEncoder().encode(RichEdit.load(args["html"]?.string ?? "")) }
        if cmd == "rich_markdown_to_storage" { return try JSONEncoder().encode(XHTML.markdownToStorage(args["markdown"]?.string ?? "")) }
        if cmd == "rich_to_xhtml" || cmd == "rich_edit_xhtml" {
            guard let doc = args["doc"]?.decode(RichDoc.self) else { throw APIError(message: "缺少文档") }
            if cmd == "rich_to_xhtml" { return try JSONEncoder().encode(XHTML.write(doc)) }
            guard let segments = args["segments"]?.decode([RichEdit.Segment].self), let baseline = args["baseline"]?.decode(RichDoc.self) else { throw APIError(message: "缺少编辑基线") }
            return try JSONEncoder().encode(RichEdit.xhtml(segments: segments, baseline: baseline, edited: doc))
        }
        if cmd == "rich_from_html" { return try JSONEncoder().encode(HTML.parse(args["html"]?.string ?? "")) }
        if cmd == "rich_html_to_markdown" { return try JSONEncoder().encode(HTML.markdown(args["html"]?.string ?? "", baseURL: args["baseUrl"]?.string ?? "")) }
        if cmd == "rich_to_wiki" {
            guard let doc = args["doc"]?.decode(RichDoc.self) else { throw APIError(message: "缺少文档") }
            return try JSONEncoder().encode(JiraMarkup.write(doc))
        }
        if cmd == "rich_from_markdown" { return try JSONEncoder().encode(Markdown.parse(args["markdown"]?.string ?? "")) }
        if cmd == "rich_to_markdown" {
            guard let doc = args["doc"]?.decode(RichDoc.self) else { throw APIError(message: "缺少文档") }
            return try JSONEncoder().encode(Markdown.write(doc))
        }
        if WorkspaceService.readOnlyCommands.contains(cmd) { return try await workspace.value.readOnly(cmd, arguments: args) }
        let object = JSONValue.object(args)
        let text = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
        do {
            let result = try await core.call(cmd: cmd, args: text)
            return Data(result.utf8)
        } catch let e as CoreError {
            if case .Failed(let message) = e { throw APIError(message: message) }
            throw e
        }
    }

    func call<T: Decodable>(_ cmd: String, _ args: [String: JSONValue] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await raw(cmd, args)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            #if DEBUG
            debugLog("解码 \(cmd) 的结果失败：\(error)")
            #endif
            throw APIError(message: "无法读取 \(cmd) 的结果：\(error)")
        }
    }

    func run(_ cmd: String, _ args: [String: JSONValue] = [:]) async throws {
        _ = try await raw(cmd, args)
    }

    /// 读取图片等资源，路径格式见 crates/app/src/asset.rs。
    func asset(_ path: String) async throws -> (Data, String?) {
        if path.hasPrefix("jira/") { return try await jira.attachments.fetch(service: .jira, url: String(path.dropFirst(5)).removingPercentEncoding ?? String(path.dropFirst(5))) }
        if path.hasPrefix("ws/") {
            guard let asset = try await workspace.value.store.asset(String(path.dropFirst(3))) else { throw APIError(message: "图片尚未同步或不存在") }
            return (asset.data, asset.mime)
        }
        do {
            let a = try await core.asset(path: path)
            return (a.data, a.contentType)
        } catch let e as CoreError {
            if case .Failed(let message) = e { throw APIError(message: message) }
            throw e
        }
    }

    // MARK: 设置

    func getSettings() async throws -> Settings { await settings.getSettings() }
    func saveSettings(_ input: SettingsInput) async throws -> Settings { let result = try await settings.saveSettings(input); await jira.configurationChanged(); return result }
    func clearToken(_ service: Service) async throws -> Settings { try await settings.clearToken(service) }
    func importTokensEnv() async throws -> [Service] { try await settings.importTokensEnv() }
    func testConnection(_ service: Service) async throws -> ConnectionInfo { try await settings.testConnection(service) }

    // MARK: Jira

    func jiraCachedSearch(_ jql: String, fields: [String] = []) async throws -> SearchResult? { try await jira.cachedSearch(jql, fields: fields) }
    func jiraSearch(_ jql: String, startAt: Int = 0, maxResults: Int = 100, fields: [String] = []) async throws -> SearchResult { try await jira.search(jql, startAt: startAt, maxResults: maxResults, fields: fields) }
    func jiraFields(refresh: Bool = false) async throws -> [FieldInfo] { try await jira.fields(refresh: refresh) }
    func jiraMyWorklogs(from: String, to: String) async throws -> [WorklogSum] { try await jira.myWorklogs(from: from, to: to) }
    func jiraIssue(_ key: String) async throws -> IssueDetail { try await jira.issue(key) }
    func jiraTransitions(_ key: String) async throws -> [Transition] { try await jira.client().transitions(key) }
    func jiraTransition(_ key: String, transitionId: String, fields: [String: JSONValue], comment: String?, visibility: CommentVisibility? = nil) async throws -> IssueDetail { try await jira.transition(key, transitionID: transitionId, fields: fields, comment: comment, visibility: visibility) }
    func jiraAddComment(_ key: String, body: String, visibility: CommentVisibility? = nil) async throws -> Comment { try await jira.saveComment(key, body: body, visibility: visibility) }
    func jiraUpdateComment(_ key: String, id: String, body: String, visibility: CommentVisibility?) async throws -> Comment { try await jira.saveComment(key, id: id, body: body, visibility: visibility) }
    func jiraCommentLevels(_ key: String) async throws -> [CommentLevel] { try await jira.commentLevels(key) }
    func jiraDeleteComment(_ key: String, id: String) async throws { try await jira.client().deleteComment(key, id: id) }
    func jiraMe() async throws -> String { try await jira.me() }
    func jiraAssign(_ key: String, assignee: String?) async throws -> IssueDetail { try await jira.assign(key, assignee: assignee) }
    func jiraWatchers(_ key: String) async throws -> Watchers { try await jira.client().watchers(key) }
    func jiraSetWatching(_ key: String, watching: Bool) async throws -> Watchers { try await jira.setWatching(key, watching: watching) }
    func jiraPriorities() async throws -> [Priority] { try await jira.priorities() }
    func jiraSetPriority(_ key: String, priorityId: String) async throws -> IssueDetail { try await jira.updateIssue(key, fields: ["priority": ["id": .string(priorityId)]]) }
    func jiraActivity() async throws -> ActivityFeed { try await jira.activity() }
    func jiraActivityPoll() async throws -> ActivityPoll { try await jira.pollActivity() }
    func jiraActivityRead(_ ids: [String]?) async throws -> ActivityFeed { try await jira.markActivityRead(ids) }
    func jiraPreviewAttachment(url: String, filename: String, mime: String, service: Service = .jira) async throws -> AttachmentPreview { try await jira.attachments.preview(service: service, url: url, filename: filename, mime: mime) }
    func jiraFavouriteFilters() async throws -> [JiraFilter] { try await jira.client().favouriteFilters() }
    func jiraSimilarIssues(_ key: String, summary: String, resolvedOnly: Bool) async throws -> SimilarIssues { try await jira.similarIssues(key: key, summary: summary, resolvedOnly: resolvedOnly) }
    func jiraIndexStatus() async throws -> IndexStatus { try await jira.indexStatus() }
    func jiraIndexSync() async throws { await jira.requestIndexSync() }
    func jiraIndexRebuild() async throws -> IndexStatus { try await jira.rebuildIndex() }
    func jiraIndexSearch(_ query: IndexQuery) async throws -> [IssueHit] { try await jira.searchIndex(query) }
    func jiraViewed(_ keys: [String]) async throws -> Viewed { try await jira.index.viewed(keys) }
    func jiraMarkViewed(_ key: String, updated: String?) async throws -> Int64? { try await jira.markViewed(key, updated: updated) }
    func jiraToolsSettings() async throws -> JiraToolsSettings { await jira.toolsSettings() }
    func jiraSaveToolsSettings(_ settings: JiraToolsSettings) async throws -> JiraToolsSettings { try await jira.saveToolsSettings(settings) }
    func jiraReminders() async throws -> Reminders { try await jira.reminders() }
    func jiraUploadAttachments(_ key: String, paths: [String]) async throws -> [Attachment] { try await jira.uploadAttachments(key, paths: paths) }
    func jiraOpenAttachment(url: String, filename: String, service: Service = .jira) async throws -> String { try await jira.attachments.open(service: service, url: url, filename: filename) }
    func jiraEditFields(_ key: String) async throws -> [FieldMeta] { try await jira.client().editFields(key) }
    func jiraUpdateIssue(_ key: String, fields: [String: JSONValue]) async throws -> IssueDetail { try await jira.updateIssue(key, fields: fields) }
    func jiraCachedCreateProjects() async throws -> [CreateProject]? { try await jira.cachedCreateProjects() }
    func jiraCreateProjects() async throws -> [CreateProject] { try await jira.createProjects() }
    func jiraCreateFields(projectKey: String, issueTypeId: String) async throws -> [FieldMeta] { try await jira.client().createFields(projectKey: projectKey, issueTypeID: issueTypeId) }
    func jiraCreateIssue(fields: [String: JSONValue], attachments: [String]) async throws -> CreatedIssue { try await jira.createIssue(fields: fields, attachments: attachments) }
    func jiraFindUsers(_ query: String, field: String, issueKey: String?, projectKey: String?) async throws -> [UserRef] { try await jira.client().findUsers(query, field: field, issueKey: issueKey, projectKey: projectKey) }
    func jiraSuggestedAssignees(_ key: String) async throws -> [UserRef] { try await jira.suggestedAssignees(key) }
    func jiraSuggestLabels(_ query: String) async throws -> [String] { try await jira.client().suggestLabels(query) }
    func jiraSearchEpics(_ query: String, projectKey: String) async throws -> [IssueRef] { try await jira.client().searchEpics(query, projectKey: projectKey) }
    func jiraPickIssues(_ query: String, projectKey: String?, standardOnly: Bool) async throws -> [IssueSummary] { try await jira.client().pickIssues(query, projectKey: projectKey, standardOnly: standardOnly) }
    func jiraLinkTypes() async throws -> [LinkType] { try await jira.client().linkTypes() }
    func jiraAddLink(_ key: String, typeId: String, other: String, outward: Bool) async throws -> IssueDetail { try await jira.addLink(key, typeID: typeId, other: other, outward: outward) }
    func jiraDeleteLink(_ key: String, linkId: String) async throws -> IssueDetail { try await jira.deleteLink(key, linkID: linkId) }
    func jiraWorklogs(_ key: String) async throws -> [Worklog] { try await jira.client().worklogs(key) }
    func jiraSaveWorklog(_ key: String, id: String?, input: WorklogInput) async throws -> [Worklog] { try await jira.saveWorklog(key, id: id, input: input) }
    func jiraDeleteWorklog(_ key: String, id: String) async throws -> [Worklog] { try await jira.deleteWorklog(key, id: id) }
    func jiraHistory(_ key: String) async throws -> [HistoryEntry] { try await jira.client().history(key) }
    func jiraRenderWiki(_ markup: String, issueKey: String?) async throws -> String { try await jira.client().renderWiki(markup, issueKey: issueKey) }
    func jiraSavePastedImage(base64: String, filename: String) async throws -> String { try jira.attachments.savePastedImage(base64: base64, filename: filename) }

    // MARK: 周报

    func weeklyLoad(section: String? = nil) async throws -> WeeklyView { try await call("weekly_load", ["section": json(section)]) }
    func weeklySave(_ input: WeeklySaveInput) async throws -> SaveResult { try await call("weekly_save", ["input": json(input)]) }
    func weeklyCreateWeek() async throws -> WeeklyView { try await call("weekly_create_week") }
    func weeklyDraft(section: String?) async throws -> WeeklyDraft { try await call("weekly_draft", ["section": json(section)]) }

    // MARK: GitLab

    func glCachedProjects() async throws -> [Project]? { try await call("gl_cached_projects") }
    func glProjects(search: String? = nil) async throws -> [Project] { try await call("gl_projects", ["search": json(search)]) }
    func glProject(_ id: Int) async throws -> Project { try await call("gl_project", ["id": json(id)]) }
    func glBranches(_ project: Int) async throws -> [Branch] { try await call("gl_branches", ["project": json(project)]) }
    func glTree(_ project: Int, ref: String, path: String) async throws -> [TreeEntry] { try await call("gl_tree", ["project": json(project), "gitRef": .string(ref), "path": .string(path)]) }
    func glFile(_ project: Int, ref: String, path: String) async throws -> FileContent { try await call("gl_file", ["project": json(project), "gitRef": .string(ref), "path": .string(path)]) }
    func glCommits(_ project: Int, ref: String, path: String?, page: Int) async throws -> [Commit] {
        try await call("gl_commits", ["project": json(project), "gitRef": .string(ref), "path": json(path), "page": json(page)])
    }
    func glCommit(_ project: Int, sha: String) async throws -> CommitDetail { try await call("gl_commit", ["project": json(project), "sha": .string(sha)]) }
    func glCompare(_ project: Int, from: String, to: String) async throws -> Comparison { try await call("gl_compare", ["project": json(project), "from": .string(from), "to": .string(to)]) }
    func issueCodeRefs(_ key: String, texts: [IssueText]) async throws -> [CodeRef] { try await call("issue_code_refs", ["key": .string(key), "texts": json(texts)]) }
    func codeRelatedIssues(_ target: CodeTarget) async throws -> [IssueHit] { try await call("code_related_issues", ["target": json(target)]) }
    func glMe() async throws -> GlUser { try await call("gl_me") }
    func glMergeRequests(scope: String, query: MrQuery) async throws -> [MergeRequest] { try await call("gl_merge_requests", ["scope": .string(scope), "query": json(query)]) }
    func glProjectMergeRequests(_ project: String, query: MrQuery) async throws -> [MergeRequest] { try await call("gl_project_merge_requests", ["project": .string(project), "query": json(query)]) }
    func glMergeRequest(_ project: String, iid: Int) async throws -> MergeRequest { try await call("gl_merge_request", ["project": .string(project), "iid": json(iid)]) }
    func glMrChanges(_ project: String, iid: Int) async throws -> MrChanges { try await call("gl_mr_changes", ["project": .string(project), "iid": json(iid)]) }
    func glMrCommits(_ project: String, iid: Int) async throws -> [Commit] { try await call("gl_mr_commits", ["project": .string(project), "iid": json(iid)]) }
    func glMrDiscussions(_ project: String, iid: Int) async throws -> [Discussion] { try await call("gl_mr_discussions", ["project": .string(project), "iid": json(iid)]) }
    func glMrApprovals(_ project: String, iid: Int) async throws -> Approvals { try await call("gl_mr_approvals", ["project": .string(project), "iid": json(iid)]) }
    func glMrAddNote(_ project: String, iid: Int, body: String, position: NotePosition? = nil) async throws -> Discussion {
        try await call("gl_mr_add_note", ["project": .string(project), "iid": json(iid), "body": .string(body), "position": json(position)])
    }
    func glMrReply(_ project: String, iid: Int, discussion: String, body: String) async throws -> MrNote {
        try await call("gl_mr_reply", ["project": .string(project), "iid": json(iid), "discussion": .string(discussion), "body": .string(body)])
    }
    func glMrEditNote(_ project: String, iid: Int, note: Int, body: String) async throws -> MrNote {
        try await call("gl_mr_edit_note", ["project": .string(project), "iid": json(iid), "note": json(note), "body": .string(body)])
    }
    func glMrDeleteNote(_ project: String, iid: Int, note: Int) async throws { try await run("gl_mr_delete_note", ["project": .string(project), "iid": json(iid), "note": json(note)]) }
    func glMrResolve(_ project: String, iid: Int, discussion: String, resolved: Bool) async throws -> Discussion {
        try await call("gl_mr_resolve", ["project": .string(project), "iid": json(iid), "discussion": .string(discussion), "resolved": .bool(resolved)])
    }
    func glMrApprove(_ project: String, iid: Int, approve: Bool) async throws -> Approvals { try await call("gl_mr_approve", ["project": .string(project), "iid": json(iid), "approve": .bool(approve)]) }
    func glMrMerge(_ project: String, iid: Int, squash: Bool, removeSourceBranch: Bool, sha: String?) async throws -> MergeRequest {
        try await call("gl_mr_merge", ["project": .string(project), "iid": json(iid), "options": ["squash": .bool(squash), "removeSourceBranch": .bool(removeSourceBranch), "sha": json(sha)]])
    }
    func glMrUpdate(_ project: String, iid: Int, update: [String: JSONValue]) async throws -> MergeRequest {
        try await call("gl_mr_update", ["project": .string(project), "iid": json(iid), "update": .object(update)])
    }
    func glMrCreate(_ project: String, mr: [String: JSONValue]) async throws -> MergeRequest { try await call("gl_mr_create", ["project": .string(project), "mr": .object(mr)]) }

    // MARK: 工作空间

    func wsTodos() async throws -> [Todo] { try await workspace.value.store.todos() }
    func wsSaveTodo(_ input: TodoInput) async throws -> Todo { try await workspace.value.store.saveTodo(input.serviceInput) }
    func wsSetTodoDone(_ id: String, done: Bool) async throws -> Todo { try await workspace.value.setTodoDone(id, done: done) }
    func wsMoveTodo(_ id: String, sort: Double) async throws { try await workspace.value.store.moveTodo(id, sort: sort) }
    func wsDeleteTodo(_ id: String) async throws { try await workspace.value.store.deleteTodo(id) }
    func wsRefreshJiraTodos() async throws -> JiraTodoSync? { try await jira.refreshTodos(in: workspace.value.store) }
    func wsDocs(_ kind: DocKind) async throws -> [DocSummary] { try await workspace.value.store.docs(kind: kind) }
    func wsDoc(_ id: String) async throws -> Doc? { try await workspace.value.doc(id) }
    func wsFullDocs(_ kind: DocKind) async throws -> [Doc] { try await workspace.value.store.fullDocs(kind: kind) }
    func wsDaily(_ day: String) async throws -> Doc { try await workspace.value.store.daily(day) }
    func wsDailyDays() async throws -> [String] { try await workspace.value.store.dailyDays() }
    func wsSaveDoc(_ input: DocInput) async throws -> Doc { try await workspace.value.store.saveDoc(input.serviceInput) }
    func wsMoveDoc(_ id: String, parentId: String?, sort: Double) async throws -> Doc { try await workspace.value.store.moveDoc(id, parentId: parentId, sort: sort) }
    func wsDeleteDoc(_ id: String) async throws -> Int { try await workspace.value.store.deleteDoc(id) }
    func wsTags() async throws -> [TagCount] { try await workspace.value.store.tags() }
    func wsBacklinks(system: String, key: String) async throws -> [Backlink] { try await workspace.value.store.backlinks(system: system, key: key) }
    func wsSearch(_ query: String) async throws -> [WorkspaceHit] { try await workspace.value.store.search(query) }
    func wsSaveAsset(base64: String, mime: String) async throws -> SavedAsset { try await workspace.value.saveAsset(base64: base64, mime: mime) }
    func wsSettings() async throws -> WorkspaceSettings { try await workspace.value.getSettings() }
    func wsSaveSettings(syncDir: String, jiraTodos: Bool) async throws -> WorkspaceSettings { try await workspace.value.saveSettings(syncDir: syncDir, jiraTodos: jiraTodos) }
    func wsSync() async throws -> SyncReport? { try await workspace.value.sync() }
    func wsSaveCaptureShortcut(_ shortcut: String) async throws -> WorkspaceSettings { try await workspace.value.saveCaptureShortcut(shortcut) }
    func wsInbox() async throws -> InboxView { try await workspace.value.inbox() }
    func wsInboxHandle(_ input: InboxHandleInput) async throws { try await workspace.value.handleInbox(input) }
    func wsInboxSnooze(_ id: String, title: String, until: Int64?) async throws { try await workspace.value.snoozeInbox(id, title: title, until: until) }
    func wsWorklog(_ day: String) async throws -> WorkLog { try await workspace.value.worklog(day) }
    func wsWikiPage(_ page: String) async throws -> WsWikiPage { try await call("ws_wiki_page", ["page": .string(page)]) }
    func wsPublishToWiki(docId: String?, mode: String, parent: String, title: String, storage: String, assets: [String]) async throws -> PublishResult {
        try await call("ws_publish_to_wiki", ["docId": json(docId), "mode": .string(mode), "parent": .string(parent), "title": .string(title), "storage": .string(storage), "assets": json(assets)])
    }
    func toolsHidden() async throws -> [String] { try await workspace.value.toolsHidden() }
    func toolsSetHidden(_ hidden: [String]) async throws -> [String] { try await workspace.value.setToolsHidden(hidden) }

    // MARK: 剪贴板

    func clipList(_ query: ClipQuery) async throws -> [ClipItem] { try await call("clip_list", ["query": json(query)]) }
    func clipText(_ id: String) async throws -> ClipText { try await call("clip_text", ["id": .string(id)]) }
    func clipPaste(_ ids: [String], plain: Bool? = nil, edited: String? = nil) async throws -> String { try await call("clip_paste", ["ids": json(ids), "plain": json(plain), "edited": json(edited)]) }
    func clipCopy(_ ids: [String], plain: Bool? = nil, edited: String? = nil) async throws { try await run("clip_copy", ["ids": json(ids), "plain": json(plain), "edited": json(edited)]) }
    func clipDelete(_ ids: [String]) async throws { try await run("clip_delete", ["ids": json(ids)]) }
    func clipClear() async throws -> Int { try await call("clip_clear") }
    func clipSetPinboard(_ ids: [String], pinboard: String?) async throws { try await run("clip_set_pinboard", ["ids": json(ids), "pinboard": json(pinboard)]) }
    func clipRename(_ id: String, title: String) async throws -> ClipItem? { try await call("clip_rename", ["id": .string(id), "title": .string(title)]) }
    func clipUpdateText(_ id: String, text: String) async throws -> ClipItem? { try await call("clip_update_text", ["id": .string(id), "text": .string(text)]) }
    func clipPinboards() async throws -> [Pinboard] { try await call("clip_pinboards") }
    func clipSavePinboard(id: String?, name: String, color: String) async throws -> Pinboard { try await call("clip_save_pinboard", ["id": json(id), "name": .string(name), "color": .string(color)]) }
    func clipDeletePinboard(_ id: String) async throws { try await run("clip_delete_pinboard", ["id": .string(id)]) }
    func clipOrderPinboards(_ ids: [String]) async throws { try await run("clip_order_pinboards", ["ids": json(ids)]) }
    func clipApps() async throws -> [ClipApp] { try await call("clip_apps") }
    func clipIssues(_ keys: [String]) async throws -> [IssueHit] { try await call("clip_issues", ["keys": json(keys)]) }
    func clipSettings() async throws -> ClipSettings { try await call("clip_settings") }
    func clipSaveSettings(_ config: ClipboardConfig) async throws -> ClipSettings { try await call("clip_save_settings", ["config": json(config)]) }
    func clipPause(minutes: Int) async throws -> ClipSettings { try await call("clip_pause", ["minutes": json(minutes)]) }
    func clipRequestPermission() async throws { try await run("clip_request_permission") }
    func clipIgnoreCandidates() async throws -> [IgnoredApp] { try await call("clip_ignore_candidates") }
    func clipTouch(_ ids: [String]) async throws { try await run("clip_touch", ["ids": json(ids)]) }

    // MARK: Wiki

    func wikiCachedSpaces() async throws -> [WikiSpace]? { try await call("wiki_cached_spaces") }
    func wikiSpaces() async throws -> [WikiSpace] { try await call("wiki_spaces") }
    func wikiSpaceRoots(_ space: String) async throws -> [WikiNode] { try await call("wiki_space_roots", ["space": .string(space)]) }
    func wikiChildren(_ page: String) async throws -> [WikiNode] { try await call("wiki_children", ["page": .string(page)]) }
    func wikiPage(_ page: String) async throws -> WikiPageDetail { try await call("wiki_page", ["page": .string(page)]) }
    func wikiResolve(_ input: String) async throws -> String? { try await call("wiki_resolve", ["input": .string(input)]) }
    func wikiAttachments(_ page: String) async throws -> [Attachment] { try await call("wiki_attachments", ["page": .string(page)]) }
    func wikiRecent(limit: Int = 30) async throws -> [WikiRecent] { try await call("wiki_recent", ["limit": json(limit)]) }
    func wikiVersions(_ page: String) async throws -> [WikiVersion] { try await call("wiki_versions", ["page": .string(page)]) }
    func wikiDiff(_ page: String, from: Int, to: Int) async throws -> String { try await call("wiki_diff", ["page": .string(page), "from": json(from), "to": json(to)]) }
    func wikiVersionHtml(_ page: String, version: Int) async throws -> String { try await call("wiki_version_html", ["page": .string(page), "version": json(version)]) }
    func wikiPageVersion(_ page: String) async throws -> WikiPageVersionInfo { try await call("wiki_page_version", ["page": .string(page)]) }
    func wikiComments(_ page: String) async throws -> [WikiComment] { try await call("wiki_comments", ["page": .string(page)]) }
    func wikiAddComment(_ page: String, parent: String?, text: String) async throws -> [WikiComment] {
        try await call("wiki_add_comment", ["page": .string(page), "parent": json(parent), "text": .string(text)])
    }
    func wikiSetTask(_ page: String, task: String, done: Bool) async throws { try await run("wiki_set_task", ["page": .string(page), "task": .string(task), "done": .bool(done)]) }
    func wikiUsers(_ keys: [String]) async throws -> [String: String] { try await call("wiki_users", ["keys": json(keys)]) }
    func wikiSearch(_ query: WikiQuery, server: Bool = false, start: Int = 0) async throws -> WikiSearchResult {
        var q = query
        if q.limit == nil { q.limit = 50 }
        return try await call("wiki_search", ["query": json(q), "server": .bool(server), "start": json(start)])
    }
    func wikiIssuePages(_ key: String) async throws -> [WikiPageHit] { try await call("wiki_issue_pages", ["key": .string(key)]) }
    func wikiEdit(_ page: String) async throws -> WikiEditSession { try await call("wiki_edit", ["page": .string(page)]) }
    func wikiNewPage(space: String, template: String?, storage: String?) async throws -> WikiEditSession {
        try await call("wiki_new_page", ["space": .string(space), "template": json(template), "storage": json(storage)])
    }
    func wikiTemplates(space: String?) async throws -> [WikiTemplate] { try await call("wiki_templates", ["space": json(space)]) }
    func wikiPreviewSave(page: String?, xhtml: String, fragments: [String]) async throws -> WikiSavePreview {
        try await call("wiki_preview_save", ["page": json(page), "xhtml": .string(xhtml), "fragments": json(fragments)])
    }
    func wikiSave(page: String, title: String, xhtml: String, fragments: [String], baseVersion: Int, minorEdit: Bool, message: String) async throws -> Int {
        try await call("wiki_save", ["page": .string(page), "title": .string(title), "xhtml": .string(xhtml), "fragments": json(fragments), "baseVersion": json(baseVersion), "minorEdit": .bool(minorEdit), "message": .string(message)])
    }
    func wikiCreate(space: String, parent: String?, title: String, xhtml: String, fragments: [String]) async throws -> String {
        try await call("wiki_create", ["space": .string(space), "parent": json(parent), "title": .string(title), "xhtml": .string(xhtml), "fragments": json(fragments)])
    }
    func wikiIndexStatus() async throws -> WikiIndexStatus { try await call("wiki_index_status") }
    func wikiIndexSync() async throws { try await run("wiki_index_sync") }
    func wikiIndexRebuild() async throws -> WikiIndexStatus { try await call("wiki_index_rebuild") }
    func wikiToolsSettings() async throws -> WikiToolsSettings { try await call("wiki_tools_settings") }
    func wikiSaveToolsSettings(_ settings: WikiToolsSettings) async throws -> WikiToolsSettings { try await call("wiki_save_tools_settings", ["settings": json(settings)]) }

    // MARK: 搜索与网页登录

    func globalSearch(_ query: String, options: SearchOptions? = nil) async throws -> SearchResults { try await call("global_search", ["query": .string(query), "options": json(options)]) }
    func webAccessStatus() async throws -> [String: WebAccess] { try await call("web_access_status") }
    func webLoginInfo(_ service: Service) async throws -> WebLoginInfo { try await call("web_login_info", ["service": .string(service.rawValue)]) }
    func webLoginFinish(_ service: Service, url: String, cookie: String) async throws -> Bool {
        try await call("web_login_finish", ["service": .string(service.rawValue), "url": .string(url), "cookie": .string(cookie)])
    }
    func webLogout(_ service: Service) async throws { try await run("web_logout", ["service": .string(service.rawValue)]) }
}

/// Rust 发出的事件名称。
enum AppEvent {
    /// 其他设备的修改合并进来、待办有变化。
    static let workspaceSynced = "workspace-synced"
    /// 需要处理的事有变化（稍后提醒到时）。
    static let inbox = "inbox-changed"
    static let clipChanged = "clipboard-changed"
    static let clipSettings = "clipboard-settings"
    static let wikiIndex = "wiki-index-changed"
    static let jiraIndex = "jira-index-changed"
    /// 网页会话状态变化，载荷为服务名。
    static let webSession = "web-session"
}

/// 只有过渡桥保留 JSON，界面与 Swift 服务之间不再进行设置模型的编解码。
private struct RustSettingsBridge: LegacySettingsBridge {
    let core: Core
    func setConfiguration(_ config: AppConfig) throws {
        try core.bridgeSetConfig(json: String(decoding: JSONEncoder().encode(config), as: UTF8.self))
    }
    func setSecrets(_ secrets: [String: String]) throws {
        try core.bridgeSetSecrets(json: String(decoding: JSONEncoder().encode(secrets), as: UTF8.self))
    }
}

extension API {
    static func make(paths: AppPaths, legacyPaths: CorePaths) throws -> API {
        try paths.createDirectories()
        let configuration = try ConfigurationStore(path: paths.config)
        let host = AppHost(configuration: configuration)
        let core = try Core(paths: legacyPaths, host: host)
        let settings = try SettingsService(paths: paths, configuration: configuration, bridge: RustSettingsBridge(core: core))
        let bridge = RustRemoteBridge(core: core)
        let jira = try JiraService(settings: settings, host: host, web: bridge, wikiActivity: bridge)
        Task { await jira.start() }
        let workspace = Task {
            let store = try await Workspace(path: paths.data.appendingPathComponent("workspace.sqlite").path)
            let service = WorkspaceService(store: store, settings: settings, host: host, remote: JiraWorkspaceSources(jira: jira, legacy: bridge))
            await service.start()
            return service
        }
        return API(core: core, settings: settings, jira: jira, workspace: workspace)
    }
}

private struct RustRemoteBridge: WorkspaceRemoteSources, WebResourceSource, WikiActivitySource {
    let core: Core
    private func read<T: Decodable>(_ command: String, _ arguments: [String: JSONValue] = [:]) async throws -> T {
        let args = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
        let result = try await core.call(cmd: command, args: args)
        return try JSONDecoder().decode(T.self, from: Data(result.utf8))
    }
    func fetch(service: Service, url: String) async throws -> (Data, String?) {
        do {
            let result = try await core.asset(path: service.rawValue + "/" + (url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url))
            return (result.data, result.contentType)
        } catch {
            let message = errorMessage(error)
            if message.contains("需要先网页登录") { throw NWZError.sessionRequired(service) }
            throw error
        }
    }
    func events(since: Date, first: Bool) async throws -> [ActivityEvent] { try await read("bridge_wiki_activity", ["since":.string(since.ISO8601Format()), "first":.bool(first)]) }
    func inboxSources() async throws -> InboxView { try await read("bridge_inbox_sources") }
    func workEvents(day: String) async throws -> WorkLog { try await read("bridge_work_events", ["day": .string(day)]) }
    func markActivityRead(_ ids: [String]) async throws {}
    func setWikiTask(page: String, task: String, done: Bool) async throws {
        let _: JSONValue = try await read("wiki_set_task", ["page": .string(page), "task": .string(task), "done": .bool(done)])
    }
}
