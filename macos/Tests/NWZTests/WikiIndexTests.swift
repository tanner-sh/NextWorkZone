import Foundation
import Testing
import NWZCore
@testable import NWZWiki

@Suite struct WikiIndexTests {
    func page(_ id: String, _ title: String, _ storage: String) -> IndexedWikiPage {
        IndexedWikiPage(id: id, kind: "page", spaceKey: "S", spaceName: "空间", title: title, ancestors: [WikiAncestor(id: "1", title: "首页")], author: "me", authorName: "我", modified: "2026-10-20T10:00:00.000+08:00", version: 3, storage: storage)
    }
    @Test func searchReferencesAndTasks() async throws {
        let index = try WikiIndex()
        try await index.upsert([page("10", "部署手册", "<p>如何部署 Nginx 服务 ABC-12</p>"), page("11", "周报", #"<p>本周处理 <ac:structured-macro ac:name="jira"><ac:parameter ac:name="key">ABC-12</ac:parameter></ac:structured-macro></p><ac:task-list><ac:task><ac:task-id>1</ac:task-id><ac:task-status>incomplete</ac:task-status><ac:task-body>跟进部署 <ac:link><ri:user ri:userkey="me" /></ac:link></ac:task-body></ac:task></ac:task-list>"#)])
        let hits = try await index.search(WikiQuery(text: "部署"))
        #expect(hits.count == 2 && hits.first?.id == "10")
        #expect(try await index.search(WikiQuery(text: "nginx 服务")).first?.snippet.contains("Nginx") == true)
        #expect(try await index.pagesWithIssue("ABC-12", limit: 10).count == 2)
        #expect(try await index.pagesWithIssue("ABC-1", limit: 10).isEmpty)
        #expect(try await index.assignedTasks("me").first?.pageTitle == "周报")
        try await index.setTaskDone(page: "11", task: "1", done: true)
        #expect(try await index.assignedTasks("me").isEmpty)
        #expect(try await index.prune(alive: ["10"]) == 1)
        #expect(try await index.stats().count == 1)
    }
    @Test func trigramFollowsUpdatesAndRebuilds() async throws {
        let index = try WikiIndex()
        try await index.upsert([page("1", "Redis 部署", "<p>主从切换</p>"), page("2", "接口文档", "<p>redis 缓存说明</p>")])
        #expect(try await index.search(WikiQuery(text: "redis")).map(\.id).sorted() == ["1", "2"])
        #expect(try await index.search(WikiQuery(text: "主从切换")).map(\.id) == ["1"])
        try await index.upsert([page("1", "Redis 部署", "<p>哨兵模式</p>")])
        #expect(try await index.search(WikiQuery(text: "主从切换")).isEmpty)
        try await index.checkIntegrity()
        _ = try await index.prune(alive: ["1"])
        try await index.checkIntegrity()
        try await index.upsert([page("3", "进度", "<p>完成 100% a_b</p>")])
        #expect(try await index.search(WikiQuery(text: "100%")).map(\.id) == ["3"])
        #expect(try await index.search(WikiQuery(text: "a_b")).map(\.id) == ["3"])
        try await index.clear()
        try await index.checkIntegrity()
        #expect(try await index.search(WikiQuery(text: "redis")).isEmpty)
        try await index.upsert([page("4", "Redis", "<p>新内容</p>")])
        try await index.upsert([page("4", "Redis", "<p>再次更新</p>")])
        _ = try await index.prune(alive: [])
        try await index.checkIntegrity()
    }
    @Test func schemaOneHasFTSAndSurvivesReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("wiki.sqlite").path
        let first = try WikiIndex(path: path)
        try await first.upsert([page("1", "Redis", "<p>主从切换</p>")])
        let second = try WikiIndex(path: path)
        #expect(try await second.search(WikiQuery(text: "主从切换")).map(\.id) == ["1"])
        try await second.checkIntegrity()
        let db = try Database(path: path)
        #expect(try await db.query("PRAGMA user_version").first?["user_version"]?.integer == 1)
    }
    @Test func snippetsAndFilters() async throws {
        let index = try WikiIndex(), long = "<p>" + String(repeating: "前", count: 100) + "关键 Redis   集群</p>"
        try await index.upsert([page("1", "标题", long), page("2", "Redis", "<p>开头的文字</p>")])
        #expect(try await index.search(WikiQuery(text: "redis")).first?.id == "2")
        #expect(try await index.search(WikiQuery(text: "redis")).first { $0.id == "1" }?.snippet == "…" + String(repeating: "前", count: 27) + "关键 Redis 集群")
        #expect(try await index.search(WikiQuery(text: "标题 集群")).first?.snippet == "…" + String(repeating: "前", count: 21) + "关键 Redis 集群")
        #expect(try await index.search(WikiQuery(space: "other")).isEmpty)
        #expect(try await index.search(WikiQuery(mine: true), me: "other").isEmpty)
    }
    @Test func viewedAndScope() async throws {
        let index = try WikiIndex()
        try await index.ensureScope(base: "https://wiki.example.com", spaces: [])
        try await index.markViewed("1", title: "A", space: "S")
        try await index.markViewed("2", title: "B", space: "S")
        try await index.markViewed("1", title: "A", space: "S")
        #expect(try await index.recent(limit: 10).count == 2)
        try await index.ensureScope(base: "https://wiki.example.com", spaces: ["S"])
        #expect(try await index.recent(limit: 10).count == 2)
        try await index.clear()
        #expect(try await index.recent(limit: 10).count == 2)
        try await index.ensureScope(base: "https://other.example.com", spaces: [])
        #expect(try await index.recent(limit: 10).isEmpty)
    }
}
