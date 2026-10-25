import Foundation
import NWZCore

/// 过渡桥只推送当前 Swift 状态，不允许 Rust 读取旧配置或凭据。
public protocol LegacySettingsBridge: Sendable {
    func setConfiguration(_ config: AppConfig) throws
    func setSecrets(_ secrets: [String: String]) throws
}

public actor SettingsService {
    public nonisolated let paths: AppPaths
    public nonisolated let configuration: ConfigurationStore
    private let store: CredentialsStore
    private var credentials: [String: String]
    private let bridge: (any LegacySettingsBridge)?
    private let injectedClient: HTTPClient?

    public init(paths: AppPaths, configuration: ConfigurationStore, bridge: (any LegacySettingsBridge)? = nil, client: HTTPClient? = nil) throws {
        self.paths = paths; self.configuration = configuration; self.bridge = bridge; injectedClient = client
        store = paths.credentialsStore
        credentials = try store.load()
        try bridge?.setConfiguration(configuration.snapshot())
        try bridge?.setSecrets(credentials)
    }

    public func updateConfiguration(_ change: @Sendable (inout AppConfig) throws -> Void) throws {
        try configuration.update(change)
        try bridge?.setConfiguration(configuration.snapshot())
    }

    public func getSettings() -> Settings {
        let config = configuration.snapshot()
        return Settings(proxy: config.proxy ?? "", services: Service.allCases.map { service in
            ServiceSettings(service: service, label: service.label, baseUrl: config[service].baseUrl,
                            hasToken: credentials[Secret.token.key(for: service)] != nil,
                            supportsWebLogin: service.supportsWebLogin,
                            webUsername: credentials[Secret.webUsername.key(for: service)] ?? "",
                            hasWebPassword: credentials[Secret.webPassword.key(for: service)] != nil)
        }, weeklyPageId: config.weekly.pageId, weeklyPersonName: config.weekly.personName)
    }

    public func saveSettings(_ input: SettingsInput) throws -> Settings {
        var next = configuration.snapshot()
        let proxy = input.proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        next.proxy = proxy.isEmpty ? nil : proxy
        _ = try SessionTransport.configuration(proxy: next.proxy)
        for (name, url) in input.baseUrls {
            guard let service = Service(rawValue: name) else { throw NWZError.other("未知系统：\(name)") }
            next[service].baseUrl = try normalizeBaseURL(url)
        }
        let page = input.weeklyPage.trimmingCharacters(in: .whitespacesAndNewlines)
        if page.isEmpty { next.weekly.pageId = "" }
        else if let id = parsePageID(page) { next.weekly.pageId = id }
        else { throw NWZError.invalidURL(page) }
        next.weekly.personName = input.weeklyPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        var secrets = credentials
        for (name, input) in input.tokens {
            guard let service = Service(rawValue: name) else { throw NWZError.other("未知系统：\(name)") }
            let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { secrets[Secret.token.key(for: service)] = token }
        }
        for (name, account) in input.webAccounts {
            guard let service = Service(rawValue: name), service.supportsWebLogin else { continue }
            let username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if username.isEmpty {
                secrets.removeValue(forKey: Secret.webUsername.key(for: service))
                secrets.removeValue(forKey: Secret.webPassword.key(for: service))
            } else {
                secrets[Secret.webUsername.key(for: service)] = username
                if !account.password.isEmpty { secrets[Secret.webPassword.key(for: service)] = account.password }
            }
        }
        if secrets != credentials { try store.save(secrets) }
        do { try configuration.replace(next) }
        catch {
            if secrets != credentials { try? store.save(credentials) }
            throw error
        }
        credentials = secrets
        try bridge?.setConfiguration(next)
        try bridge?.setSecrets(secrets)
        return getSettings()
    }

    public func clearToken(_ service: Service) throws -> Settings {
        var next = credentials
        next.removeValue(forKey: Secret.token.key(for: service))
        try store.save(next)
        credentials = next
        try bridge?.setSecrets(next)
        return getSettings()
    }

    public func importTokensEnv() throws -> [Service] {
        let file = paths.home.appendingPathComponent(".nextworkzone/tokens.env")
        let text: String
        do { text = try String(contentsOf: file, encoding: .utf8) }
        catch CocoaError.fileReadNoSuchFile { throw NWZError.other("未找到 ~/.nextworkzone/tokens.env，请在设置中手动填写令牌") }
        let tokens = parseTokensEnv(text)
        var next = credentials
        for (service, token) in tokens { next[Secret.token.key(for: service)] = token }
        if next != credentials { try store.save(next) }
        credentials = next
        try bridge?.setSecrets(next)
        return Service.allCases.filter { tokens[$0] != nil }
    }

    public func testConnection(_ service: Service) async throws -> ConnectionInfo {
        let config = configuration.snapshot()
        let base = try config.baseURL(for: service)
        guard let token = credentials[Secret.token.key(for: service)], !token.isEmpty else { throw NWZError.missingToken(service) }
        let client = try injectedClient ?? HTTPClient(proxy: config.proxy)
        return try await ConnectionProbe.check(service, base: base, token: token, client: client)
    }
}
