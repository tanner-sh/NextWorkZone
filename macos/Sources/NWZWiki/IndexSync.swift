import Foundation
import NWZCore

public struct WikiScope: Sendable {
    public var spaces: [String]
    public init(spaces: [String] = []) { self.spaces = spaces }
    public var cql: String {
        "type in (page, blogpost)" + (spaces.isEmpty ? "" : " AND space in (" + spaces.map { "\"" + WikiBrowse.cqlEscape($0) + "\"" }.joined(separator: ", ") + ")")
    }
}

extension WikiIndex {
    public func sync(client: WikiClient, scope: WikiScope, now: Date = Date(), pause: Duration = .milliseconds(200), progress: @Sendable (WikiIndexProgress) async -> Void = { _ in }) async throws -> Int {
        try await ensureScope(base: client.baseURL, spaces: scope.spaces, identity: client.rest.cacheIdentity)
        let base = scope.cql
        let since = try await get("cursor").flatMap(Self.time).map { " AND lastmodified >= now(\"-\(max(0, Int(now.timeIntervalSince($0) / 60)) + 5)m\")" } ?? ""
        let cql = base + since + " ORDER BY lastmodified ASC"
        var start = 0, changed = 0, total = 0
        while true {
            try Task.checkCancellation()
            guard let batch = try await client.indexBatch(cql: cql, start: start) else {
                if start == 0 { throw NWZError.other("获取 Wiki 页面失败，请稍后重试") }
                start += 1
                if start >= total { break }
                continue
            }
            try Task.checkCancellation()
            total = batch.total
            if batch.pages.isEmpty { break }
            try await upsert(batch.pages)
            if let latest = batch.pages.map(\.modified).max(by: { (Self.time($0) ?? .distantPast) < (Self.time($1) ?? .distantPast) }) { try await put("cursor", latest) }
            start += batch.pages.count; changed += batch.pages.count
            await progress(WikiIndexProgress(done: min(start, total), total: total))
            if start >= total { break }
            try await Task.sleep(for: pause)
        }
        let lastPrune = try await get("last_prune").flatMap(Int64.init) ?? 0
        if Int64(now.timeIntervalSince1970 * 1000) - lastPrune > 86_400_000 {
            let alive = try await client.allPageIDs(cql: base, pause: pause)
            try Task.checkCancellation()
            _ = try await prune(alive: alive)
            try await put("last_prune", String(Int64(now.timeIntervalSince1970 * 1000)))
        }
        try await put("last_sync", now.ISO8601Format())
        return changed
    }
}

extension WikiClient {
    public func indexPage(cql: String, start: Int, limit: Int) async throws -> (total: Int, pages: [IndexedWikiPage]) {
        let raw = try await get("/rest/api/content/search", query: [("cql", cql), ("start", String(start)), ("limit", String(limit)), ("expand", "body.storage,version,space,ancestors")])
        return (raw["totalSize"].int, raw["results"].list.compactMap(IndexedWikiPage.init(raw:)))
    }
    func indexBatch(cql: String, start: Int) async throws -> (total: Int, pages: [IndexedWikiPage])? {
        for size in [50, 10, 1] {
            do { return try await indexPage(cql: cql, start: start, limit: size) }
            catch is CancellationError { throw CancellationError() }
            catch NWZError.unauthorized(let status) { throw NWZError.unauthorized(status) }
            catch NWZError.forbidden(let status) { throw NWZError.forbidden(status) }
            catch NWZError.sessionRequired(let service) { throw NWZError.sessionRequired(service) }
            catch { try Task.checkCancellation() }
        }
        return nil
    }
    func allPageIDs(cql: String, pause: Duration) async throws -> Set<String> {
        var ids: Set<String> = [], start = 0
        while true {
            try Task.checkCancellation()
            let raw = try await get("/rest/api/content/search", query: [("cql", cql), ("start", String(start)), ("limit", "500")])
            let results = raw["results"].list, total = raw["totalSize"].int
            if results.isEmpty {
                // 列表未完整返回时不能据此删除本机记录。
                if start < total { throw NWZError.other("Wiki 页面清单尚未完整返回，已跳过删除清理") }
                break
            }
            ids.formUnion(results.compactMap { $0["id"].string })
            start += results.count
            if start >= total { break }
            try await Task.sleep(for: pause)
        }
        return ids
    }
}
