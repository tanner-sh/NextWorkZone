import NWZCore

public struct ServiceSettings: Codable, Hashable, Sendable {
    public var service: Service
    public var label: String
    public var baseUrl: String
    public var hasToken: Bool
    public var supportsWebLogin: Bool
    public var webUsername: String
    public var hasWebPassword: Bool
}

public struct Settings: Codable, Hashable, Sendable {
    public var proxy: String
    public var services: [ServiceSettings]
    public var weeklyPageId: String
    public var weeklyPersonName: String
}

public struct WebAccountInput: Codable, Hashable, Sendable {
    public var username: String
    public var password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}

public struct SettingsInput: Codable, Sendable {
    public var proxy: String
    public var baseUrls: [String: String]
    public var tokens: [String: String]
    public var weeklyPage: String
    public var weeklyPersonName: String
    public var webAccounts: [String: WebAccountInput]
    public init(proxy: String = "", baseUrls: [String: String] = [:], tokens: [String: String] = [:], weeklyPage: String = "", weeklyPersonName: String = "", webAccounts: [String: WebAccountInput] = [:]) {
        self.proxy = proxy; self.baseUrls = baseUrls; self.tokens = tokens; self.weeklyPage = weeklyPage
        self.weeklyPersonName = weeklyPersonName; self.webAccounts = webAccounts
    }
}
