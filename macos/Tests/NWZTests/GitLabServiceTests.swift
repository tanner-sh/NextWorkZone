import Foundation
import Testing
import NWZCore
import NWZJira
import NWZGitLab
import NWZServices

private struct GitLabTestWeb: WebResourceSource {
    func fetch(service: Service, url: String) async throws -> (Data, String?) { (Data(), nil) }
}
@Suite struct GitLabServiceTests {
    func service(_ dir: URL, transport: CodeTransport) throws -> (GitLabService, SettingsService) {
        let paths = AppPaths(dataDirectory: dir); try paths.createDirectories()
        let config = try ConfigurationStore(path: paths.config)
        try config.update { $0.gitlab.baseUrl = "https://git.example.com" }
        try paths.credentialsStore.save([Secret.token.key(for: .gitlab): "test-token"])
        let settings = try SettingsService(paths: paths, configuration: config, client: HTTPClient(transport: transport)), host = WorkspaceTestHost(), web = GitLabTestWeb()
        return (GitLabService(settings: settings, jira: try JiraService(settings: settings, host: host, web: web), host: host, web: web), settings)
    }
    @Test func inboxDeduplicatesSelfAuthoredItemsAndScopesCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = CodeTransport { request in
            if request.url!.path.hasSuffix("/user") { return (200, #"{"id":1,"name":"张三"}"#) }
            return (200, #"[{"id":1,"iid":1,"project_id":7,"author":{"id":1}},{"id":2,"iid":2,"project_id":7,"author":{"id":2,"name":"李四"},"title":"请审核"}]"#)
        }
        let (service, settings) = try service(dir, transport: t), now = Date()
        let items = try await service.inboxItems(now: now)
        #expect(items.count == 1 && items[0].detail.hasSuffix("请你审核"))
        let count = await t.requests.count
        #expect(try await service.inboxItems(now: now.addingTimeInterval(119)) == items)
        #expect(await t.requests.count == count)
        try await settings.updateConfiguration { $0.gitlab.baseUrl = "https://other.example.com" }
        _ = try await service.inboxItems(now: now.addingTimeInterval(119))
        #expect(await t.requests.count > count)
    }
    @Test func weeklyWorkFiltersLocalDatesAndMergeCommits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let day = try #require(f.date(from: "2026-10-22")), at = day.addingTimeInterval(3600).ISO8601Format(), outside = day.addingTimeInterval(-86400).ISO8601Format()
        let raw: JSONValue = .array([at, outside].map { .object(["action_name":"pushed to", "project_id":7, "created_at":.string($0), "push_data":["ref":"feature/ABC-1", "commit_title":"修复导入", "commit_count":2]]) } + [["action_name":"pushed to", "project_id":7, "created_at":.string(at), "push_data":["ref":"main", "commit_title":"Merge branch feature", "commit_count":1]]])
        let response = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        let t = CodeTransport { request in request.url!.path.hasSuffix("/events") ? (200, response) : (200, #"{"id":7,"name":"项目"}"#) }
        let (service, _) = try service(dir, transport: t)
        let work = try await service.weeklyWork(from: "2026-10-22", to: "2026-10-22")
        #expect(work.count == 2 && work[0].keys == ["ABC-1"] && work[0].standalone == "修复导入")
        #expect(work[1].standalone == nil)
        await #expect(throws: NWZError.self) { try await service.readOnly("gl_mr_merge", arguments: [:]) }
        #expect(await t.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
