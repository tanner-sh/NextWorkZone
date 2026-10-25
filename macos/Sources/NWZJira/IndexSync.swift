import Foundation
import NWZCore

public struct IndexScope: Sendable {
    public var jql: String
    public var days: Int
    public init(jql: String = "", days: Int = 730) { self.jql = jql; self.days = days }
}

extension IssueIndex {
    public func sync(client: JiraClient, scope: IndexScope, progress: @Sendable (IndexProgress) async -> Void = { _ in }) async throws -> Int {
        try await ensureBase(client.baseURL)
        let window = scope.days > 0 ? " AND created >= -\(scope.days)d" : ""
        let scopes: [(String, String, String)]
        if scope.jql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scopes = try await client.involvedProjects().map { ("project:" + $0, $0, "project = \"\(JiraQueries.escape($0))\"") } }
        else { let jql = JiraIndexText.stripOrder(scope.jql); scopes = [("jql:" + jql, "自定义范围", jql)] }
        var changed = 0
        for (number, (id, label, base)) in scopes.enumerated() {
            let since: String
            if let cursor = try await cursor(id), let time = JiraActivity.time(cursor) { since = " AND updated >= -\(max(0, Int(Date().timeIntervalSince(time) / 60)) + 5)m" } else { since = "" }
            let jql = "(\(base))\(window)\(since) ORDER BY updated ASC"
            var start = 0
            while true {
                try Task.checkCancellation()
                let (total, issues) = try await client.indexPage(jql, startAt: start, maxResults: 100)
                guard !issues.isEmpty else { break }
                try await upsert(issues)
                if let latest = issues.map({ $0.issue.updated }).max(by: { (JiraActivity.time($0) ?? .distantPast) < (JiraActivity.time($1) ?? .distantPast) }) { try await setCursor(id, cursor: latest) }
                start += issues.count; changed += issues.count
                await progress(IndexProgress(scope: label, done: min(start, total), total: total, finished: number, scopes: scopes.count))
                if start >= total { break }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        try await finishSync(changed: changed)
        return changed
    }
}

extension JiraClient {
    public func involvedProjects() async throws -> [String] {
        var counts: [String: Int] = [:], start = 0
        while true {
            let raw = try await get("/rest/api/2/search", query: [("jql", "assignee was currentUser() OR reporter = currentUser()"), ("fields", "project"), ("startAt", String(start)), ("maxResults", "1000")])
            let issues = raw["issues"].list
            for issue in issues { counts[issue["fields"]["project"]["key"].text, default: 0] += 1 }
            start += issues.count
            if issues.isEmpty || start >= raw["total"].int || start >= 5000 { break }
        }
        return counts.filter { !$0.key.isEmpty }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
    public func indexPage(_ jql: String, startAt: Int, maxResults: Int) async throws -> (Int, [IndexedIssue]) {
        let fields = "summary,status,issuetype,priority,project,assignee,reporter,resolution,created,updated,duedate,resolutiondate,description,comment"
        let raw = try await get("/rest/api/2/search", query: [("jql", jql), ("fields", fields), ("startAt", String(startAt)), ("maxResults", String(maxResults))])
        return (raw["total"].int, raw["issues"].list.map(IndexedIssue.init(raw:)))
    }
    public func similarHits(_ jql: String, maxResults: Int) async throws -> [IssueHit] { try await indexPage(jql, startAt: 0, maxResults: maxResults).1.map { $0.hit(boilerplate: []) } }
}
