import Foundation

// 缺少字段时保留默认值，允许不同版本逐步增加设置。
public struct AppConfig: Codable, Hashable, Sendable {
    public var proxy: String? = nil
    public var jira: Endpoint = .init()
    public var confluence: Endpoint = .init()
    public var gitlab: Endpoint = .init()
    public var weekly: WeeklyConfig = .init()
    public var workspace: WorkspaceConfig = .init()
    public var jiraTools: JiraToolsConfig = .init()
    public var wikiTools: WikiToolsConfig = .init()
    public var tools: ToolsConfig = .init()

    public init() {}

    private enum CodingKeys: String, CodingKey { case proxy, jira, confluence, gitlab, weekly, workspace, jiraTools, wikiTools, tools }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proxy = try c.decodeIfPresent(String.self, forKey: .proxy)
        jira = try c.decodeIfPresent(Endpoint.self, forKey: .jira) ?? .init()
        confluence = try c.decodeIfPresent(Endpoint.self, forKey: .confluence) ?? .init()
        gitlab = try c.decodeIfPresent(Endpoint.self, forKey: .gitlab) ?? .init()
        weekly = try c.decodeIfPresent(WeeklyConfig.self, forKey: .weekly) ?? .init()
        workspace = try c.decodeIfPresent(WorkspaceConfig.self, forKey: .workspace) ?? .init()
        jiraTools = try c.decodeIfPresent(JiraToolsConfig.self, forKey: .jiraTools) ?? .init()
        wikiTools = try c.decodeIfPresent(WikiToolsConfig.self, forKey: .wikiTools) ?? .init()
        tools = try c.decodeIfPresent(ToolsConfig.self, forKey: .tools) ?? .init()
    }
}

public struct Endpoint: Codable, Hashable, Sendable {
    public var baseUrl: String = ""

    public init() {}

    private enum CodingKeys: String, CodingKey { case baseUrl }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
    }
}

public struct WeeklyConfig: Codable, Hashable, Sendable {
    public var pageId: String = ""
    public var personName: String = ""

    public init() {}

    private enum CodingKeys: String, CodingKey { case pageId, personName }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageId = try c.decodeIfPresent(String.self, forKey: .pageId) ?? ""
        personName = try c.decodeIfPresent(String.self, forKey: .personName) ?? ""
    }
}

public struct WorkspaceConfig: Codable, Hashable, Sendable {
    public var syncDir: String = ""
    public var jiraTodos: Bool = true
    public var captureShortcut: String = "Alt+Space"

    public init() {}

    private enum CodingKeys: String, CodingKey { case syncDir, jiraTodos, captureShortcut }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        syncDir = try c.decodeIfPresent(String.self, forKey: .syncDir) ?? ""
        jiraTodos = try c.decodeIfPresent(Bool.self, forKey: .jiraTodos) ?? true
        captureShortcut = try c.decodeIfPresent(String.self, forKey: .captureShortcut) ?? "Alt+Space"
    }
}

public struct JiraToolsConfig: Codable, Hashable, Sendable {
    public var indexEnabled: Bool = true
    public var indexJql: String = ""
    public var indexDays: UInt32 = 730
    public var dueField: String = ""
    public var dueSoonDays: UInt32 = 2
    public var staleDays: UInt32 = 7
    public var remind: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case indexEnabled, indexJql, indexDays, dueField, dueSoonDays, staleDays, remind }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        indexEnabled = try c.decodeIfPresent(Bool.self, forKey: .indexEnabled) ?? true
        indexJql = try c.decodeIfPresent(String.self, forKey: .indexJql) ?? ""
        indexDays = try c.decodeIfPresent(UInt32.self, forKey: .indexDays) ?? 730
        dueField = try c.decodeIfPresent(String.self, forKey: .dueField) ?? ""
        dueSoonDays = try c.decodeIfPresent(UInt32.self, forKey: .dueSoonDays) ?? 2
        staleDays = try c.decodeIfPresent(UInt32.self, forKey: .staleDays) ?? 7
        remind = try c.decodeIfPresent(Bool.self, forKey: .remind) ?? true
    }
}

public struct WikiToolsConfig: Codable, Hashable, Sendable {
    public var indexEnabled: Bool = true
    public var indexSpaces: [String] = []
    public var taskTodos: Bool = true
    public var activity: Bool = true
    public var mutedPages: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case indexEnabled, indexSpaces, taskTodos, activity, mutedPages }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        indexEnabled = try c.decodeIfPresent(Bool.self, forKey: .indexEnabled) ?? true
        indexSpaces = try c.decodeIfPresent([String].self, forKey: .indexSpaces) ?? []
        taskTodos = try c.decodeIfPresent(Bool.self, forKey: .taskTodos) ?? true
        activity = try c.decodeIfPresent(Bool.self, forKey: .activity) ?? true
        mutedPages = try c.decodeIfPresent([String].self, forKey: .mutedPages) ?? []
    }
}

