import Foundation

public enum Service: String, Codable, CaseIterable, Hashable, Sendable {
    case jira, confluence, gitlab
    public var label: String {
        switch self { case .jira: "Jira"; case .confluence: "Wiki"; case .gitlab: "GitLab" }
    }
    public var supportsWebLogin: Bool { self != .gitlab }
}

public struct ConnectionInfo: Codable, Hashable, Sendable {
    public var service: Service
    public var username: String
    public var displayName: String
    public var serverVersion: String?
    public init(service: Service, username: String, displayName: String, serverVersion: String? = nil) {
        self.service = service; self.username = username; self.displayName = displayName; self.serverVersion = serverVersion
    }
}

/// Codable 默认会把枚举键字典编码成数组；配置与接口需要稳定的字符串键对象。
public struct ServiceMap<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    private var values: [String: Value]
    public init(_ values: [Service: Value] = [:]) { self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }) }
    public subscript(_ service: Service) -> Value? {
        get { values[service.rawValue] }
        set { values[service.rawValue] = newValue }
    }
    public init(from decoder: any Decoder) throws { values = try [String: Value](from: decoder) }
    public func encode(to encoder: any Encoder) throws { try values.encode(to: encoder) }
}

public enum NWZError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured(Service), missingToken(Service), sessionRequired(Service)
    case invalidURL(String), unauthorized(Int), forbidden(String), http(Int, String), conflict(String), other(String)
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let service): "尚未配置 \(service.label) 的地址"
        case .missingToken(let service): "尚未设置 \(service.label) 的 Token"
        case .sessionRequired(let service): "需要先网页登录 \(service.label)，才能访问附件和图片"
        case .invalidURL(let value): "无效的地址：\(value)"
        case .unauthorized(let status): "认证失败（HTTP \(status)），请检查 Token 是否有效或已过期"
        case .forbidden(let body): "没有权限执行此操作：\(body)"
        case .http(let status, let body): "请求失败（HTTP \(status)）：\(body)"
        case .conflict(let message): "内容已被他人修改：\(message)"
        case .keychain(let status): "钥匙串访问失败：\(status)"
        case .other(let message): message
        }
    }
}
