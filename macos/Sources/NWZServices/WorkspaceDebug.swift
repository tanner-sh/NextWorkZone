import Foundation
import NWZCore

extension WorkspaceService {
    public static let readOnlyCommands: Set<String> = ["ws_todos", "ws_docs", "ws_doc", "ws_full_docs", "ws_daily", "ws_daily_days", "ws_tags", "ws_backlinks", "ws_search", "ws_settings", "ws_inbox", "ws_worklog", "tools_hidden"]

    /// 调试通道保留只读 JSON 边界，界面使用类型化服务。
    public func readOnly(_ command: String, arguments: [String: JSONValue]) async throws -> Data {
        func string(_ key: String) throws -> String {
            guard let value = arguments[key]?.string else { throw NWZError.other("缺少参数：\(key)") }
            return value
        }
        let encoder = JSONEncoder()
        switch command {
        case "ws_todos": return try encoder.encode(await store.todos())
        case "ws_docs": return try encoder.encode(await store.docs(kind: string("kind")))
        case "ws_doc": return try encoder.encode(await doc(string("id")))
        case "ws_full_docs": return try encoder.encode(await store.fullDocs(kind: string("kind")))
        case "ws_daily": return try encoder.encode(await store.daily(string("day")))
        case "ws_daily_days": return try encoder.encode(await store.dailyDays())
        case "ws_tags": return try encoder.encode(await store.tags())
        case "ws_backlinks": return try encoder.encode(await store.backlinks(system: string("system"), key: string("key")))
        case "ws_search": return try encoder.encode(await store.search(string("query")))
        case "ws_settings": return try encoder.encode(getSettings())
        case "ws_inbox": return try encoder.encode(await inbox())
        case "ws_worklog": return try encoder.encode(await worklog(string("day")))
        case "tools_hidden": return try encoder.encode(toolsHidden())
        default: throw NWZError.other("此调试命令不允许执行")
        }
    }
}
