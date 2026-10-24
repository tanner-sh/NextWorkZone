import Foundation
import SQLite3

/// 从 Tauri 版沿用界面偏好：Tauri 版存在网页的 localStorage 中（常用查询、收藏、列表显示方式等），
/// 首次启动时读出 `nextworkzone.*` 的值写入 UserDefaults。已有的值不覆盖，只做一次。
enum PrefsMigration {
    private static let doneKey = "nextworkzone.migratedFromWebStorage"

    /// 值的写法：网页中都是文字，这里按读取的地方需要的类型转换。
    private enum Kind {
        case string
        case int
        case stringArray
        case intArray
        /// JSON 原样存为 Data（用 Codable 读取）
        case json
    }

    private static let keys: [String: Kind] = [
        "nextworkzone.lastPage": .string,
        "nextworkzone.lastTool": .string,
        "nextworkzone.wiki.tab": .string,
        "nextworkzone.wiki.lastPage": .string,
        "nextworkzone.gitlab.mode": .string,
        "nextworkzone.gitlab.mrScope": .string,
        "nextworkzone.jira.searchSource": .string,
        "nextworkzone.jira.editorMode": .string,
        "nextworkzone.capture.mode": .string,
        "nextworkzone.gitlab.lastProject": .int,
        "nextworkzone.kb.expanded": .stringArray,
        "nextworkzone.activity.notify": .stringArray,
        "nextworkzone.gitlab.starred": .intArray,
        "nextworkzone.jira.savedQueries": .json,
        "nextworkzone.jira.view": .json,
        "nextworkzone.wiki.favorites": .json,
    ]

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let items = readWebStorage() else { return }
        for (key, value) in items {
            if key.hasPrefix("nextworkzone.weekly.") {
                // 周报未保存的编辑内容：格式相同
                if defaults.object(forKey: key) == nil { defaults.set(Data(value.utf8), forKey: key) }
                continue
            }
            if key == "nextworkzone.jira.lastCreate" {
                if defaults.object(forKey: key) == nil, let obj = json(value) as? [String: Any] {
                    defaults.set(obj.compactMapValues { $0 as? String }, forKey: key)
                }
                continue
            }
            if key == "nextworkzone.jira.remindedToday" {
                // 今天已经通知过的问题，避免切换后同一天再通知一遍
                if let obj = json(value) as? [String: Any], let day = obj["day"] as? String {
                    defaults.set(day, forKey: key + ".day")
                    defaults.set(obj["keys"] as? [String] ?? [], forKey: key + ".keys")
                }
                continue
            }
            guard let kind = keys[key], defaults.object(forKey: key) == nil else { continue }
            switch kind {
            case .string:
                defaults.set(value, forKey: key)
            case .int:
                if let n = Int(value) { defaults.set(n, forKey: key) }
            case .stringArray:
                if let list = json(value) as? [String] { defaults.set(list, forKey: key) }
            case .intArray:
                if let list = json(value) as? [Int] { defaults.set(list, forKey: key) }
            case .json:
                if json(value) != nil { defaults.set(Data(value.utf8), forKey: key) }
            }
        }
    }

    private static func json(_ s: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
    }

    /// Tauri 版网页的 localStorage（WebKit 按来源各存一个库，取含有本应用数据最多的那个）。
    private static func readWebStorage() -> [String: String]? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/com.nextworkzone.desktop/WebsiteData/Default")
        guard let origins = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        var best: [String: String] = [:]
        for origin in origins {
            guard let inner = try? fm.contentsOfDirectory(at: origin, includingPropertiesForKeys: nil) else { continue }
            for dir in inner {
                let db = dir.appendingPathComponent("LocalStorage/localstorage.sqlite3")
                guard fm.fileExists(atPath: db.path), let items = read(db), items.count > best.count else { continue }
                best = items
            }
        }
        return best.isEmpty ? nil : best
    }

    /// 读取一个 localStorage 库中 `nextworkzone.` 开头的项。库可能正被 Tauri 版使用（WAL 模式），先复制再读。
    private static func read(_ db: URL) -> [String: String]? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("nwz-webstorage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: db.path + suffix)
                if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: tmp.appendingPathComponent("localstorage.sqlite3" + suffix)) }
            }
        } catch {
            return nil
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent("localstorage.sqlite3").path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT key, value FROM ItemTable WHERE key LIKE 'nextworkzone.%'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let k = sqlite3_column_text(stmt, 0), let blob = sqlite3_column_blob(stmt, 1) else { continue }
            // 值是 UTF-16（小端）
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
            if let value = String(data: data, encoding: .utf16LittleEndian) { out[String(cString: k)] = value }
        }
        return out
    }
}
