import CryptoKit
import Foundation

public actor FileCache {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func path(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    public func get<T: Decodable & Sendable>(_ key: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: path(key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    public func put<T: Encodable & Sendable>(_ key: String, value: T) {
        // 缓存可重建，写入失败不应阻止用户正在进行的操作。
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: path(key), options: .atomic) }
    }
}
