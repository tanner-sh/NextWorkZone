import Darwin
import Foundation
import Security

public enum Secret: Sendable {
    case token, webUsername, webPassword
    public func key(for service: Service) -> String {
        let suffix = switch self { case .token: ""; case .webUsername: "-username"; case .webPassword: "-password" }
        return service.rawValue + suffix
    }
}

/// 正式版只访问这一个条目；开发版不会触碰钥匙串或任何旧版条目。
public enum CredentialsStore: Sendable, Equatable {
    case keychain, file(URL)
    public static let service = "NextWorkZone"
    public static let account = "credentials"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    public func load() throws -> [String: String] {
        let data: Data
        switch self {
        case .file(let url):
            do { data = try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { return [:] }
        case .keychain:
            var query = query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return [:] }
            guard status == errSecSuccess, let value = result as? Data else { throw NWZError.keychain(status) }
            data = value
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    public func save(_ values: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values)
        switch self {
        case .file(let url): try PrivateFile.write(data, to: url)
        case .keychain:
            let attributes = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw NWZError.keychain(status) }
        }
    }
}

public enum PrivateFile {
    /// 在同一目录以 0600 创建临时文件后原子替换，避免崩溃截断或短暂暴露凭据。
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

public func parseTokensEnv(_ content: String) -> [Service: String] {
    var result: [Service: String] = [:]
    for line in content.split(separator: "\n") {
        let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { continue }
        let key = pair[0].trimmingCharacters(in: .whitespaces)
        let value = pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let service: Service? = switch key { case "JIRA_PAT": .jira; case "WIKI_PAT", "CONFLUENCE_PAT": .confluence; case "GITLAB_PAT": .gitlab; default: nil }
        if let service, !value.isEmpty { result[service] = value }
    }
    return result
}
