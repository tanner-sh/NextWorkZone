import Foundation
import NWZCore

public struct WikiWork: Codable, Hashable, Sendable {
    public var at: String
    public var kind: String
    public var pageId: String
    public var title: String
    public var detail: String
}
public struct WikiNotification: Codable, Hashable, Sendable {
    public var id: String
    public var action: String
    public var title: String
    public var text: String
    public var actor: String
    public var pageId: String?
    public var pageTitle: String
    public var url: String
    public var updated: Int64
}
public struct WikiPageChange: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var version: Int
    public var by: String
    public var byKey: String
    public var when: String
    public var message: String
}

public enum WikiBrowse {
    public static func ancestors(_ raw: JSONDocument) -> [WikiAncestor] { raw.list.map { WikiAncestor(id: $0["id"].text, title: $0["title"].text) } }
    public static func cqlEscape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    public static func stripHighlight(_ s: String) -> String { WikiStorage.collapseWhitespace(WikiStorage.decodeEntities(s.replacingOccurrences(of: "@@@hl@@@", with: "").replacingOccurrences(of: "@@@endhl@@@", with: ""))) }
    public static func stripHTML(_ html: String) -> String {
        var out = "", inTag = false
        for c in html {
            if c == "<" { inTag = true }
            else if c == ">" { inTag = false; out += " " }
            else if !inTag { out.append(c) }
        }
        return WikiStorage.collapseWhitespace(WikiStorage.decodeEntities(out))
    }
    public static func percentDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = [], i = 0
        while i < bytes.count {
            if bytes[i] == 37, i + 2 < bytes.count, let b = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { out.append(b); i += 3 }
            else { out.append(bytes[i]); i += 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }
    public static func decodeTiny(_ code: String) -> String? {
        var s = code.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "-", with: "/").replacingOccurrences(of: "_", with: "+")
        while s.utf8.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s), !data.isEmpty, data.count <= 8 else { return nil }
        return String(data.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) })
    }
    public static func normalizeAction(_ action: String, title: String) -> String {
        let a = action.lowercased(), t = title.lowercased()
        for (kind, words) in [("mention", ["提到", "mentioned"]), ("comment", ["评论", "comment"]), ("share", ["分享", "shared"]), ("task", ["任务"]), ("like", ["赞"])] {
            if a.contains(kind) || words.contains(where: t.contains) { return kind }
        }
        return a.isEmpty ? "other" : a
    }
    public static func work(_ r: JSONDocument, me: String) -> WikiWork {
        let version = r["version"]["number"].int
        let kind = r["history"]["createdBy"]["userKey"].text == me && version <= 1 ? "create" : "edit"
        let mine = r["version"]["by"]["userKey"].text == me
        let message = r["version"]["message"].text
        let detail = kind == "create" ? "" : mine ? "第 \(version) 版" + (message.isEmpty ? "" : "：" + message) : "参与编辑"
        return WikiWork(at: r["version"]["when"].text, kind: kind, pageId: r["id"].text, title: r["title"].text, detail: detail)
    }
}

