import Foundation
import Synchronization
import Testing
@testable import NWZCore

struct CoreTests {
    @Test func uploadProgressCombinesParts() async throws {
        let seen = Mutex<[Double]>([])
        _ = try await UploadProgress.$report.withValue({ value in seen.withLock { $0.append(value) } }) {
            try await UploadProgress.sequence([100, 300]) { _ in
                UploadProgress.report?(0.5)
                UploadProgress.report?(1)
            }
        }
        #expect(seen.withLock { $0 } == [0.125, 0.25, 0.625, 1])
    }

    @Test func stripsUIPagesAndTrailingSlash() throws {
        let cases = [
            ("https://jira.example.com/secure/Dashboard.jspa", "https://jira.example.com"),
            ("https://wiki.example.com/", "https://wiki.example.com"),
            ("https://wiki.example.com/pages/viewpage.action?pageId=1#x", "https://wiki.example.com"),
            ("git.example.com", "https://git.example.com"),
            ("https://git.example.com/users/sign_in", "https://git.example.com"),
            ("https://host:8443/jira/browse/ABC-1", "https://host:8443/jira"), ("", "")
        ]
        for (input, expected) in cases { #expect(try normalizeBaseURL(input) == expected) }
    }

    @Test func parsesPageID() {
        #expect(parsePageID("https://wiki.example.com/pages/viewpage.action?pageId=123#expand-") == "123")
        #expect(parsePageID("https://wiki.example.com/pages/123/Title") == "123")
        #expect(parsePageID(" 42 ") == "42")
        #expect(parsePageID("https://wiki.example.com/display/ABC/Title") == nil)
    }

    @Test func rejectsInvalidURLs() {
        for url in ["ftp://host", "http://", "https://example.com:99999", "https://user:password@example.com"] {
            #expect(throws: NWZError.self) { try normalizeBaseURL(url) }
        }
    }

    @Test func deserializesServiceMapKey() throws {
        let values = try JSONDecoder().decode(ServiceMap<String>.self, from: Data(#"{"jira":"a","confluence":"b","gitlab":"c"}"#.utf8))
        #expect(values[.confluence] == "b")
        #expect(try JSONDecoder().decode(ServiceMap<String>.self, from: JSONEncoder().encode(values)) == values)
    }

    @Test func parsesTokensEnv() {
        let parsed = parseTokensEnv("JIRA_PAT=abc\n# comment\nWIKI_PAT=\"def\"\nGITLAB_PAT=\nOTHER=x\n")
        #expect(parsed == [.jira: "abc", .confluence: "def"])
    }

    @Test func detectsLoginRedirects() throws {
        let base = "https://jira.example.com"
        for address in ["https://jira.example.com/login.jsp?x=1", "https://jira.example.com/plugins/servlet/mfa/authlogin", "https://sso.example.com/idp/start"] {
            #expect(isLoginRedirect(try #require(URL(string: address)), base: base))
        }
        #expect(!isLoginRedirect(try #require(URL(string: base + "/secure/attachment/1/a.png")), base: base))
    }

    @Test func mergesRotatedCookies() {
        let header = "JSESSIONID=old; token=a"
        #expect(mergeSetCookies(header, setCookies: ["JSESSIONID=new; Path=/; HttpOnly", "extra=1; Path=/"]) == "JSESSIONID=new; token=a; extra=1")
        #expect(mergeSetCookies(header, setCookies: ["token=a; Path=/"]) == nil)
        #expect(mergeSetCookies(header, setCookies: []) == nil)
    }

    @Test func partialConfigurationUsesDefaults() throws {
        let value = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"jira":{"baseUrl":"https://jira.example.com"},"workspace":{"syncDir":""},"tools":{"clipboard":{"keepDays":10}},"unknown":true}"#.utf8))
        #expect(value.workspace.jiraTodos)
        #expect(value.workspace.captureShortcut == "Alt+Space")
        #expect(value.jiraTools.indexDays == 730)
        #expect(value.tools.clipboard.enabled)
        #expect(value.tools.clipboard.keepDays == 10)
        #expect(value.tools.clipboard.maxItems == 5000)
        #expect(value.wikiTools.taskTodos)
        #expect(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func pathsSeparateEnvironmentsAndNeverUseLegacyLocations() throws {
        let home = URL(fileURLWithPath: "/tmp/nwz-home")
        let production = AppPaths(home: home, development: false, environment: [:])
        let development = AppPaths(home: home, development: true, environment: [:])
        #expect(production.data.path == "/tmp/nwz-home/Library/Application Support/NextWorkZone")
        #expect(development.cache.path == "/tmp/nwz-home/Library/Caches/NextWorkZone-dev")
        #expect(production.credentialsStore == .keychain)
        #expect(development.credentialsStore == .file(development.data.appendingPathComponent("dev-credentials.json")))
        #if DEBUG
        let isolated = AppPaths(home: home, development: true, environment: ["NWZ_DATA_DIR": "/tmp/nwz-isolated"])
        #expect(isolated.data.path == "/tmp/nwz-isolated")
        #expect(isolated.cache.path == "/tmp/nwz-isolated/cache")
        #endif
        #expect(production.syncRoot(in: URL(fileURLWithPath: "/tmp/shared")).path == "/tmp/shared/NextWorkZone/v2")
    }

    @Test func configAndCredentialsSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json")
        var config = AppConfig()
        config.jira.baseUrl = "https://jira.example.com"
        try config.save(to: path)
        #expect(try AppConfig.load(from: path) == config)
        let file = directory.appendingPathComponent("dev-credentials.json")
        let store = CredentialsStore.file(file)
        try store.save(["jira": "sample-token", "confluence-username": "example-user"])
        #expect(try store.load()["jira"] == "sample-token")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try store.save([:])
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func malformedFilesAreNotSilentlyReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invalid.json")
        try Data("invalid".utf8).write(to: file)
        #expect(throws: (any Error).self) { try AppConfig.load(from: file) }
        #expect(throws: (any Error).self) { try CredentialsStore.file(file).load() }
    }

    @Test func fileCacheHandlesMissingAndCorruptData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileCache(directory: directory)
        #expect(await cache.get("missing", as: [String].self) == nil)
        await cache.put("../unsafe/key", value: ["中文"])
        #expect(await cache.get("../unsafe/key", as: [String].self) == ["中文"])
        #expect(await cache.get("../unsafe/key", as: Int.self) == nil)
    }
}
