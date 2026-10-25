import Foundation
import Testing
import NWZCore
@testable import NWZServices

/// 按地址返回预设响应；可以模拟服务器把请求重定向到登录页（同站时最终地址不同，跨站时返回 3xx）。
private actor RoutedTransport: HTTPTransport {
    struct Route: Sendable { var status = 200; var body = "ok"; var finalURL: String?; var setCookie: String? }
    private let routes: [String: Route]
    private(set) var requests: [URLRequest] = []
    init(_ routes: [String: Route]) { self.routes = routes }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        let url = request.url!.absoluteString
        guard let route = routes.first(where: { url.hasPrefix($0.key) })?.value else { throw NWZError.other("没有预设响应：\(url)") }
        return HTTPResponse(data: Data(route.body.utf8), status: route.status, headers: route.setCookie.map { ["Set-Cookie": $0] } ?? [:], url: URL(string: route.finalURL ?? url)!)
    }
}

struct WebSessionTests {
    private func service(_ transport: RoutedTransport) async throws -> (URL, WebSessionService, WorkspaceTestHost) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = AppPaths(dataDirectory: directory)
        let settings = try SettingsService(paths: paths, configuration: ConfigurationStore(path: paths.config), client: HTTPClient(transport: transport))
        _ = try await settings.saveSettings(SettingsInput(baseUrls: ["jira": "https://jira.example.com"], tokens: ["jira": "sample-token"]))
        let host = WorkspaceTestHost()
        return (directory, WebSessionService(settings: settings, host: host), host)
    }

    @Test func autofillScriptEscapesCredentials() {
        let script = WebSessionService.autofillScript(base: "https://jira.example.com", username: "zhang\"san", password: "p'a\"ss</script>\\n")
        #expect(script.contains(#"window.location.origin !== "https://jira.example.com""#))
        #expect(script.contains(#"set(user, "zhang\"san");"#))
        #expect(script.contains(#"set(pass, "p'a\"ss</script>\\n");"#))
    }

    @Test func loginKeepsSessionAndMergesRotatedCookies() async throws {
        let transport = RoutedTransport([
            "https://jira.example.com/secure/ViewProfile.jspa": .init(),
            "https://jira.example.com/secure/attachment/1": .init(body: "file", setCookie: "JSESSIONID=new; Path=/"),
        ])
        let (directory, sessions, host) = try await service(transport)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 还停在登录页时不保存
        #expect(try await sessions.loginFinish(.jira, url: "https://jira.example.com/login.jsp", cookie: "JSESSIONID=old") == false)
        #expect(try await sessions.loginFinish(.jira, url: "https://jira.example.com/secure/Dashboard.jspa", cookie: "JSESSIONID=old; seraph=1"))
        #expect(await sessions.accessStatus()["jira"] == .session)
        #expect(host.events.withLock { $0.map(\.name) } == [WebSessionService.sessionEvent])

        let (data, _) = try await sessions.fetch(service: .jira, url: "https://jira.example.com/secure/attachment/1")
        #expect(data == Data("file".utf8))
        let sent = await transport.requests.last!
        #expect(sent.value(forHTTPHeaderField: "Cookie") == "JSESSIONID=old; seraph=1")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        // 轮换后的 Cookie 写回文件，重新打开后仍然有效
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("web-sessions.json")))
        #expect(saved["jira-session"] == "JSESSIONID=new; seraph=1")
    }

    @Test func loginRedirectClearsSessionAndCrossSiteRedirectNeedsLogin() async throws {
        let transport = RoutedTransport([
            "https://jira.example.com/secure/ViewProfile.jspa": .init(),
            "https://jira.example.com/secure/attachment/1": .init(finalURL: "https://jira.example.com/login.jsp?os_destination=x"),
            "https://jira.example.com/secure/attachment/2": .init(status: 302, body: ""),
        ])
        let (directory, sessions, _) = try await service(transport)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await sessions.loginFinish(.jira, url: "https://jira.example.com/secure/Dashboard.jspa", cookie: "JSESSIONID=old")
        await #expect(throws: NWZError.sessionRequired(.jira)) { try await sessions.fetch(service: .jira, url: "https://jira.example.com/secure/attachment/1") }
        #expect(await sessions.accessStatus()["jira"] == .token)
        // 没有会话时用 Token；被重定向到单点登录站点（跨站，不跟随）时同样需要网页登录
        await #expect(throws: NWZError.sessionRequired(.jira)) { try await sessions.fetch(service: .jira, url: "https://jira.example.com/secure/attachment/2") }
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sample-token")
    }

    @Test func recognizesIssueKeys() {
        #expect(SearchService.isIssueKey("ABC-123"))
        #expect(SearchService.isIssueKey("proj_2-7"))
        #expect(!SearchService.isIssueKey("ABC-"))
        #expect(!SearchService.isIssueKey("1AB-2"))
        #expect(!SearchService.isIssueKey("修复 ABC-1"))
    }
}