extension WikiClient {
    public func search(_ text: String, limit: Int) async throws -> [WikiHit] {
        let cql = "siteSearch ~ \"\(WikiBrowse.cqlEscape(text))\" AND type = page"
        let raw = try await get("/rest/api/search", query: [("cql", cql), ("limit", String(limit))])
        return raw["results"].list.compactMap { r in
            guard let id = r["content"]["id"].string else { return nil }
            return WikiHit(id: id, title: r["content"]["title"].text, space: r["resultGlobalContainer"]["title"].text, url: baseURL + r["url"].text, excerpt: WikiBrowse.stripHighlight(r["excerpt"].text))
        }
    }
    public func cqlSearch(_ query: WikiQuery, me: String = "", start: Int = 0, label: String = "") async throws -> WikiSearchResult {
        let kind = query.kind ?? "", text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [kind.isEmpty ? "type in (page, blogpost)" : "type = \(WikiBrowse.cqlEscape(kind))"]
        if !text.isEmpty { parts.append("siteSearch ~ \"\(WikiBrowse.cqlEscape(text))\"") }
        if let space = query.space, !space.isEmpty { parts.append("space = \"\(WikiBrowse.cqlEscape(space))\"") }
        if query.mine == true, !me.isEmpty { parts.append("contributor = \"\(WikiBrowse.cqlEscape(me))\"") }
        if let days = query.days, days > 0 { parts.append("lastmodified >= now(\"-\(days)d\")") }
        if !label.isEmpty { parts.append("label = \"\(WikiBrowse.cqlEscape(label))\"") }
        let cql = parts.joined(separator: " AND ") + (text.isEmpty ? " ORDER BY lastmodified DESC" : "")
        let limit = (query.limit ?? 0) <= 0 ? 50 : min(query.limit ?? 50, 100)
        let raw = try await get("/rest/api/search", query: [("cql", cql), ("start", String(max(0, start))), ("limit", String(limit)), ("expand", "content.space,content.version,content.ancestors")])
        let hits: [WikiPageHit] = raw["results"].list.compactMap { r in
            let c = r["content"]
            guard let id = c["id"].string else { return nil }
            return WikiPageHit(id: id, kind: c["type"].text, title: c["title"].text, spaceKey: c["space"]["key"].text, spaceName: c["space"]["name"].text, ancestors: WikiBrowse.ancestors(c["ancestors"]), authorName: c["version"]["by"]["displayName"].text, modified: c["version"]["when"].text, snippet: WikiBrowse.stripHighlight(r["excerpt"].text))
        }
        return WikiSearchResult(source: "server", total: raw["totalSize"].int, hits: hits)
    }
    public func userNames(_ keys: [String]) async -> [String: String] {
        var out: [String: String] = [:]
        for key in keys.prefix(50) {
            if let raw = try? await get("/rest/api/user", query: [("key", key)]) { out[key] = raw["displayName"].text }
        }
        return out
    }
    public func recentlyViewed(limit: Int) async -> [WikiRecent] {
        guard let raw = try? await get("/rest/recentlyviewed/1.0/recent", query: [("limit", String(limit))]) else { return [] }
        return raw.list.compactMap { r in
            guard ["page", "blogpost"].contains(r["type"].text), let id = r["id"].string ?? r["id"].number.map({ String(Int64($0)) }) else { return nil }
            return WikiRecent(id: id, title: r["title"].text, space: r["space"].text, at: Int64(r["lastSeen"].int), source: "web")
        }
    }
    public func notifications() async -> [WikiNotification] {
        guard let raw = try? await get("/rest/mywork/latest/notification/nested", query: [("limit", "100")]) else { return [] }
        var out: [WikiNotification] = []
        for group in raw.list {
            let item = group["item"]
            if item["entity"].text == "authentication" || item["application"].text == "com.atlassian.mywork.host.provider" { continue }
            for n in group["notifications"].list {
                let url = n["url"].text.isEmpty ? item["url"].text : n["url"].text
                let action = n["action"].text.isEmpty ? item["action"].text : n["action"].text
                let meta = n["metadata"]
                let actor = ["user", "userDisplayName", "username", "fullName"].compactMap { meta[$0].string }.first { !$0.isEmpty } ?? ""
                let page = parsePageID(baseURL + url) ?? meta["pageId"].string ?? meta["contentId"].number.map { String(Int64($0)) }
                out.append(WikiNotification(id: n["id"].number.map { String(Int64($0)) } ?? n["globalId"].text, action: WikiBrowse.normalizeAction(action, title: n["title"].text), title: WikiBrowse.stripHTML(n["title"].text), text: String(WikiBrowse.stripHTML(n["description"].text).prefix(200)), actor: actor, pageId: page, pageTitle: WikiBrowse.stripHTML(item["title"].text), url: url.hasPrefix("/") ? baseURL + url : url, updated: Int64(n["updated"].number ?? n["created"].number ?? 0)))
            }
        }
        return out
    }
    public func watchedChanges(minutes: Int) async throws -> [WikiPageChange] {
        let cql = "type in (page, blogpost) AND (watcher = currentUser() OR creator = currentUser()) AND lastmodified >= now(\"-\(minutes)m\") ORDER BY lastmodified DESC"
        return try await get("/rest/api/content/search", query: [("cql", cql), ("limit", "50"), ("expand", "version")])["results"].list.map { r in
            WikiPageChange(id: r["id"].text, title: r["title"].text, version: r["version"]["number"].int, by: r["version"]["by"]["displayName"].text, byKey: r["version"]["by"]["userKey"].text, when: r["version"]["when"].text, message: r["version"]["message"].text)
        }
    }
    public func myWork(from: String, to: String) async throws -> [WikiWork] {
        let (key, _) = try await me()
        let pagesCQL = "type in (page, blogpost) AND contributor = currentUser() AND lastmodified >= \"\(WikiBrowse.cqlEscape(from))\" AND lastmodified < \"\(WikiBrowse.cqlEscape(to))\" ORDER BY lastmodified"
        let commentsCQL = "type = comment AND creator = currentUser() AND created >= \"\(WikiBrowse.cqlEscape(from))\" AND created < \"\(WikiBrowse.cqlEscape(to))\" ORDER BY created"
        async let pages = get("/rest/api/content/search", query: [("cql", pagesCQL), ("limit", "100"), ("expand", "version,history")])
        async let comments = get("/rest/api/content/search", query: [("cql", commentsCQL), ("limit", "100"), ("expand", "container,history,body.view")])
        var out = try await pages["results"].list.map { WikiBrowse.work($0, me: key) }
        out += try await comments["results"].list.map { r in
            WikiWork(at: r["history"]["createdDate"].text, kind: "comment", pageId: r["container"]["id"].text, title: r["container"]["title"].text, detail: String(WikiBrowse.stripHTML(r["body"]["view"]["value"].text).prefix(120)))
        }
        return out.sorted { $0.at < $1.at }
    }
    public func resolvePage(_ input: String) async throws -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = parsePageID(input) { return id }
        guard let url = URLComponents(string: input), url.scheme != nil else { return nil }
        let basePath = URLComponents(string: baseURL)?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        var path = url.percentEncodedPath
        if !basePath.isEmpty, path.hasPrefix("/" + basePath + "/") { path = String(path.dropFirst(basePath.utf8.count + 1)) }
        let parts = path.split(separator: "/").map { WikiBrowse.percentDecode(String($0)) }
        func query(_ name: String) -> String? { url.queryItems?.first { $0.name == name }?.value }
        if parts.count >= 2, parts[0] == "x" { return WikiBrowse.decodeTiny(parts[1]) }
        if parts.count == 2, parts[0] == "display" { return try await spaceHome(parts[1]) }
        if parts.count >= 3, parts[0] == "display" { return try await findByTitle(space: parts[1], title: parts[2].replacingOccurrences(of: "+", with: " ")) }
        if parts.count == 2, parts[0] == "pages", ["viewpage.action", "editpage.action"].contains(parts[1]), let space = query("spaceKey"), let title = query("title") { return try await findByTitle(space: space, title: title) }
        if parts == ["spaces", "viewspace.action"], let space = query("key") { return try await spaceHome(space) }
        return nil
    }
    private func spaceHome(_ space: String) async throws -> String? {
        try await get("/rest/api/space/" + RESTClient.component(space), query: [("expand", "homepage")])["homepage"]["id"].string
    }
    private func findByTitle(space: String, title: String) async throws -> String? {
        for kind in ["page", "blogpost"] {
            let raw = try await get("/rest/api/content", query: [("spaceKey", space), ("title", title), ("type", kind)])
            if let id = raw["results"].list.first?["id"].string { return id }
        }
        return nil
    }
}
