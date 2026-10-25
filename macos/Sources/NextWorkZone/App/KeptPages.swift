import AppKit
import SwiftUI

/// 切走后保留的页面：每个页面放在自己的 NSHostingView 中，不显示的设为 isHidden。
///
/// 都放在同一个 SwiftUI 视图树中（用 opacity 隐藏）时，每次切换 SwiftUI 都要更新所有保留页面的显示列表，
/// 待办、问题列表、长 Wiki 页面都打开过之后，切换一次要 100 毫秒左右；分开后隐藏的页面不参与布局和绘制，
/// 各页面的视图树也互不影响。
struct KeptPages: NSViewRepresentable {
    var pages: [PageID]
    /// 正在显示的页面（不是保留的页面时，所有保留的页面都隐藏）
    var active: PageID
    /// 页面内容；第二个参数为是否正在显示（页面据此决定是否响应快捷键、接收拖入的文件）
    var content: (PageID, Bool) -> AnyView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let c = context.coordinator
        for page in pages {
            let isActive = page == active
            if let host = c.hosts[page] {
                // 只在显示状态变化时更新内容：替换 rootView 会让这个页面整体重新比较一遍
                if c.shown[page] != isActive { host.rootView = content(page, isActive) }
                if !isActive, let responder = container.window?.firstResponder as? NSView, responder.isDescendant(of: host) {
                    // 隐藏的页面中的输入框不应继续接收键盘输入
                    container.window?.makeFirstResponder(nil)
                }
                host.isHidden = !isActive
            } else {
                let host = NSHostingView(rootView: content(page, isActive))
                host.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    host.topAnchor.constraint(equalTo: container.topAnchor),
                    host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
                host.isHidden = !isActive
                c.hosts[page] = host
            }
            c.shown[page] = isActive
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosts: [PageID: NSHostingView<AnyView>] = [:]
        var shown: [PageID: Bool] = [:]
    }
}
