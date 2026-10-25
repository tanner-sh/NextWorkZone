import Foundation
import Synchronization

/// 收藏、页面状态和未提交的草稿也随数据目录隔离，不能再从旧版 UserDefaults 读入。
public final class PreferencesStore: Sendable {
    private let path: URL
    private let values: Mutex<[String: Data]>
    public init(path: URL) {
        self.path = path
        let loaded = (try? Data(contentsOf: path)).flatMap { try? PropertyListDecoder().decode([String: Data].self, from: $0) } ?? [:]
        values = Mutex(loaded)
    }
    public func object(forKey key: String) -> Any? {
        guard let data = values.withLock({ $0[key] }),
              let wrapper = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return wrapper["value"]
    }
    public func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    public func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    public func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    public func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    public func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    public func set(_ value: Any?, forKey key: String) {
        let encoded = value.flatMap { try? PropertyListSerialization.data(fromPropertyList: ["value": $0], format: .binary, options: 0) }
        values.withLock { values in
            values[key] = encoded
            if let data = try? PropertyListEncoder().encode(values) { try? PrivateFile.write(data, to: path) }
        }
    }
    public func removeObject(forKey key: String) { set(nil, forKey: key) }
}
