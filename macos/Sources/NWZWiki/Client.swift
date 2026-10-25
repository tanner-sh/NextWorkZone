import Foundation
import NWZCore

public struct WikiPage: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var spaceKey: String
    public var version: Int
    public var storage: String
    public var modifiedBy: String
    public var modifiedAt: String
    public init(raw: JSONDocument) {
        id = raw["id"].text; title = raw["title"].text; spaceKey = raw["space"]["key"].text
        version = raw["version"]["number"].int; storage = raw["body"]["storage"]["value"].text
        modifiedBy = raw["version"]["by"]["displayName"].text; modifiedAt = raw["version"]["when"].text
    }
}
public struct WikiAttachment: Codable, Hashable, Sendable {
    public var id: String
    public var filename: String
    public var size: Int64
    public var mimeType: String
    public var contentUrl: String
    public var thumbnailUrl: String?
    public var author: String
    public var created: String
    public init(raw: JSONDocument) {
        id = raw["id"].text; filename = raw["title"].text; size = Int64(raw["extensions"]["fileSize"].int)
        mimeType = raw["metadata"]["mediaType"].text; contentUrl = raw["_links"]["download"].text
        thumbnailUrl = mimeType.hasPrefix("image/") ? contentUrl : nil
        author = raw["version"]["by"]["displayName"].text; created = raw["version"]["when"].text
    }
}
public struct WikiPageView: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var spaceKey: String
    public var url: String
    public var html: String
    public var version: Int
}