public struct ToolsConfig: Codable, Hashable, Sendable {
    public var hidden: [String] = []
    public var clipboard: ClipboardConfig = .init()

    public init() {}

    private enum CodingKeys: String, CodingKey { case hidden, clipboard }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        clipboard = try c.decodeIfPresent(ClipboardConfig.self, forKey: .clipboard) ?? .init()
    }
}

public struct ClipboardConfig: Codable, Hashable, Sendable {
    public var enabled: Bool = true
    public var shortcut: String = "CommandOrControl+Alt+V"
    public var autoPaste: Bool = true
    public var plainText: Bool = false
    public var keepDays: UInt32 = 30
    public var maxItems: UInt32 = 5000
    public var saveImages: Bool = true
    public var maxImageMb: UInt32 = 50
    public var skipSecrets: Bool = true
    public var ignoredApps: [IgnoredApp] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, shortcut, autoPaste, plainText, keepDays, maxItems, saveImages, maxImageMb, skipSecrets, ignoredApps }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut) ?? "CommandOrControl+Alt+V"
        autoPaste = try c.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
        plainText = try c.decodeIfPresent(Bool.self, forKey: .plainText) ?? false
        keepDays = try c.decodeIfPresent(UInt32.self, forKey: .keepDays) ?? 30
        maxItems = try c.decodeIfPresent(UInt32.self, forKey: .maxItems) ?? 5000
        saveImages = try c.decodeIfPresent(Bool.self, forKey: .saveImages) ?? true
        maxImageMb = try c.decodeIfPresent(UInt32.self, forKey: .maxImageMb) ?? 50
        skipSecrets = try c.decodeIfPresent(Bool.self, forKey: .skipSecrets) ?? true
        ignoredApps = try c.decodeIfPresent([IgnoredApp].self, forKey: .ignoredApps) ?? []
    }
}

public struct IgnoredApp: Codable, Hashable, Sendable, Identifiable {
    public var id: String = ""
    public var name: String = ""

    public init() {}
    public init(id: String, name: String) { self.id = id; self.name = name }

    private enum CodingKeys: String, CodingKey { case id, name }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

extension AppConfig {
    public static func load(from url: URL) throws -> AppConfig {
        do { return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return AppConfig() }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public subscript(service: Service) -> Endpoint {
        get { switch service { case .jira: jira; case .confluence: confluence; case .gitlab: gitlab } }
        set { switch service { case .jira: jira = newValue; case .confluence: confluence = newValue; case .gitlab: gitlab = newValue } }
    }

    public func baseURL(for service: Service) throws -> String {
        let value = self[service].baseUrl
        guard !value.isEmpty else { throw NWZError.notConfigured(service) }
        return value
    }
}

public func parsePageID(_ input: String) -> String? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    func digits(_ text: String) -> Bool { !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) } }
    if digits(text) { return text }
    guard let url = URLComponents(string: text), url.host != nil else { return nil }
    if let id = url.queryItems?.first(where: { $0.name == "pageId" })?.value { return id }
    let parts = url.path.split(separator: "/").map(String.init)
    for (first, second) in zip(parts, parts.dropFirst()) where first == "pages" && digits(second) { return second }
    return nil
}

public func normalizeBaseURL(_ input: String) throws -> String {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.isEmpty { return "" }
    let text = input.contains("://") ? input : "https://" + input
    guard var url = URLComponents(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty, !host.contains(where: \.isWhitespace), url.user == nil, url.password == nil,
          url.port.map({ (1...65535).contains($0) }) ?? true else { throw NWZError.invalidURL(input) }
    let markers: Set<String> = ["secure", "browse", "projects", "issues", "login.jsp", "pages", "display", "spaces", "login.action", "index.action", "dashboard", "users", "-", "explore"]
    var context: [String] = []
    for part in url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
        if part.isEmpty || markers.contains(String(part)) { break }
        context.append(String(part))
    }
    url.scheme = url.scheme?.lowercased()
    url.host = host.lowercased()
    if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
    url.percentEncodedPath = context.isEmpty ? "" : "/" + context.joined(separator: "/")
    url.query = nil; url.fragment = nil
    guard let value = url.string else { throw NWZError.invalidURL(input) }
    return value
}
