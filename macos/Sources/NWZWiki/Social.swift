import Foundation
import NWZCore

/// 页面的关注（观看）、点赞、标签和访问限制：与网页页面顶部、底部的操作对应。
public struct WikiPageMeta: Codable, Hashable, Sendable {
    public var watching: Bool
    /// 点赞的人（显示名）
    public var likes: [String]
    public var liked: Bool
    /// 限制查看、编辑的用户和组；为空表示没有限制
    public var readRestrictions: [String]
    public var updateRestrictions: [String]
    public init(watching: Bool = false, likes: [String] = [], liked: Bool = false, readRestrictions: [String] = [], updateRestrictions: [String] = []) {
        self.watching = watching; self.likes = likes; self.liked = liked; self.readRestrictions = readRestrictions; self.updateRestrictions = updateRestrictions
    }
}

extension WikiClient {
    /// 读取失败的部分（例如没有安装点赞插件）按空处理，不影响其余信息。
    public func pageMeta(_ id: String) async throws -> WikiPageMeta {
        let page = RESTClient.component(id)
        async let watch = try? get("/rest/api/user/watch/content/" + page)
        async let likes = try? get("/rest/likes/1.0/content/" + page + "/likes")
        async let restrictions = try? get(Self.pagePath(id) + "/restriction/byOperation")
        async let user = try? me()
        let (w, l, r, u) = await (watch, likes, restrictions, user)
        var meta = WikiPageMeta()
        meta.watching = w?["watching"].bool ?? false
        let likers = l?["likes"].list.map { $0["user"] } ?? []
        meta.likes = likers.map { $0["fullName"].string ?? $0["displayName"].string ?? $0["name"].text }
        meta.liked = u.map { me in likers.contains { $0["name"].text == me.username } } ?? false
        func names(_ op: JSONDocument?) -> [String] {
            guard let op else { return [] }
            return op["restrictions"]["user"]["results"].list.map { $0["displayName"].text } + op["restrictions"]["group"]["results"].list.map { $0["name"].text }
        }
        meta.readRestrictions = names(r?["read"])
        meta.updateRestrictions = names(r?["update"])
        return meta
    }

    public func setWatching(_ id: String, watching: Bool) async throws {
        try await send(watching ? "POST" : "DELETE", "/rest/api/user/watch/content/" + RESTClient.component(id))
    }

    public func setLiked(_ id: String, liked: Bool) async throws {
        try await send(liked ? "POST" : "DELETE", "/rest/likes/1.0/content/" + RESTClient.component(id) + "/likes")
    }

    public func addLabels(_ id: String, names: [String]) async throws {
        let body = JSONValue.array(names.map { ["prefix": "global", "name": .string($0)] })
        _ = try await rest.response("POST", Self.pagePath(id) + "/label", body: body)
    }

    public func removeLabel(_ id: String, name: String) async throws {
        try await send("DELETE", Self.pagePath(id) + "/label", query: [("name", name)])
    }

    /// 网页端接口需要的跨站检查头。
    private func send(_ method: String, _ path: String, query: [(String, String)] = []) async throws {
        var request = try rest.request(method, path, query: query)
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        _ = try await rest.http.send(request)
    }
}
