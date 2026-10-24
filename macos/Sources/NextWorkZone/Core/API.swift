import Foundation

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

/// Rust 应用层的类型化封装。界面只通过这里与应用层交互；命令与 Tauri 前端（src/api.ts）相同。
final class API: @unchecked Sendable {
    nonisolated(unsafe) static var shared: API!

    let core: Core

    init(core: Core) {
        self.core = core
    }

    /// 调用命令，返回原始 JSON 文本。
    func raw(_ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Data {
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
        do {
            let a = try await core.asset(path: path)
            return (a.data, a.contentType)
        } catch let e as CoreError {
            if case .Failed(let message) = e { throw APIError(message: message) }
            throw e
        }
    }

    // MARK: 设置

    func getSettings() async throws -> Settings { try await call("get_settings") }
    func saveSettings(_ input: SettingsInput) async throws -> Settings { try await call("save_settings", ["input": json(input)]) }
    func clearToken(_ service: Service) async throws -> Settings { try await call("clear_token", ["service": .string(service.rawValue)]) }
    func importTokensEnv() async throws -> [Service] { try await call("import_tokens_env") }
    func testConnection(_ service: Service) async throws -> ConnectionInfo { try await call("test_connection", ["service": .string(service.rawValue)]) }

    // MARK: Jira

    func jiraCachedSearch(_ jql: String, fields: [String] = []) async throws -> SearchResult? {
        try await call("jira_cached_search", ["jql": .string(jql), "fields": json(fields)])
    }
    func jiraSearch(_ jql: String, startAt: Int = 0, maxResults: Int = 100, fields: [String] = []) async throws -> SearchResult {
        try await call("jira_search", ["jql": .string(jql), "startAt": json(startAt), "maxResults": json(maxResults), "fields": json(fields)])
    }
    func jiraFields(refresh: Bool = false) async throws -> [FieldInfo] { try await call("jira_fields", ["refresh": .bool(refresh)]) }
    func jiraMyWorklogs(from: String, to: String) async throws -> [WorklogSum] { try await call("jira_my_worklogs", ["from": .string(from), "to": .string(to)]) }
    func jiraIssue(_ key: String) async throws -> IssueDetail { try await call("jira_issue", ["key": .string(key)]) }
    func jiraTransitions(_ key: String) async throws -> [Transition] { try await call("jira_transitions", ["key": .string(key)]) }
    func jiraTransition(_ key: String, transitionId: String, fields: [String: JSONValue], comment: String?, visibility: CommentVisibility? = nil) async throws -> IssueDetail {
        try await call("jira_transition", ["key": .string(key), "transitionId": .string(transitionId), "fields": .object(fields), "comment": json(comment), "visibility": json(visibility)])
    }
    func jiraAddComment(_ key: String, body: String, visibility: CommentVisibility? = nil) async throws -> Comment {
        try await call("jira_add_comment", ["key": .string(key), "body": .string(body), "visibility": json(visibility)])
    }
    func jiraUpdateComment(_ key: String, id: String, body: String, visibility: CommentVisibility?) async throws -> Comment {
        try await call("jira_update_comment", ["key": .string(key), "id": .string(id), "body": .string(body), "visibility": json(visibility)])
    }
    func jiraCommentLevels(_ key: String) async throws -> [CommentLevel] { try await call("jira_comment_levels", ["key": .string(key)]) }
    func jiraDeleteComment(_ key: String, id: String) async throws { try await run("jira_delete_comment", ["key": .string(key), "id": .string(id)]) }
    func jiraMe() async throws -> String { try await call("jira_me") }
    func jiraAssign(_ key: String, assignee: String?) async throws -> IssueDetail { try await call("jira_assign", ["key": .string(key), "assignee": json(assignee)]) }
    func jiraWatchers(_ key: String) async throws -> Watchers { try await call("jira_watchers", ["key": .string(key)]) }
    func jiraSetWatching(_ key: String, watching: Bool) async throws -> Watchers { try await call("jira_set_watching", ["key": .string(key), "watching": .bool(watching)]) }
    func jiraPriorities() async throws -> [Priority] { try await call("jira_priorities") }
    func jiraSetPriority(_ key: String, priorityId: String) async throws -> IssueDetail { try await call("jira_set_priority", ["key": .string(key), "priorityId": .string(priorityId)]) }
    func jiraActivity() async throws -> ActivityFeed { try await call("jira_activity") }
    func jiraActivityPoll() async throws -> ActivityPoll { try await call("jira_activity_poll") }
    func jiraActivityRead(_ ids: [String]?) async throws -> ActivityFeed { try await call("jira_activity_read", ["ids": json(ids)]) }
    func jiraPreviewAttachment(url: String, filename: String, mime: String, service: Service = .jira) async throws -> AttachmentPreview {
        try await call("jira_preview_attachment", ["url": .string(url), "filename": .string(filename), "mime": .string(mime), "service": .string(service.rawValue)])
    }
    func jiraFavouriteFilters() async throws -> [JiraFilter] { try await call("jira_favourite_filters") }
    func jiraSimilarIssues(_ key: String, summary: String, resolvedOnly: Bool) async throws -> SimilarIssues {
        try await call("jira_similar_issues", ["key": .string(key), "summary": .string(summary), "resolvedOnly": .bool(resolvedOnly)])
    }
    func jiraIndexStatus() async throws -> IndexStatus { try await call("jira_index_status") }
    func jiraIndexSync() async throws { try await run("jira_index_sync") }
    func jiraIndexRebuild() async throws -> IndexStatus { try await call("jira_index_rebuild") }
    func jiraIndexSearch(_ query: IndexQuery) async throws -> [IssueHit] { try await call("jira_index_search", ["query": json(query)]) }
    func jiraViewed(_ keys: [String]) async throws -> Viewed { try await call("jira_viewed", ["keys": json(keys)]) }
    func jiraMarkViewed(_ key: String, updated: String?) async throws -> Int64? { try await call("jira_mark_viewed", ["key": .string(key), "updated": json(updated)]) }
    func jiraToolsSettings() async throws -> JiraToolsSettings { try await call("jira_tools_settings") }
    func jiraSaveToolsSettings(_ settings: JiraToolsSettings) async throws -> JiraToolsSettings { try await call("jira_save_tools_settings", ["settings": json(settings)]) }
    func jiraReminders() async throws -> Reminders { try await call("jira_reminders") }
    func jiraUploadAttachments(_ key: String, paths: [String]) async throws -> [Attachment] { try await call("jira_upload_attachments", ["key": .string(key), "paths": json(paths)]) }
    func jiraOpenAttachment(url: String, filename: String, service: Service = .jira) async throws -> String {
        try await call("jira_open_attachment", ["url": .string(url), "filename": .string(filename), "service": .string(service.rawValue)])
    }
    func jiraEditFields(_ key: String) async throws -> [FieldMeta] { try await call("jira_edit_fields", ["key": .string(key)]) }
    func jiraUpdateIssue(_ key: String, fields: [String: JSONValue]) async throws -> IssueDetail { try await call("jira_update_issue", ["key": .string(key), "fields": .object(fields)]) }
    func jiraCachedCreateProjects() async throws -> [CreateProject]? { try await call("jira_cached_create_projects") }
    func jiraCreateProjects() async throws -> [CreateProject] { try await call("jira_create_projects") }
    func jiraCreateFields(projectKey: String, issueTypeId: String) async throws -> [FieldMeta] {
        try await call("jira_create_fields", ["projectKey": .string(projectKey), "issueTypeId": .string(issueTypeId)])
    }
    func jiraCreateIssue(fields: [String: JSONValue], attachments: [String]) async throws -> CreatedIssue {
        try await call("jira_create_issue", ["fields": .object(fields), "attachments": json(attachments)])
    }
    func jiraFindUsers(_ query: String, field: String, issueKey: String?, projectKey: String?) async throws -> [UserRef] {
        try await call("jira_find_users", ["query": .string(query), "field": .string(field), "issueKey": json(issueKey), "projectKey": json(projectKey)])
    }
    func jiraSuggestedAssignees(_ key: String) async throws -> [UserRef] { try await call("jira_suggested_assignees", ["key": .string(key)]) }
    func jiraSuggestLabels(_ query: String) async throws -> [String] { try await call("jira_suggest_labels", ["query": .string(query)]) }
    func jiraSearchEpics(_ query: String, projectKey: String) async throws -> [IssueRef] { try await call("jira_search_epics", ["query": .string(query), "projectKey": .string(projectKey)]) }
    func jiraPickIssues(_ query: String, projectKey: String?, standardOnly: Bool) async throws -> [IssueSummary] {
        try await call("jira_pick_issues", ["query": .string(query), "projectKey": json(projectKey), "standardOnly": .bool(standardOnly)])
    }
    func jiraLinkTypes() async throws -> [LinkType] { try await call("jira_link_types") }
    func jiraAddLink(_ key: String, typeId: String, other: String, outward: Bool) async throws -> IssueDetail {
        try await call("jira_add_link", ["key": .string(key), "typeId": .string(typeId), "other": .string(other), "outward": .bool(outward)])
    }
    func jiraDeleteLink(_ key: String, linkId: String) async throws -> IssueDetail { try await call("jira_delete_link", ["key": .string(key), "linkId": .string(linkId)]) }
    func jiraWorklogs(_ key: String) async throws -> [Worklog] { try await call("jira_worklogs", ["key": .string(key)]) }
    func jiraSaveWorklog(_ key: String, id: String?, input: WorklogInput) async throws -> [Worklog] {
        try await call("jira_save_worklog", ["key": .string(key), "id": json(id), "input": json(input)])
    }
    func jiraDeleteWorklog(_ key: String, id: String) async throws -> [Worklog] { try await call("jira_delete_worklog", ["key": .string(key), "id": .string(id)]) }
    func jiraHistory(_ key: String) async throws -> [HistoryEntry] { try await call("jira_history", ["key": .string(key)]) }
    func jiraRenderWiki(_ markup: String, issueKey: String?) async throws -> String { try await call("jira_render_wiki", ["markup": .string(markup), "issueKey": json(issueKey)]) }
    func jiraSavePastedImage(base64: String, filename: String) async throws -> String { try await call("jira_save_pasted_image", ["data": .string(base64), "filename": .string(filename)]) }

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

    func wsTodos() async throws -> [Todo] { try await call("ws_todos") }
    func wsSaveTodo(_ input: TodoInput) async throws -> Todo { try await call("ws_save_todo", ["input": json(input)]) }
    func wsSetTodoDone(_ id: String, done: Bool) async throws -> Todo { try await call("ws_set_todo_done", ["id": .string(id), "done": .bool(done)]) }
    func wsMoveTodo(_ id: String, sort: Double) async throws { try await run("ws_move_todo", ["id": .string(id), "sort": .number(sort)]) }
    func wsDeleteTodo(_ id: String) async throws { try await run("ws_delete_todo", ["id": .string(id)]) }
    func wsRefreshJiraTodos() async throws -> JiraTodoSync? { try await call("ws_refresh_jira_todos") }
    func wsDocs(_ kind: DocKind) async throws -> [DocSummary] { try await call("ws_docs", ["kind": .string(kind)]) }
    func wsDoc(_ id: String) async throws -> Doc? { try await call("ws_doc", ["id": .string(id)]) }
    func wsFullDocs(_ kind: DocKind) async throws -> [Doc] { try await call("ws_full_docs", ["kind": .string(kind)]) }
    func wsDaily(_ day: String) async throws -> Doc { try await call("ws_daily", ["day": .string(day)]) }
    func wsDailyDays() async throws -> [String] { try await call("ws_daily_days") }
    func wsSaveDoc(_ input: DocInput) async throws -> Doc { try await call("ws_save_doc", ["input": json(input)]) }
    func wsMoveDoc(_ id: String, parentId: String?, sort: Double) async throws -> Doc { try await call("ws_move_doc", ["id": .string(id), "parentId": json(parentId), "sort": .number(sort)]) }
    func wsDeleteDoc(_ id: String) async throws -> Int { try await call("ws_delete_doc", ["id": .string(id)]) }
    func wsTags() async throws -> [TagCount] { try await call("ws_tags") }
    func wsBacklinks(system: String, key: String) async throws -> [Backlink] { try await call("ws_backlinks", ["system": .string(system), "key": .string(key)]) }
    func wsSearch(_ query: String) async throws -> [WorkspaceHit] { try await call("ws_search", ["query": .string(query)]) }
    func wsSaveAsset(base64: String, mime: String) async throws -> SavedAsset { try await call("ws_save_asset", ["data": .string(base64), "mime": .string(mime)]) }
    func wsSettings() async throws -> WorkspaceSettings { try await call("ws_settings") }
    func wsSaveSettings(syncDir: String, jiraTodos: Bool) async throws -> WorkspaceSettings { try await call("ws_save_settings", ["syncDir": .string(syncDir), "jiraTodos": .bool(jiraTodos)]) }
    func wsSync() async throws -> SyncReport? { try await call("ws_sync") }
    func wsSaveCaptureShortcut(_ shortcut: String) async throws -> WorkspaceSettings { try await call("ws_save_capture_shortcut", ["shortcut": .string(shortcut)]) }
    func wsInbox() async throws -> InboxView { try await call("ws_inbox") }
    func wsInboxHandle(_ input: InboxHandleInput) async throws { try await run("ws_inbox_handle", ["input": json(input)]) }
    func wsInboxSnooze(_ id: String, title: String, until: Int64?) async throws { try await run("ws_inbox_snooze", ["id": .string(id), "title": .string(title), "until": json(until)]) }
    func wsWorklog(_ day: String) async throws -> WorkLog { try await call("ws_worklog", ["day": .string(day)]) }
    func wsWikiPage(_ page: String) async throws -> WsWikiPage { try await call("ws_wiki_page", ["page": .string(page)]) }
    func wsPublishToWiki(docId: String?, mode: String, parent: String, title: String, storage: String, assets: [String]) async throws -> PublishResult {
        try await call("ws_publish_to_wiki", ["docId": json(docId), "mode": .string(mode), "parent": .string(parent), "title": .string(title), "storage": .string(storage), "assets": json(assets)])
    }
    func toolsHidden() async throws -> [String] { try await call("tools_hidden") }
    func toolsSetHidden(_ hidden: [String]) async throws -> [String] { try await call("tools_set_hidden", ["hidden": json(hidden)]) }

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
