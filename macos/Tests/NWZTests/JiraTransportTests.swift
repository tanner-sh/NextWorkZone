import Foundation
import Testing
import NWZCore
@testable import NWZJira

struct JiraTransportTests {
    func client(_ transport: OfflineTransport) -> JiraClient { JiraClient(baseURL: "https://jira.example.com/context", token: "test-token", http: HTTPClient(transport: transport)) }
    func body(_ request: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)) }
    @Test func writesTransitionsCommentsAndVisibilityOffline() async throws {
        let transport = OfflineTransport(Array(repeating: .response(200, "{}"), count: 4)), jira = client(transport)
        try await jira.transition("PROJ-123", transitionID: "5", fields: ["resolution":["id":"1"]])
        let visibility = CommentVisibility(type: "role", value: "Developers")
        _ = try await jira.saveComment("PROJ-123", body: "说明", visibility: visibility)
        _ = try await jira.saveComment("PROJ-123", id: "7", body: "修改", visibility: nil)
        try await jira.deleteComment("PROJ-123", id: "7")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "PUT", "DELETE"])
        #expect(try body(requests[0]) == ["transition":["id":"5"], "fields":["resolution":["id":"1"]]])
        #expect(try body(requests[1]) == ["body":"说明", "visibility":["type":"role", "value":"Developers"]])
        #expect(try body(requests[2]) == ["body":"修改"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" && $0.url?.path.hasPrefix("/context/rest/api/2/") == true })
    }
    @Test func deletesAttachmentOffline() async throws {
        let transport = OfflineTransport([.response(204, "")]), jira = client(transport)
        try await jira.deleteAttachment(id: "10086")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "DELETE" && request.url?.path == "/context/rest/api/2/attachment/10086")
    }
    @Test func writesIssueAssignmentsWatchingAndLinksOffline() async throws {
        let transport = OfflineTransport(Array(repeating: .response(200, #"{"key":"PROJ-123"}"#), count: 7)), jira = client(transport)
        #expect(try await jira.createIssue(fields: ["summary":"新问题"]) == "PROJ-123")
        try await jira.assign("PROJ-123", username: nil)
        try await jira.updateIssue("PROJ-123", fields: ["priority":["id":"2"]])
        try await jira.setWatching("PROJ-123", me: "zs", watching: true)
        try await jira.setWatching("PROJ-123", me: "zs", watching: false)
        try await jira.addLink("PROJ-123", typeID: "1", other: "ABC-1", outward: false)
        try await jira.deleteLink("10")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "PUT", "PUT", "POST", "DELETE", "POST", "DELETE"])
        #expect(try body(requests[0]) == ["fields":["summary":"新问题"]])
        #expect(try body(requests[1]) == ["name": .null])
        #expect(try body(requests[2]) == ["fields":["priority":["id":"2"]]])
        #expect(try body(requests[3]) == "zs")
        #expect(URLComponents(url: requests[4].url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "username", value: "zs")])
        #expect(try body(requests[5]) == ["type":["id":"1"], "inwardIssue":["key":"ABC-1"], "outwardIssue":["key":"PROJ-123"]])
    }
    @Test func writesWorklogsUploadAndRendererOffline() async throws {
        let transport = OfflineTransport([.response(200, "{}"), .response(200, "{}"), .response(200, "{}"), .response(200, "[]"), .response(200, "<p>预览</p>")]), jira = client(transport)
        let input = WorklogInput(started: "2026-10-22T09:00:00.000+0800", timeSpent: "3h 30m", comment: "说明")
        try await jira.saveWorklog("PROJ-123", id: nil, input: input)
        try await jira.saveWorklog("PROJ-123", id: "1", input: input)
        try await jira.deleteWorklog("PROJ-123", id: "1")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("离线附件".utf8).write(to: file)
        #expect(try await jira.uploadAttachment("PROJ-123", file: file).isEmpty)
        #expect(try await jira.renderWiki("*预览*", issueKey: "PROJ-123") == "<p>预览</p>")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "PUT", "DELETE", "POST", "POST"])
        #expect(try body(requests[0]) == .from(input))
        #expect(requests[3].value(forHTTPHeaderField: "X-Atlassian-Token") == "no-check")
        #expect(requests[3].httpBody?.range(of: Data("离线附件".utf8)) != nil)
        #expect(try body(requests[4]) == ["rendererType":"atlassian-wiki-renderer", "unrenderedMarkup":"*预览*", "issueKey":"PROJ-123"])
        // 渲染接口返回 HTML，只接受 JSON 时真实的 Jira 会回 406
        #expect(requests[4].value(forHTTPHeaderField: "Accept") == "text/html")
    }
    @Test func readsOrderedFieldsAndProtectsCredentials() async throws {
        let transport = OfflineTransport([.response(200, #"{"fields":{"summary":"内容"},"editmeta":{"fields":{"summary":{"name":"概要","schema":{"type":"string"}},"duedate":{"name":"日期"}}}}"#)]), jira = client(transport)
        let fields = try await jira.editFields("PROJ-123")
        #expect(fields.map(\.key) == ["summary", "duedate"] && fields[0].value == "内容")
        await #expect(throws: NWZError.self) { try await jira.get("https://other.example.com/rest/api/2/myself") }
        await #expect(throws: NWZError.self) { try await jira.get("http://jira.example.com/context/rest/api/2/myself") }
        #expect(await transport.requests.count == 1)
    }
    @Test func preservesJSONOrderEscapesAndRejectsTruncation() throws {
        let raw = try JSONDocument(data: Data(#"{"z":1,"键\u540d":[true,null,{"first":"\"文本\"","second":-2.5}],"a":3}"#.utf8))
        #expect(raw.keys == ["z", "键名", "a"] && raw["键名"][2].keys == ["first", "second"])
        #expect(raw["键名"][2]["first"].text == "\"文本\"")
        #expect(raw["键名"][2]["second"].number == -2.5)
        for text in ["{", "[1,]", "{\"a\":}", "\"bad\\", "true false"] { #expect(throws: (any Error).self) { try JSONDocument(data: Data(text.utf8)) } }
    }
    @Test func synchronizesPagesIncrementally() async throws {
        let transport = OfflineTransport([.response(200, #"{"total":1,"issues":[{"key":"PROJ-123","fields":{"summary":"概要","updated":"2026-10-22T10:00:00.000+0800"}}]}"#), .response(200, #"{"total":0,"issues":[]}"#)])
        let index = try IssueIndex(), jira = client(transport), scope = IndexScope(jql: "project = PROJ ORDER BY created DESC", days: 730)
        #expect(try await index.sync(client: jira, scope: scope) == 1)
        #expect(try await index.sync(client: jira, scope: scope) == 0)
        let requests = await transport.requests
        let jql = requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "jql" }!.value! }
        #expect(jql[0] == "(project = PROJ) AND created >= -730d ORDER BY updated ASC")
        #expect(jql[1].contains("updated >= -") && jql[1].hasSuffix("ORDER BY updated ASC"))
        #expect(try await index.stats().count == 1)
    }
}
