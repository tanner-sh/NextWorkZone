import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// 应用内拖动的问题、Wiki 页面、合并请求（Info.plist 中声明）。
    static let nwzLink = UTType(exportedAs: "com.nextworkzone.link")
}

/// 可以拖动的问题、Wiki 页面、合并请求。
///
/// 拖进应用内：侧栏的“待办”（加一条关联的待办）、“笔记”（追加到今天的日记）、待办列表、笔记编辑器（插入链接）；
/// 拖到其他应用：网页地址，或“问题键 概要”这样的文字。
struct WorkLink: Codable, Hashable, Transferable {
    enum Kind: String, Codable { case issue, wiki, mr }

    var kind: Kind
    /// 问题键、Wiki 页面 ID、合并请求的引用（项目!编号）
    var key: String
    var title: String
    var url: String

    /// 显示的文字：问题带上问题键
    var label: String { kind == .wiki ? title : "\(key) \(title)" }
    var markdown: String { "[\(label)](\(url))" }

    @MainActor static func issue(_ issue: IssueSummary) -> WorkLink {
        WorkLink(kind: .issue, key: issue.key, title: issue.summary, url: "\(AppModel.shared.baseUrl(.jira))/browse/\(issue.key)")
    }

    @MainActor static func wiki(id: String, title: String) -> WorkLink {
        WorkLink(kind: .wiki, key: id, title: title, url: WikiMenus.pageUrl(id))
    }

    static func mr(_ mr: MergeRequest) -> WorkLink {
        WorkLink(kind: .mr, key: mr.reference.isEmpty ? "!\(mr.iid)" : mr.reference, title: mr.title, url: mr.webUrl)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .nwzLink)
        ProxyRepresentation(exporting: \.webURL)
        ProxyRepresentation(exporting: \.label)
    }

    private var webURL: URL { URL(string: url) ?? URL(string: "about:blank")! }

    /// 从拖动的数据中读出（编辑器等 AppKit 视图接收拖入时用）。
    static func read(_ pasteboard: NSPasteboard) -> WorkLink? {
        pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.nwzLink.identifier)).flatMap { try? JSONDecoder().decode(WorkLink.self, from: $0) }
    }
}

/// 拖进待办、笔记的内容：应用内的链接，或其他应用中的文字（网址也是文字）。
enum DroppedWork: Transferable {
    case link(WorkLink)
    case text(String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (link: WorkLink) in DroppedWork.link(link) })
        ProxyRepresentation(importing: { (text: String) in DroppedWork.text(text) })
    }

    /// 加为待办：问题、Wiki 页面关联到原来的条目（已有它的未完成待办时不再添加，例如分配给我的问题已自动加入）；
    /// 文字的第一行作标题，其余作备注。可撤销。
    @MainActor
    static func addTodos(_ items: [DroppedWork], due: String? = nil) {
        guard !items.isEmpty else { return }
        guarded {
            let open = Set(try await API.shared.wsTodos().filter { !$0.done }.compactMap { t in t.refKey.map { "\(t.refSystem ?? ""):\($0)" } })
            var added = 0, existing = 0
            for item in items {
                var input: TodoInput
                switch item {
                case .link(let l) where l.kind == .issue:
                    input = TodoInput(title: l.title, refSystem: .some("jira"), refKey: .some(l.key), refTitle: .some(l.title))
                case .link(let l) where l.kind == .wiki:
                    input = TodoInput(title: l.title, refSystem: .some("wiki"), refKey: .some(l.key), refTitle: .some(l.title))
                case .link(let l):
                    input = TodoInput(title: l.label, notes: l.url)
                case .text(let text):
                    let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                    guard let first = lines.first, !first.isEmpty else { continue }
                    input = TodoInput(title: first.trimmingCharacters(in: .whitespaces), notes: lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if let key = input.refKey ?? nil, open.contains("\((input.refSystem ?? nil) ?? ""):\(key)") {
                    existing += 1
                    continue
                }
                input.due = due
                _ = try await TodoActions.add(input)
                added += 1
            }
            if added > 0 {
                toast((added == 1 ? "已添加待办" : "已添加 \(added) 个待办") + (existing > 0 ? "，\(existing) 个已在待办中" : ""))
            } else if existing > 0 {
                toast("已在待办中")
            }
        }
    }

    /// 追加到今天的日记：链接写成 Markdown 链接。
    @MainActor
    static func appendToDaily(_ items: [DroppedWork]) {
        guard !items.isEmpty else { return }
        guarded {
            for item in items {
                switch item {
                case .link(let l): try await ClipActions.appendToDaily(l.markdown)
                case .text(let text): try await ClipActions.appendToDaily(text)
                }
            }
            toast("已写入今天的日记")
        }
    }
}

/// 拖动的内容停在可以放下的区域上时的提示：虚线框和说明。
struct DropHighlight: View {
    var text: String

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .overlay(Text(text).font(.headline).padding(10).glassEffect())
            .padding(8)
            .allowsHitTesting(false)
    }
}
