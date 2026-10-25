import Foundation
import NWZClipboard
import NWZCore

/// 调试通道中可以调用的剪贴板命令（只读）。
extension ClipboardService {
    public static let readOnlyCommands: Set<String> = ["clip_list", "clip_text", "clip_pinboards", "clip_apps", "clip_issues", "clip_settings", "clip_ignore_candidates"]

    public func readOnly(_ command: String, arguments a: [String: JSONValue]) async throws -> Data {
        let encoder = JSONEncoder()
        switch command {
        case "clip_list": return try encoder.encode(await list(a["query"]?.decode(ClipQuery.self) ?? ClipQuery()))
        case "clip_text": return try encoder.encode(await text(a["id"]?.string ?? ""))
        case "clip_pinboards": return try encoder.encode(await pinboards())
        case "clip_apps": return try encoder.encode(await apps())
        case "clip_issues": return try encoder.encode(await issues(a["keys"]?.decode([String].self) ?? []))
        case "clip_settings": return try encoder.encode(await settingsView())
        case "clip_ignore_candidates": return try encoder.encode(await ignoreCandidates())
        default: throw NWZError.other("调试通道只允许读取剪贴板数据")
        }
    }
}
