import Foundation
import NWZCore
import NWZServices
import NWZRich
import NWZWorkspace
import NWZPreview
import NWZWiki
import NWZGitLab
import NWZJira
import NWZClipboard

/// 命令失败时的错误，`message` 可以直接显示给用户。
struct APIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// 可以显示给用户的错误信息。
func errorMessage(_ error: Error) -> String {
    if let e = error as? APIError { return e.message }
    return error.localizedDescription
}

/// 任务被取消（切换了条目、关闭了对话框）：不是失败，结果也已过时，不应写入界面状态。
/// URLSession 被取消时抛出的是 URLError.cancelled（中文描述“已取消”），不是 CancellationError。
func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if (error as? URLError)?.code == .cancelled { return true }
    return Task.isCancelled
}

/// 界面的类型化入口：各方法直接调用 Swift 服务。
final class API: @unchecked Sendable {
    nonisolated(unsafe) static var shared: API!

    let settings: SettingsService
    let jira: JiraService
    let wiki: WikiService
    let gitlab: GitLabService
    let weekly: WeeklyService
    let clipboard: ClipboardService
    let sessions: WebSessionService
    let workspace: Task<WorkspaceService, Error>

    init(settings: SettingsService, jira: JiraService, wiki: WikiService, weekly: WeeklyService, gitlab: GitLabService, clipboard: ClipboardService, sessions: WebSessionService, workspace: Task<WorkspaceService, Error>) {
        self.settings = settings
        self.jira = jira
        self.wiki = wiki; self.weekly = weekly; self.gitlab = gitlab; self.clipboard = clipboard; self.sessions = sessions
        self.workspace = workspace
    }