public struct WikiClient: Sendable {
    public let rest: RESTClient
    public var baseURL: String { rest.baseURL }
    public init(rest: RESTClient) { self.rest = rest }
    public func get(_ path: String, query: [(String, String)] = []) async throws -> JSONDocument { try await rest.json("GET", path, query: query) }
    public static func pagePath(_ id: String) -> String { "/rest/api/content/" + RESTClient.component(id) }
    public func pageURL(_ id: String) -> String { baseURL + "/pages/viewpage.action?pageId=" + RESTClient.component(id) }
    public func currentUser() async throws -> JSONDocument {
        let raw = try await get("/rest/api/user/current")
        if raw["type"].text == "anonymous" { throw NWZError.unauthorized(401) }
        return raw
    }
    public func me() async throws -> (key: String, username: String) {
        let raw = try await currentUser()
        return (raw["userKey"].text, raw["username"].text)
    }
    public func resolvePersonName(_ configured: String) async throws -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? try await currentUser()["displayName"].text : trimmed
    }
    public func page(_ id: String) async throws -> WikiPage {
        try await WikiPage(raw: get(Self.pagePath(id), query: [("expand", "body.storage,version,space")]))
    }
    public func pageView(_ id: String) async throws -> WikiPageView {
        let raw = try await get(Self.pagePath(id), query: [("expand", "body.view,space,version")])
        return WikiPageView(id: id, title: raw["title"].text, spaceKey: raw["space"]["key"].text, url: pageURL(id), html: raw["body"]["view"]["value"].text, version: raw["version"]["number"].int)
    }
    public func pageDetail(_ id: String) async throws -> WikiPageDetail {
        let r = try await get(Self.pagePath(id), query: [("expand", "body.view,version,space,ancestors,history,metadata.labels,operations")])
        return WikiPageDetail(id: r["id"].text, kind: r["type"].text, title: r["title"].text, spaceKey: r["space"]["key"].text, spaceName: r["space"]["name"].text, version: r["version"]["number"].int, modifiedBy: r["version"]["by"]["displayName"].text, modified: r["version"]["when"].text, versionMessage: r["version"]["message"].text, createdBy: r["history"]["createdBy"]["displayName"].text, created: r["history"]["createdDate"].text, ancestors: WikiBrowse.ancestors(r["ancestors"]), labels: r["metadata"]["labels"]["results"].list.map { $0["name"].text }, html: r["body"]["view"]["value"].text, url: pageURL(id), canEdit: r["operations"].list.contains { $0["operation"].text == "update" })
    }
    public func pageVersion(_ id: String) async throws -> WikiPageVersionInfo {
        let r = try await get(Self.pagePath(id), query: [("expand", "version")])
        return WikiPageVersionInfo(title: r["title"].text, version: r["version"]["number"].int, by: r["version"]["by"]["displayName"].text, when: r["version"]["when"].text)
    }

    /// 每次请求都使用受限的站内路径，分页响应不能把凭据引向其他主机。
    func all(_ path: String, query: [(String, String)] = [], limit: Int = 200) async throws -> [JSONDocument] {
        var out: [JSONDocument] = [], start = 0
        while true {
            try Task.checkCancellation()
            let raw = try await get(path, query: query + [("start", String(start)), ("limit", String(limit))])
            let results = raw["results"].list
            out += results; start += results.count
            if results.isEmpty || raw["_links"]["next"].isNull { break }
        }
        return out
    }
    public func spaces() async throws -> [WikiSpace] {
        try await all("/rest/api/space", query: [("type", "global"), ("expand", "homepage,description.plain")]).map {
            WikiSpace(key: $0["key"].text, name: $0["name"].text, homepageId: $0["homepage"]["id"].string, description: $0["description"]["plain"]["value"].text)
        }.sorted { $0.name < $1.name }
    }
    public func spaceRoots(_ space: String) async throws -> [WikiNode] { try await nodes("/rest/api/space/" + RESTClient.component(space) + "/content/page", query: [("depth", "root")]) }
    public func children(_ page: String) async throws -> [WikiNode] { try await nodes(Self.pagePath(page) + "/child/page") }
    private func nodes(_ path: String, query: [(String, String)] = []) async throws -> [WikiNode] {
        try await all(path, query: query + [("expand", "children.page")]).map { WikiNode(id: $0["id"].text, title: $0["title"].text, hasChildren: $0["children"]["page"]["size"].int > 0) }
    }
    public func attachments(_ page: String) async throws -> [WikiAttachment] {
        try await all(Self.pagePath(page) + "/child/attachment", query: [("expand", "version")]).map(WikiAttachment.init(raw:))
    }
    public func versions(_ page: String) async throws -> [WikiVersion] {
        try await all("/rest/experimental/content/" + RESTClient.component(page) + "/version").map {
            WikiVersion(number: $0["number"].int, by: $0["by"]["displayName"].text, when: $0["when"].text, message: $0["message"].text, minorEdit: $0["minorEdit"].bool ?? false)
        }.sorted { $0.number > $1.number }
    }
    public func versionStorage(_ page: String, version: Int) async throws -> String { try await versionBody(page, version: version, kind: "storage") }
    public func versionHTML(_ page: String, version: Int) async throws -> String { try await versionBody(page, version: version, kind: "view") }
    private func versionBody(_ page: String, version: Int, kind: String) async throws -> String {
        try await get(Self.pagePath(page), query: [("status", "historical"), ("version", String(version)), ("expand", "body." + kind)])["body"][kind]["value"].text
    }
    public func comments(_ page: String) async throws -> [WikiComment] {
        try await all(Self.pagePath(page) + "/child/comment", query: [("depth", "all"), ("expand", "body.view,version,history,ancestors,extensions.inlineProperties")], limit: 100).map { r in
            let inline = r["extensions"]["location"].text == "inline" ? r["extensions"]["inlineProperties"]["originalSelection"].text : ""
            return WikiComment(id: r["id"].text, author: r["history"]["createdBy"]["displayName"].text, created: r["history"]["createdDate"].text, html: r["body"]["view"]["value"].text, parentId: r["ancestors"].list.last.map { $0["id"].text }, inlineText: inline.isEmpty ? nil : inline, version: r["version"]["number"].number.map(Int.init) ?? 1)
        }.sorted { $0.created < $1.created }
    }

    public func updatePage(_ page: WikiPage, storage: String, message: String) async throws -> Int {
        try await putPage(page.id, title: page.title, space: page.spaceKey, storage: storage, version: page.version + 1, minorEdit: true, message: message)
    }
    public func savePage(_ id: String, title: String, storage: String, baseVersion: Int, minorEdit: Bool, message: String) async throws -> Int {
        try WikiStorage.validate(storage)
        let current = try await page(id)
        guard current.version == baseVersion else { throw NWZError.conflict("页面在你编辑期间被 \(current.modifiedBy) 修改过（当前为第 \(current.version) 版，你基于第 \(baseVersion) 版编辑）") }
        return try await putPage(id, title: title, space: current.spaceKey, storage: storage, version: baseVersion + 1, minorEdit: minorEdit, message: message)
    }
    private func putPage(_ id: String, title: String, space: String, storage: String, version: Int, minorEdit: Bool, message: String) async throws -> Int {
        try WikiStorage.validate(storage)
        let body: JSONValue = ["id": .string(id), "type": "page", "title": .string(title), "space": ["key": .string(space)], "version": ["number": .number(Double(version)), "minorEdit": .bool(minorEdit), "message": .string(message)], "body": ["storage": ["value": .string(storage), "representation": "storage"]]]
        do { _ = try await rest.response("PUT", Self.pagePath(id), body: body) }
        catch NWZError.conflict { throw NWZError.conflict("页面刚刚被他人更新，请刷新后重新编辑") }
        return version
    }
    public func createPage(parent: String, title: String, storage: String) async throws -> String {
        let page = try await page(parent)
        return try await createIn(space: page.spaceKey, parent: parent, title: title, storage: storage)
    }
    public func createIn(space: String, parent: String?, title: String, storage: String) async throws -> String {
        try WikiStorage.validate(storage)
        var body: [String: JSONValue] = ["type": "page", "title": .string(title), "space": ["key": .string(space)], "body": ["storage": ["value": .string(storage), "representation": "storage"]]]
        if let parent { body["ancestors"] = [["id": .string(parent)]] }
        let raw = try await rest.json("POST", "/rest/api/content", body: .object(body))
        guard let id = raw["id"].string else { throw NWZError.other("创建页面失败：响应中没有页面 id") }
        return id
    }
    public func addComment(_ page: String, parent: String?, storage: String) async throws -> String {
        try WikiStorage.validate(storage)
        var body: [String: JSONValue] = ["type": "comment", "container": ["id": .string(page), "type": "page"], "body": ["storage": ["value": .string(storage), "representation": "storage"]]]
        if let parent { body["ancestors"] = [["id": .string(parent)]] }
        let raw = try await rest.json("POST", "/rest/api/content", body: .object(body))
        guard let id = raw["id"].string else { throw NWZError.other("发表评论失败：响应中没有评论 id") }
        return id
    }
    public func setTaskStatus(_ page: String, task: String, done: Bool) async throws {
        var request = try rest.request("POST", "/rest/inlinetasks/1/task/" + RESTClient.component(page) + "/" + RESTClient.component(task) + "/", body: ["status": .string(done ? "CHECKED" : "UNCHECKED"), "trigger": "VIEW_PAGE"])
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        _ = try await rest.http.send(request)
    }
    public func attach(_ page: String, filename: String, mime: String, data: Data) async throws {
        var multipart = MultipartBody()
        try multipart.append(name: "file", filename: filename, contentType: mime, data: data)
        var request = try rest.request("POST", Self.pagePath(page) + "/child/attachment")
        request.httpBody = multipart.data
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        _ = try await rest.http.send(request)
    }
    public func templates(space: String?) async -> [WikiTemplate] {
        var scopes: [String?] = [nil], out: [WikiTemplate] = []
        if let space { scopes.append(space) }
        for space in scopes {
            let query = [("limit", "200")] + (space.map { [("spaceKey", $0)] } ?? [])
            guard let raw = try? await get("/rest/experimental/template/page", query: query) else { continue }
            out += raw["results"].list.map { WikiTemplate(id: $0["templateId"].text, name: $0["name"].text, description: $0["description"].text, spaceKey: $0["space"]["key"].string ?? space) }
        }
        return out
    }
    public func templateStorage(_ id: String) async throws -> String {
        try await get("/rest/experimental/template/" + RESTClient.component(id), query: [("expand", "body.storage")])["body"]["storage"]["value"].text
    }
}
