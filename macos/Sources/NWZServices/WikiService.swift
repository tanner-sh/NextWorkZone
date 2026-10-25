import Foundation
import NWZCore
import NWZWiki
import NWZJira
import NWZWorkspace

public actor WikiService {
    public nonisolated let index: WikiIndex
    public nonisolated let attachments: AttachmentService
    let settings: SettingsService
    let host: any AppHost
    let cache: FileCache
    var workspace: Workspace?
    var identity: (String, String, String)?
    var indexLoop: Task<Void, Never>?
    var indexTask: Task<Void, Never>?
    var indexRunning = false
    var indexProgress: WikiIndexProgress?
    var indexError: String?

    public init(settings: SettingsService, host: any AppHost, web: any WebResourceSource) throws {
        self.settings = settings; self.host = host
        index = try WikiIndex(path: settings.paths.cache.appendingPathComponent("wiki-index.sqlite").path)
        attachments = AttachmentService(settings: settings, web: web, host: host)
        cache = FileCache(directory: settings.paths.cache.appendingPathComponent("responses", isDirectory: true))
    }
    deinit { indexLoop?.cancel(); indexTask?.cancel() }
    public func bindWorkspace(_ workspace: Workspace) { self.workspace = workspace }
    public func client() async throws -> WikiClient { try await WikiClient(rest: settings.restClient(.confluence)) }
    public func me() async throws -> (key: String, username: String) {
        let client = try await client(), key = client.rest.cacheIdentity
        if let identity, identity.0 == key { return (identity.1, identity.2) }
        let me = try await client.me(); identity = (key, me.key, me.username); return me
    }
    public func pageID(_ input: String) async throws -> String {
        guard let id = try await client().resolvePage(input) else { throw NWZError.other("无法识别的 Wiki 页面地址：\(input)") }
        return id
    }
    public func cachedSpaces() async throws -> [WikiSpace]? {
        await cache.get(try client().rest.cacheIdentity + ":wiki:spaces", as: [WikiSpace].self)
    }
    public func spaces() async throws -> [WikiSpace] {
        let client = try await client(), list = try await client.spaces()
        await cache.put(client.rest.cacheIdentity + ":wiki:spaces", value: list)
        return list
    }
    public func page(_ input: String) async throws -> WikiPageDetail {
        let id = try await pageID(input), page = try await client().pageDetail(id)
        try? await index.markViewed(id, title: page.title, space: page.spaceName)
        return page
    }
    public func recent(limit: Int) async throws -> [WikiRecent] {
        var list = try await index.recent(limit: limit)
        let web = (try? await client().recentlyViewed(limit: limit)) ?? []
        for item in web {
            if let n = list.firstIndex(where: { $0.id == item.id }) { list[n].at = max(list[n].at, item.at) }
            else { list.append(item) }
        }
        return Array(list.sorted { $0.at > $1.at }.prefix(max(0, limit)))
    }
    public func pageAttachments(_ page: String) async throws -> [Attachment] {
        try await client().attachments(page).map { Attachment(id: $0.id, filename: $0.filename, size: Int($0.size), mimeType: $0.mimeType, contentUrl: $0.contentUrl, thumbnailUrl: $0.thumbnailUrl, author: $0.author, created: $0.created) }
    }
    public func diff(_ page: String, from: Int, to: Int) async throws -> String {
        let client = try await client()
        async let old = client.versionStorage(page, version: from)
        async let new = client.versionStorage(page, version: to)
        let pair = try await (old, new)
        return await Task.detached { WikiDiff.unified(pair.0, pair.1) }.value
    }
    public func addComment(_ page: String, parent: String?, text: String) async throws -> [WikiComment] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NWZError.other("评论内容为空") }
        let client = try await client()
        _ = try await client.addComment(page, parent: parent, storage: WikiEdit.plainToStorage(text))
        return try await client.comments(page)
    }
    public func setTask(_ page: String, task: String, done: Bool) async throws {
        try await client().setTaskStatus(page, task: task, done: done)
        try await index.setTaskDone(page: page, task: task, done: done)
        if let workspace, let todo = try await workspace.todo("wiki-\(page)-\(task)"), todo.done != done, !todo.deleted {
            _ = try await workspace.setTodoDone(todo.id, done: done)
            host.emit(ServiceEvent("workspace-synced"))
        }
    }
    public func search(_ query: WikiQuery, server: Bool, start: Int) async throws -> WikiSearchResult {
        if settings.configuration.snapshot().wikiTools.indexEnabled, !server, try await !index.isEmpty() {
            let key = (try? await me().key) ?? ""
            let hits = try await index.search(query, me: key)
            return WikiSearchResult(source: "local", total: hits.count, hits: hits)
        }
        let name = (try? await me().username) ?? ""
        return try await client().cqlSearch(query, me: name, start: start)
    }
    public func issuePages(_ key: String) async throws -> [WikiPageHit] {
        let client = try await client()
        var linked: [String] = []
        if let rest = try? await settings.restClient(.jira) { linked = (try? await JiraClient(rest: rest).wikiPageLinks(key)) ?? [] }
        let enabled = settings.configuration.snapshot().wikiTools.indexEnabled
        let local = enabled ? try await !index.isEmpty() : false
        var pages = local ? try await index.pagesWithIssue(key, limit: 30) : (try? await client.cqlSearch(WikiQuery(text: key, limit: 20)).hits) ?? []
        let missing = linked.filter { id in !pages.contains { $0.id == id } }
        let known = (try? await index.titles(missing)) ?? []
        for id in missing {
            if let page = known.first(where: { $0.id == id }) { pages.append(WikiPageHit(id: id, kind: "page", title: page.title, spaceName: page.space)) }
            else if let page = try? await client.pageVersion(id) { pages.append(WikiPageHit(id: id, kind: "page", title: page.title)) }
        }
        return pages
    }
    public func edit(_ page: String) async throws -> WikiEditSession {
        let p = try await client().page(page)
        let ed = try await Task.detached { try WikiEdit.toEditable(p.storage) }.value
        return WikiEditSession(pageId: p.id, title: p.title, spaceKey: p.spaceKey, version: p.version, html: ed.html, fragments: ed.fragments, users: ed.users)
    }
    public func newPage(space: String, template: String?, storage: String?) async throws -> WikiEditSession {
        let body: String
        if let template { body = try await WikiEdit.stripTemplateVariables(client().templateStorage(template)) }
        else { body = storage ?? "<p></p>" }
        let ed = try await Task.detached { try WikiEdit.toEditable(body) }.value
        return WikiEditSession(spaceKey: space, html: ed.html, fragments: ed.fragments, users: ed.users)
    }
    public func previewSave(page: String?, xhtml: String, fragments: [String]) async throws -> WikiSavePreview {
        let storage = try await Task.detached { try WikiEdit.fromEditable(xhtml, fragments: fragments) }.value
        guard let page else { return WikiSavePreview(storage: storage, changed: true) }
        let current = try await client().page(page)
        return await Task.detached { WikiSavePreview(storage: storage, diff: WikiDiff.unified(current.storage, storage), changed: WikiStorage.normalizeEntities(current.storage) != WikiStorage.normalizeEntities(storage)) }.value
    }
    public func save(page: String, title: String, xhtml: String, fragments: [String], baseVersion: Int, minorEdit: Bool, message: String) async throws -> Int {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NWZError.other("页面标题不能为空") }
        let storage = try await Task.detached { try WikiEdit.fromEditable(xhtml, fragments: fragments) }.value
        let version = try await client().savePage(page, title: title, storage: storage, baseVersion: baseVersion, minorEdit: minorEdit, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        requestIndexSync(); return version
    }
    public func create(space: String, parent: String?, title: String, xhtml: String, fragments: [String]) async throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NWZError.other("页面标题不能为空") }
        let storage = try await Task.detached { try WikiEdit.fromEditable(xhtml, fragments: fragments) }.value
        let id = try await client().createIn(space: space, parent: parent, title: title, storage: storage)
        requestIndexSync(); return id
    }
}