    /// 按命令名调用只读命令，返回 JSON（调试通道使用，命令名与原来的应用层命令相同）。
    func raw(_ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Data {
        if GitLabDebug.commands.contains(cmd) || ["gl_cached_projects", "issue_code_refs", "code_related_issues"].contains(cmd) { return try await gitlab.readOnly(cmd, arguments: args) }
        if WikiService.readOnlyCommands.contains(cmd) { return try await wiki.readOnly(cmd, arguments: args) }
        if cmd == "weekly_load" { return try await JSONEncoder().encode(weekly.load(section: args["section"]?.string)) }
        if cmd == "weekly_draft" { return try await JSONEncoder().encode(weekly.draft(section: args["section"]?.string, workspace: workspace.value.store)) }
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
        if ClipboardService.readOnlyCommands.contains(cmd) { return try await clipboard.readOnly(cmd, arguments: args) }
        if cmd == "global_search" { return try JSONEncoder().encode(await globalSearch(args["query"]?.string ?? "", options: args["options"]?.decode(SearchOptions.self))) }
        if cmd == "web_access_status" { return try JSONEncoder().encode(await webAccessStatus()) }
        throw APIError(message: "未知命令 \(cmd)")
    }

    /// 读取图片等资源（各页面的图片加载都使用它）：
    /// - `ws/<图片 id>`：工作空间里的图片；
    /// - `clip/<thumb|image|icon>/<id>`：剪贴板历史中的图片和来源应用图标；
    /// - `<jira|confluence|gitlab>/<编码后的路径或完整地址>`：带上对应系统的凭据去取回内容，只允许访问已配置系统的地址。
    func asset(_ path: String) async throws -> (Data, String?) {
        if path.hasPrefix("confluence/") { return try await wiki.attachments.fetch(service: .confluence, url: String(path.dropFirst(11)).removingPercentEncoding ?? String(path.dropFirst(11))) }
        if path.hasPrefix("gitlab/") { return try await gitlab.attachments.fetch(service: .gitlab, url: String(path.dropFirst(7)).removingPercentEncoding ?? String(path.dropFirst(7))) }
        if path.hasPrefix("jira/") { return try await jira.attachments.fetch(service: .jira, url: String(path.dropFirst(5)).removingPercentEncoding ?? String(path.dropFirst(5))) }
        if path.hasPrefix("ws/") {
            guard let asset = try await workspace.value.store.asset(String(path.dropFirst(3))) else { throw APIError(message: "图片尚未同步或不存在") }
            return (asset.data, asset.mime)
        }
        // clip/<thumb|image|icon>/<id>：剪贴板历史中的图片和来源应用图标
        if path.hasPrefix("clip/") {
            let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { throw APIError(message: "无效的图片地址") }
            let store = clipboard.store
            let url = switch parts[1] { case "thumb": store.thumbURL(parts[2]); case "image": store.imageURL(parts[2]); default: store.iconURL(parts[2]) }
            guard let data = try? Data(contentsOf: url) else { throw APIError(message: "图片已丢失") }
            return (data, "image/png")
        }
        throw APIError(message: "无效的图片地址")
    }

    // MARK: 设置

    func getSettings() async throws -> Settings { await settings.getSettings() }
    func saveSettings(_ input: SettingsInput) async throws -> Settings { let result = try await settings.saveSettings(input); await jira.configurationChanged(); await wiki.configurationChanged(); await gitlab.configurationChanged(); await sessions.configurationChanged(); return result }
    func clearToken(_ service: Service) async throws -> Settings { try await settings.clearToken(service) }
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
    func jiraSetWatcher(_ key: String, username: String, watching: Bool) async throws -> Watchers {
        let client = try await jira.client()
        try await client.setWatcher(key, username: username, watching: watching)
        return try await client.watchers(key)
    }
    func jiraVotes(_ key: String) async throws -> Votes { try await jira.client().votes(key) }
    func jiraSetVote(_ key: String, voted: Bool) async throws -> Votes {
        let client = try await jira.client()
        try await client.setVote(key, voted: voted)
        return try await client.votes(key)
    }
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
    func jiraDeleteAttachment(id: String) async throws { try await jira.client().deleteAttachment(id: id) }
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

    func weeklyLoad(section: String? = nil) async throws -> WeeklyView { try await weekly.load(section: section) }
    func weeklySave(_ input: WeeklySaveInput) async throws -> SaveResult { try await weekly.save(input) }
    func weeklyCreateWeek() async throws -> WeeklyView { try await weekly.createWeek() }
    func weeklyDraft(section: String?) async throws -> WeeklyDraft { try await weekly.draft(section: section, workspace: workspace.value.store) }

    // MARK: GitLab

    func glCachedProjects() async throws -> [Project]? { try await gitlab.cachedProjects() }
    func glProjects(search: String? = nil) async throws -> [Project] { try await gitlab.projects(search: search) }
    func glProject(_ id: Int) async throws -> Project { try await gitlab.client().project(id) }
    func glBranches(_ project: Int) async throws -> [Branch] { try await gitlab.client().branches(project) }
    func glTree(_ project: Int, ref: String, path: String) async throws -> [TreeEntry] { try await gitlab.client().tree(project, ref: ref, path: path) }
    func glFile(_ project: Int, ref: String, path: String) async throws -> FileContent { try await gitlab.client().file(project, ref: ref, path: path) }
    func glFileRaw(_ project: Int, ref: String, path: String) async throws -> Data { try await gitlab.client().rawFile(project, ref: ref, path: path) }
    func glCommits(_ project: Int, ref: String, path: String?, page: Int) async throws -> [Commit] { try await gitlab.client().commits(project, ref: ref, path: path, page: page) }
    func glCommit(_ project: Int, sha: String) async throws -> CommitDetail { try await gitlab.client().commit(project, sha: sha) }
    func glCompare(_ project: Int, from: String, to: String) async throws -> Comparison { try await gitlab.client().compare(project, from: from, to: to) }
    func issueCodeRefs(_ key: String, texts: [IssueText]) async throws -> [CodeRef] { await gitlab.issueCodeRefs(key, texts: texts) }
    func codeRelatedIssues(_ target: CodeTarget) async throws -> [IssueHit] { try await gitlab.relatedIssues(target) }
    func glMe() async throws -> GlUser { try await gitlab.client().currentUser() }
    func glMergeRequests(scope: String, query: MrQuery) async throws -> [MergeRequest] { guard let scope = NWZGitLab.MrScope(rawValue: scope) else { throw APIError(message: "无法识别的合并请求范围") }; return try await gitlab.client().mergeRequests(scope: scope, query: query) }
    func glProjectMergeRequests(_ project: String, query: MrQuery) async throws -> [MergeRequest] { try await gitlab.client().projectMergeRequests(project, query: query) }
    func glMergeRequest(_ project: String, iid: Int) async throws -> MergeRequest { try await gitlab.client().mergeRequest(project, iid: iid) }
    func glMrChanges(_ project: String, iid: Int) async throws -> MrChanges { try await gitlab.client().mrChanges(project, iid: iid) }
    func glMrCommits(_ project: String, iid: Int) async throws -> [Commit] { try await gitlab.client().mrCommits(project, iid: iid) }
    func glMrDiscussions(_ project: String, iid: Int) async throws -> [Discussion] { try await gitlab.client().mrDiscussions(project, iid: iid) }
    func glMrApprovals(_ project: String, iid: Int) async throws -> Approvals { try await gitlab.client().mrApprovals(project, iid: iid) }
    func glMrAddNote(_ project: String, iid: Int, body: String, position: NotePosition? = nil) async throws -> Discussion { try await gitlab.client().mrAddNote(project, iid: iid, body: body, position: position) }
    func glMrReply(_ project: String, iid: Int, discussion: String, body: String) async throws -> MrNote { try await gitlab.client().mrReply(project, iid: iid, discussion: discussion, body: body) }
    func glMrEditNote(_ project: String, iid: Int, note: Int, body: String) async throws -> MrNote { try await gitlab.client().mrEditNote(project, iid: iid, note: note, body: body) }
    func glMrDeleteNote(_ project: String, iid: Int, note: Int) async throws { try await gitlab.client().mrDeleteNote(project, iid: iid, note: note) }
    func glMrResolve(_ project: String, iid: Int, discussion: String, resolved: Bool) async throws -> Discussion { try await gitlab.client().mrResolve(project, iid: iid, discussion: discussion, resolved: resolved) }
    func glInboxChanged() async { await gitlab.inboxChanged() }
    func glMrApprove(_ project: String, iid: Int, approve: Bool) async throws -> Approvals { try await gitlab.client().mrApprove(project, iid: iid, approve: approve) }
    func glMrMerge(_ project: String, iid: Int, squash: Bool, removeSourceBranch: Bool, sha: String?) async throws -> MergeRequest { try await gitlab.client().mrMerge(project, iid: iid, options: MergeOptions(squash: squash, removeSourceBranch: removeSourceBranch, sha: sha)) }
    func glMrUpdate(_ project: String, iid: Int, update: MrUpdate) async throws -> MergeRequest { try await gitlab.client().mrUpdate(project, iid: iid, update: update) }
    func glMrCreate(_ project: String, mr: NewMergeRequest) async throws -> MergeRequest { try await gitlab.client().mrCreate(project, input: mr) }

    // MARK: 工作空间

    func wsTodos() async throws -> [Todo] { try await workspace.value.store.todos() }
    func wsSaveTodo(_ input: TodoInput) async throws -> Todo { try await workspace.value.store.saveTodo(input.serviceInput) }
    func wsSetTodoDone(_ id: String, done: Bool) async throws -> Todo { try await workspace.value.setTodoDone(id, done: done) }
    func wsMoveTodo(_ id: String, sort: Double) async throws { try await workspace.value.store.moveTodo(id, sort: sort) }
    func wsDeleteTodo(_ id: String) async throws { try await workspace.value.store.deleteTodo(id) }
    func wsRestoreTodo(_ id: String) async throws -> Todo { try await workspace.value.store.restoreTodo(id) }
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
    func wsWikiPage(_ page: String) async throws -> WsWikiPage { try await wiki.workspacePage(page) }
    func wsPublishToWiki(docId: String?, mode: String, parent: String, title: String, storage: String, assets: [String]) async throws -> PublishResult { try await wiki.publish(docID: docId, mode: mode, parent: parent, title: title, storage: storage, assets: assets, workspace: workspace.value.store) }
    func toolsHidden() async throws -> [String] { try await workspace.value.toolsHidden() }
    func toolsSetHidden(_ hidden: [String]) async throws -> [String] { try await workspace.value.setToolsHidden(hidden) }

    // MARK: 剪贴板

    func clipList(_ query: ClipQuery) async throws -> [ClipItem] { try await clipboard.list(query) }
    func clipText(_ id: String) async throws -> ClipText { try await clipboard.text(id) }
    func clipPaste(_ ids: [String], plain: Bool? = nil, edited: String? = nil) async throws -> String { try await clipboard.paste(ids, plain: plain, edited: edited) }
    func clipCopy(_ ids: [String], plain: Bool? = nil, edited: String? = nil) async throws { try await clipboard.copy(ids, plain: plain, edited: edited) }
    func clipDelete(_ ids: [String]) async throws { try await clipboard.delete(ids) }
    func clipClear() async throws -> Int { try await clipboard.clear() }
    func clipSetPinboard(_ ids: [String], pinboard: String?) async throws { try await clipboard.setPinboard(ids, pinboard: pinboard) }
    func clipRename(_ id: String, title: String) async throws -> ClipItem? { try await clipboard.rename(id, title: title) }
    func clipUpdateText(_ id: String, text: String) async throws -> ClipItem? { try await clipboard.updateText(id, text: text) }
    func clipPinboards() async throws -> [Pinboard] { try await clipboard.pinboards() }
    func clipSavePinboard(id: String?, name: String, color: String) async throws -> Pinboard { try await clipboard.savePinboard(id: id, name: name, color: color) }
    func clipDeletePinboard(_ id: String) async throws { try await clipboard.deletePinboard(id) }
    func clipOrderPinboards(_ ids: [String]) async throws { try await clipboard.orderPinboards(ids) }
    func clipApps() async throws -> [ClipApp] { try await clipboard.apps() }
    func clipIssues(_ keys: [String]) async throws -> [IssueHit] { try await clipboard.issues(keys) }
    func clipSettings() async throws -> ClipSettings { try await clipboard.settingsView() }
    func clipSaveSettings(_ config: ClipboardConfig) async throws -> ClipSettings { try await clipboard.saveSettings(config) }
    func clipPause(minutes: Int) async throws -> ClipSettings { try await clipboard.pause(minutes: minutes) }
    func clipRequestPermission() async throws { clipboard.requestPermission() }
    func clipIgnoreCandidates() async throws -> [IgnoredApp] { try await clipboard.ignoreCandidates() }
    func clipTouch(_ ids: [String]) async throws { try await clipboard.touch(ids) }

    /// 当前配置中的全局快捷键：`capture` / `clipboard`（剪贴板关闭时为空）。
    func configuredShortcut(_ action: String) -> String {
        let config = settings.configuration.snapshot()
        switch action {
        case "capture": return config.workspace.captureShortcut
        case "clipboard": return config.tools.clipboard.enabled ? config.tools.clipboard.shortcut : ""
        default: return ""
        }
    }

    // MARK: Wiki

    func wikiCachedSpaces() async throws -> [WikiSpace]? { try await wiki.cachedSpaces() }
    func wikiSpaces() async throws -> [WikiSpace] { try await wiki.spaces() }
    func wikiSpaceRoots(_ space: String) async throws -> [WikiNode] { try await wiki.client().spaceRoots(space) }
    func wikiChildren(_ page: String) async throws -> [WikiNode] { try await wiki.client().children(page) }
    func wikiPage(_ page: String) async throws -> WikiPageDetail { try await wiki.page(page) }
    func wikiPageMeta(_ page: String) async throws -> WikiPageMeta { try await wiki.client().pageMeta(page) }
    func wikiSetWatching(_ page: String, watching: Bool) async throws { try await wiki.client().setWatching(page, watching: watching) }
    func wikiSetLiked(_ page: String, liked: Bool) async throws { try await wiki.client().setLiked(page, liked: liked) }
    func wikiAddLabels(_ page: String, names: [String]) async throws { try await wiki.client().addLabels(page, names: names) }
    func wikiRemoveLabel(_ page: String, name: String) async throws { try await wiki.client().removeLabel(page, name: name) }
    func wikiStorage(_ page: String) async throws -> String { try await wiki.client().page(page).storage }
    func wikiUpload(_ page: String, paths: [String]) async throws {
        let client = try await wiki.client()
        _ = try await UploadProgress.sequence(paths.map(UploadProgress.fileSize)) { index in
            let url = URL(fileURLWithPath: paths[index])
            try await client.attach(page, filename: url.lastPathComponent, mime: AttachmentViewer.guessMime(url.lastPathComponent), data: Data(contentsOf: url))
        }
    }
    /// 复制页面（不含附件）到同一位置，返回新页面 id
    func wikiCopyPage(_ page: WikiPageDetail, title: String) async throws -> String {
        let client = try await wiki.client()
        let storage = try await client.page(page.id).storage
        return try await client.createIn(space: page.spaceKey, parent: page.ancestors.last?.id, title: title, storage: storage)
    }
    /// 导出 PDF / Word：使用网页端的导出地址（需要网页登录），返回文件内容和建议的文件名（由用户选择保存位置）
    func wikiExport(_ page: WikiPageDetail, word: Bool) async throws -> (Data, String) {
        let path = word ? "/exportword?pageId=\(page.id)" : "/spaces/flyingpdf/pdfpageexport.action?pageId=\(page.id)"
        let name = page.title.replacingOccurrences(of: "/", with: "_") + (word ? ".doc" : ".pdf")
        let (data, type) = try await wiki.attachments.fetch(service: .confluence, url: path)
        // 网页登录失效时拿到的是登录页
        let head = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        if type?.contains("text/html") == true, head.contains("os_username") || head.contains("login.action") {
            throw APIError(message: "导出需要网页登录，请先在设置中登录 Wiki 网页")
        }
        return (data, name)
    }
    func wikiResolve(_ input: String) async throws -> String? { try await wiki.client().resolvePage(input) }
    func wikiAttachments(_ page: String) async throws -> [Attachment] { try await wiki.pageAttachments(page) }
    func wikiRecent(limit: Int = 30) async throws -> [WikiRecent] { try await wiki.recent(limit: limit) }
    func wikiVersions(_ page: String) async throws -> [WikiVersion] { try await wiki.client().versions(page) }
    func wikiDiff(_ page: String, from: Int, to: Int) async throws -> String { try await wiki.diff(page, from: from, to: to) }
    func wikiVersionHtml(_ page: String, version: Int) async throws -> String { try await wiki.client().versionHTML(page, version: version) }
    func wikiPageVersion(_ page: String) async throws -> WikiPageVersionInfo { try await wiki.client().pageVersion(page) }
    func wikiComments(_ page: String) async throws -> [WikiComment] { try await wiki.client().comments(page) }
    func wikiAddComment(_ page: String, parent: String?, text: String) async throws -> [WikiComment] { try await wiki.addComment(page, parent: parent, text: text) }
    func wikiSetTask(_ page: String, task: String, done: Bool) async throws { try await wiki.setTask(page, task: task, done: done) }
    func wikiUsers(_ keys: [String]) async throws -> [String: String] { try await wiki.client().userNames(keys) }
    func wikiSearch(_ query: WikiQuery, server: Bool = false, start: Int = 0) async throws -> WikiSearchResult { var q = query; if q.limit == nil { q.limit = 50 }; return try await wiki.search(q, server: server, start: start) }
    func wikiIssuePages(_ key: String) async throws -> [WikiPageHit] { try await wiki.issuePages(key) }
    func wikiEdit(_ page: String) async throws -> WikiEditSession { try await wiki.edit(page) }
    func wikiNewPage(space: String, template: String?, storage: String?) async throws -> WikiEditSession { try await wiki.newPage(space: space, template: template, storage: storage) }
    func wikiTemplates(space: String?) async throws -> [WikiTemplate] { try await wiki.client().templates(space: space) }
    func wikiPreviewSave(page: String?, xhtml: String, fragments: [String]) async throws -> WikiSavePreview { try await wiki.previewSave(page: page, xhtml: xhtml, fragments: fragments) }
    func wikiSave(page: String, title: String, xhtml: String, fragments: [String], baseVersion: Int, minorEdit: Bool, message: String) async throws -> Int { try await wiki.save(page: page, title: title, xhtml: xhtml, fragments: fragments, baseVersion: baseVersion, minorEdit: minorEdit, message: message) }
    func wikiCreate(space: String, parent: String?, title: String, xhtml: String, fragments: [String]) async throws -> String { try await wiki.create(space: space, parent: parent, title: title, xhtml: xhtml, fragments: fragments) }
    func wikiIndexStatus() async throws -> WikiIndexStatus { try await wiki.indexStatus() }
    func wikiIndexSync() async throws { await wiki.requestIndexSync() }
    func wikiIndexRebuild() async throws -> WikiIndexStatus { try await wiki.rebuildIndex() }
    func wikiToolsSettings() async throws -> WikiToolsSettings { await wiki.toolsSettings() }
    func wikiSaveToolsSettings(_ settings: WikiToolsSettings) async throws -> WikiToolsSettings { try await wiki.saveToolsSettings(settings) }

    // MARK: 搜索与网页登录

    func globalSearch(_ query: String, options: SearchOptions? = nil) async throws -> SearchResults {
        await SearchService(settings: settings, workspace: try await workspace.value.store, jira: jira, wiki: wiki, gitlab: gitlab, clipboard: clipboard.store).search(query, options: options)
    }
    func webAccessStatus() async throws -> [String: WebAccess] { await sessions.accessStatus() }
    func webLoginInfo(_ service: Service) async throws -> WebLoginInfo { try await sessions.loginInfo(service) }
    func webLoginFinish(_ service: Service, url: String, cookie: String) async throws -> Bool { try await sessions.loginFinish(service, url: url, cookie: cookie) }
    func webLogout(_ service: Service) async throws { await sessions.logout(service) }
}

/// 服务发出的事件名称。
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

extension API {
    static func make(paths: AppPaths) throws -> API {
        try paths.createDirectories()
        let configuration = try ConfigurationStore(path: paths.config)
        let host = AppHost()
        let settings = try SettingsService(paths: paths, configuration: configuration)
        let sessions = WebSessionService(settings: settings, host: host)
        let wiki = try WikiService(settings: settings, host: host, web: sessions)
        let jira = try JiraService(settings: settings, host: host, web: sessions, wikiActivity: wiki)
        let gitlab = GitLabService(settings: settings, jira: jira, host: host, web: sessions)
        let weekly = WeeklyService(settings: settings, jira: jira, wiki: wiki, code: gitlab)
        let clipboard = ClipboardService(store: try ClipboardStore(directory: paths.data.appendingPathComponent("clipboard", isDirectory: true)), system: MacClipboard(), settings: settings, host: host, issues: jira.index)
        clipboard.start()
        Task { await jira.start(); await sessions.start() }
        let workspace = Task {
            let store = try await Workspace(path: paths.data.appendingPathComponent("workspace.sqlite").path)
            let service = WorkspaceService(store: store, settings: settings, host: host, remote: RemoteWorkspaceSources(jira: jira, wiki: wiki, gitlab: gitlab))
            await wiki.bindWorkspace(store); await wiki.start()
            await service.start()
            return service
        }
        return API(settings: settings, jira: jira, wiki: wiki, weekly: weekly, gitlab: gitlab, clipboard: clipboard, sessions: sessions, workspace: workspace)
    }
}
