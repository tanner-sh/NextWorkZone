import Foundation
import Testing
import NWZCore
import NWZJira
import NWZWorkspace
@testable import NWZServices

private actor JiraTestWeb: WebResourceSource {
    var urls: [String] = []
    func fetch(service: Service, url: String) throws -> (Data, String?) { urls.append(url); return (Data("文本".utf8), "text/plain") }
}
struct JiraServiceTests {
    func settings(_ directory: URL, transport: OfflineTransport) throws -> SettingsService {
        let paths = AppPaths(dataDirectory: directory); try paths.createDirectories()
        let configuration = try ConfigurationStore(path: paths.config)
        try configuration.update { $0.jira.baseUrl = "https://jira.example.com" }
        try paths.credentialsStore.save([Secret.token.key(for: .jira): "test-token"])
        return try SettingsService(paths: paths, configuration: configuration, client: HTTPClient(transport: transport))
    }
    @Test func activityStoreDeduplicatesAndKeepsReadReceipts() async throws {
        let store = try ActivityStore()
        #expect(try await store.prepare(system: "jira", identity: "first") == nil)
        let event = NWZJira.ActivityEvent(id: "PROJ-123:c:1", issueKey: "PROJ-123", at: "2026-10-25T10:00:00Z", system: "jira")
        let first = try await store.merge([event], checks: ["jira":"2026-10-25T11:00:00Z"])
        #expect(first.fresh.count == 1 && first.feed.unread == 1)
        _ = try await store.markRead([event.id])
        let duplicate = try await store.merge([event], checks: [:])
        #expect(duplicate.fresh.isEmpty && duplicate.feed.unread == 0)
        #expect(try await store.prepare(system: "jira", identity: "first") == "2026-10-25T11:00:00Z")
        _ = try await store.prepare(system: "wiki", identity: "wiki")
        _ = try await store.merge([.init(id: "wiki:1", at: event.at, system: "wiki")], checks: [:])
        _ = try await store.prepare(system: "jira", identity: "second")
        #expect(try await store.feed().events.map(\.id) == ["wiki:1"])
    }
    @Test func firstPollMarksHistoryReadAndNextPollFindsNewEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let at = Date().addingTimeInterval(-60).ISO8601Format()
        func response(_ count: Int) throws -> String {
            let raw: JSONValue = ["issues":[["key":"PROJ-123", "fields":["summary":"概要", "comment":["comments":.array((1...count).map { ["id":.string(String($0)), "author":["name":"ls", "displayName":"李四"], "created":.string(at), "body":"评论"] })]]]]]
            return String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        }
        let transport = OfflineTransport([.response(200, #"{"name":"me"}"#), .response(200, try response(1)), .response(200, try response(2))])
        let service = try JiraService(settings: settings(directory, transport: transport), host: WorkspaceTestHost(), web: JiraTestWeb())
        let first = try await service.pollActivity()
        #expect(first.feed.events.count == 1 && first.feed.unread == 0 && first.fresh.isEmpty)
        let second = try await service.pollActivity()
        #expect(second.feed.events.count == 2 && second.fresh.map(\.id) == ["PROJ-123:c:2"])
    }
    @Test func partialAssignedResultsDoNotCompleteTodos() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = OfflineTransport([.response(200, #"{"total":2,"issues":[]}"#)])
        let settings = try settings(directory, transport: transport)
        try await settings.updateConfiguration { $0.workspace.jiraTodos = true }
        let service = try JiraService(settings: settings, host: WorkspaceTestHost(), web: JiraTestWeb()), workspace = try await Workspace()
        _ = try await workspace.syncJiraTodos([.init(key: "PROJ-123", summary: "保留待办")])
        await #expect(throws: NWZError.self) { try await service.refreshTodos(in: workspace) }
        #expect(try await workspace.todos().first?.done == false)
    }
    @Test func createdIssueSurvivesAttachmentFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = OfflineTransport([.response(201, #"{"key":"PROJ-123"}"#), .response(503, "离线上传失败")])
        let service = try JiraService(settings: settings(directory, transport: transport), host: WorkspaceTestHost(), web: JiraTestWeb())
        let file = directory.appendingPathComponent("sample.txt"); try Data("附件".utf8).write(to: file)
        let created = try await service.createIssue(fields: ["summary":"概要"], attachments: [file.path])
        #expect(created.key == "PROJ-123" && created.attachmentError?.contains("离线上传失败") == true)
        #expect(await transport.requests.count == 2)
        await #expect(throws: NWZError.self) { try await service.readOnly("jira_create_issue", arguments: [:]) }
    }
    @Test func attachmentsRejectOtherOriginsBeforeCallingWebBridge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = JiraTestWeb(), service = AttachmentService(settings: try settings(directory, transport: OfflineTransport([])), web: web, host: WorkspaceTestHost())
        await #expect(throws: NWZError.self) { try await service.fetch(service: .jira, url: "https://other.example.com/a.png") }
        await #expect(throws: NWZError.self) { try await service.fetch(service: .jira, url: "http://jira.example.com/a.png") }
        #expect(await web.urls.isEmpty)
        _ = try await service.fetch(service: .jira, url: "/attachment/a.txt")
        #expect(await web.urls == ["https://jira.example.com/attachment/a.txt"])
    }
    @Test func remindersChoosePopulatedDateFieldAndSortByUrgency() throws {
        var config = JiraToolsConfig(); config.dueSoonDays = 2; config.staleDays = 7
        let fields = [FieldInfo(id: "customfield_1", name: "计划完成日期", custom: true, kind: "date"), FieldInfo(id: "customfield_2", name: "备注", custom: true, kind: "string")]
        let candidates = JiraReminders.candidates(configured: "", fields: fields)
        #expect(candidates.map(\.id) == ["duedate", "customfield_1"])
        let issues = ["2026-10-26", "2026-10-24", "2026-10-25", "2026-11-01"].enumerated().map { index, day in
            var issue = IssueSummary(raw: JSONDocument(value: ["key":.string("PROJ-\(index + 1)"), "fields":["summary":"概要", "updated":"2026-10-01T10:00:00Z"]]))
            issue.extra = ["customfield_1":day]; return issue
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reminders = JiraReminders.make(issues: issues, candidates: candidates, config: config, now: try #require(JiraActivity.time("2026-10-25T10:00:00Z")), calendar: calendar)
        #expect(reminders.dueField?.id == "customfield_1")
        #expect(reminders.items.map(\.kind) == ["overdue", "today", "soon", "stale"])
        #expect(reminders.items.map(\.days) == [-1, 0, 1, 24])
    }
}
