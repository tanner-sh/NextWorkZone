import Foundation
import Synchronization
import Testing
@testable import NWZCore
@testable import NWZServices

struct SettingsTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func service(_ directory: URL, transport: OfflineTransport? = nil) throws -> SettingsService {
        let paths = AppPaths(home: directory, development: true, environment: ["NWZ_DATA_DIR": directory.path])
        return try SettingsService(paths: paths, configuration: ConfigurationStore(path: paths.config),
                                   client: transport.map { HTTPClient(transport: $0) })
    }

    @Test func savesTypedSettings() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = try service(dir)
        #expect(await settings.getSettings().services.allSatisfy { !$0.hasToken })
        let input = SettingsInput(baseUrls: ["jira": "jira.example.com/secure/Dashboard.jspa", "confluence": "wiki.example.com"], tokens: ["jira": " token "], weeklyPage: "42", weeklyPersonName: "张三", webAccounts: ["jira": .init(username: "jira-user", password: "first"), "confluence": .init(username: "wiki-user", password: "second")])
        let saved = try await settings.saveSettings(input)
        #expect(saved.services[0].baseUrl == "https://jira.example.com")
        #expect(await settings.secret(.token, for: .jira) == "token")
        #expect(await settings.secret(.webPassword, for: .confluence) == "second")
        #expect(settings.configuration.snapshot().weekly.pageId == "42")
        let reopened = try service(dir)
        #expect(await reopened.getSettings() == saved)
        let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("token"))
    }

    @Test func blankTokensPreserveAndBlankAccountsDelete() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = try service(dir)
        _ = try await settings.saveSettings(.init(tokens: ["jira": "sample"], webAccounts: ["jira": .init(username: "example-user", password: "sample-password")]))
        _ = try await settings.saveSettings(.init(tokens: ["jira": " "], webAccounts: ["jira": .init(username: "example-user", password: "")]))
        #expect(await settings.getSettings().services[0].hasWebPassword)
        _ = try await settings.saveSettings(.init(webAccounts: ["jira": .init(username: "", password: "")]))
        let account = await settings.getSettings().services[0]
        #expect(account.hasToken && !account.hasWebPassword && account.webUsername.isEmpty)
        #expect(try await settings.clearToken(.jira).services[0].hasToken == false)
    }

    @Test func validatesBeforeWritingAndPreservesOtherDomains() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigurationStore(path: dir.appendingPathComponent("config.json"))
        let paths = AppPaths(home: dir, development: true, environment: ["NWZ_DATA_DIR": dir.path])
        let settings = try SettingsService(paths: paths, configuration: store)
        try store.update { $0.workspace.syncDir = "/tmp/shared"; $0.tools.hidden = ["clipboard"] }
        _ = try await settings.saveSettings(.init(baseUrls: ["jira": "jira.example.com"]))
        #expect(store.snapshot().workspace.syncDir == "/tmp/shared")
        #expect(store.snapshot().tools.hidden == ["clipboard"])
        await #expect(throws: NWZError.self) { try await settings.saveSettings(.init(baseUrls: ["jira": "ftp://example.com"], tokens: ["jira": "should-not-save"])) }
        #expect(await settings.getSettings().services[0].hasToken == false)
        #expect(store.snapshot().jira.baseUrl == "https://jira.example.com")
    }

    @Test func tokenImportHandlesMissingFile() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = try service(dir)
        await #expect(throws: NWZError.self) { try await settings.importTokensEnv() }
        let folder = dir.appendingPathComponent(".nextworkzone")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("JIRA_PAT=sample\nWIKI_PAT=another".utf8).write(to: folder.appendingPathComponent("tokens.env"))
        #expect(try await settings.importTokensEnv() == [.jira, .confluence])
    }

    @Test func connectionProbeUsesReadOnlyRequestsAndSeparateTokens() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = OfflineTransport([
            .response(200, #"{"name":"example-user","displayName":"张三"}"#), .response(200, #"{"version":"1.0"}"#),
            .response(200, #"{"type":"known","username":"wiki-user","displayName":"李四"}"#), .response(200, "<manifest><version>2.0</version></manifest>"),
            .response(200, #"{"username":"git-user","name":"张三"}"#), .response(200, #"{"version":"3.0"}"#)
        ])
        let settings = try service(dir, transport: transport)
        _ = try await settings.saveSettings(.init(baseUrls: ["jira": "https://example.com/jira", "confluence": "https://example.com/wiki", "gitlab": "https://example.com/git"], tokens: ["jira": "j-token", "confluence": "w-token", "gitlab": "g-token"]))
        #expect(try await settings.testConnection(.jira).username == "example-user")
        #expect(try await settings.testConnection(.confluence).serverVersion == "2.0")
        #expect(try await settings.testConnection(.gitlab).displayName == "张三")
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests[0].url?.path == "/jira/rest/api/2/myself")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer w-token")
        #expect(requests[4].value(forHTTPHeaderField: "PRIVATE-TOKEN") == "g-token")
    }

    @Test func anonymousWikiIsRejectedAndVersionIsOptional() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = OfflineTransport([.response(200, #"{"type":"anonymous"}"#), .response(200, #"{"type":"known","username":"example-user","displayName":"张三"}"#), .response(404, "missing")])
        let settings = try service(dir, transport: transport)
        _ = try await settings.saveSettings(.init(baseUrls: ["confluence": "wiki.example.com"], tokens: ["confluence": "sample"]))
        await #expect(throws: NWZError.unauthorized(401)) { try await settings.testConnection(.confluence) }
        #expect(try await settings.testConnection(.confluence).serverVersion == nil)
    }
}

struct ReadOnlyCommandTests {
    @Test func rejectsWritesUnknownCommandsAndCredentials() {
        for command in ["save_settings", "clear_token", "import_tokens_env", "jira_transition", "jira_add_comment", "jira_upload_attachments", "wiki_save", "wiki_create", "wiki_set_task", "weekly_save", "weekly_create_week", "gl_mr_merge", "gl_mr_approve", "gl_mr_add_note", "ws_publish_to_wiki", "clip_paste", "web_login_info", "web_login_finish", "web_logout", "future_command"] {
            #expect(!ReadOnlyCommands.names.contains(command))
        }
        #expect(ReadOnlyCommands.names.contains("get_settings"))
        #expect(ReadOnlyCommands.names.contains("wiki_page"))
    }
}
