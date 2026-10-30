import AppKit
import SwiftUI

/// 在新窗口中打开的内容：问题、Wiki 页面、笔记或知识库页面。可以同时开多个窗口，同一内容只开一个。
enum DetailTarget: Codable, Hashable {
    case issue(String)
    case wiki(String)
    case doc(String)
}

@MainActor
enum DetailWindows {
    static let id = "detail"
    static let previewId = "preview"

    static func open(_ target: DetailTarget) {
        NSApp.activate()
        AppModel.shared.openWindowAction?(id: id, value: target)
    }

    /// 右键菜单中的“在新窗口中打开”。
    static func menuItem(_ target: DetailTarget) -> MenuSpec {
        .action("在新窗口中打开", icon: "macwindow.badge.plus") { open(target) }
    }
}

/// 单独窗口中的问题、Wiki 页面或文档。
struct DetailWindow: View {
    var target: DetailTarget?

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var title = ""

    var body: some View {
        Group {
            switch target {
            case .issue(let key):
                IssueView(issueKey: key) { summary in
                    title = "\(summary.key) \(summary.summary)"
                    AppModel.shared.issueChanged()
                }
                .task {
                    // 看过的问题直接用缓存中的概要，否则单独查一次
                    title = key
                    var summary = IssueCache.shared.get(key)?.detail.summary
                    if summary == nil { summary = try? await IssueMenu.fetchSummary(key).summary }
                    if let summary { title = "\(key) \(summary)" }
                }
            case .wiki(let id):
                PageView(pageId: id, anchor: nil, onOpen: { DetailWindows.open(.wiki($0)) }, onLoaded: { title = $0.title }, onEdit: {
                    // 编辑器在主窗口的 Wiki 页面中
                    var t = NavTarget(.wiki, wikiPage: id)
                    t.wikiEdit = true
                    AppModel.shared.navigate(t)
                }, onNewChild: { AppModel.shared.navigate(NavTarget(.wiki, wikiPage: id)) })
            case .doc(let id):
                DocPane(docId: id, onSaved: { title = $0.title.isEmpty ? "无标题" : $0.title }, onDeleted: { dismissWindow() }) { _ in
                    EmptyView()
                } actions: { _ in
                    EmptyView()
                } footer: { doc in
                    if doc.kind == "daily", let day = doc.day { WorkLogPanel(day: day).id(day) }
                }
            case nil:
                Text("内容已不存在").foregroundStyle(.secondary)
            }
        }
        .environment(AppModel.shared)
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(title)
        .overlay { ToastOverlay() }
    }
}

/// 预览窗口的内容：图片、附件（见 ImageViewer、AttachmentViewer）。
@MainActor @Observable
final class PreviewContent {
    static let shared = PreviewContent()
    var title = ""
    var view: AnyView?
    /// 每次显示新内容时递增，让查看器重新创建
    var version = 0

    func show<V: View>(title: String, _ content: V) {
        self.title = title
        view = AnyView(content)
        version += 1
        NSApp.activate()
        AppModel.shared.openWindowAction?(id: DetailWindows.previewId)
    }
}

/// 预览窗口：Esc 关闭，← → 切换附件。
struct PreviewWindowView: View {
    @State private var content = PreviewContent.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let view = content.view { view.id(content.version) } else { Color.clear }
        }
        .environment(AppModel.shared)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .navigationTitle(content.title)
        .overlay { ToastOverlay() }
        // Esc 关闭：查看器里不一定有获得焦点的控件，用带快捷键的隐藏按钮（onExitCommand 需要焦点）
        .background {
            Button("关闭") { dismissWindow() }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false)
        }
        // 关闭后不再占着上一个附件的内容
        .onDisappear { content.view = nil }
    }
}
