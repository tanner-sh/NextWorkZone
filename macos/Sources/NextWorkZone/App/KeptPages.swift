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
    /// 各页面第几次显示
    var visits: [PageID: Int]
    /// 页面内容（只创建一次）；第二个参数为页面的显示状态，之后切换页面只改它
    var content: (PageID, PageState) -> AnyView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let c = context.coordinator
        for page in pages {
            let isActive = page == active
            if let host = c.hosts[page], let state = c.states[page] {
                // 只改显示状态，不替换 rootView：替换会让这个页面整体重新比较一遍
                if state.active != isActive { state.active = isActive }
                if let visit = visits[page], state.visit != visit { state.visit = visit }
                if !isActive, let responder = container.window?.firstResponder as? NSView, responder.isDescendant(of: host) {
                    // 隐藏的页面中的输入框不应继续接收键盘输入
                    container.window?.makeFirstResponder(nil)
                }
                Self.track(host, in: container, active: isActive)
            } else {
                let state = PageState(active: isActive, visit: visits[page] ?? 0)
                let host = PageHost(rootView: content(page, state))
                container.addSubview(host)
                Self.track(host, in: container, active: isActive)
                c.hosts[page] = host
                c.states[page] = state
            }
        }
    }

    /// 只有显示的页面跟随窗口大小。隐藏的页面也跟着缩放的话，拖动窗口边框时每一帧都要重新排版所有打开过的页面
    /// （打开过长 Wiki 页面后尤其卡）；隐藏的页面保持原来的大小，再显示时调整一次。
    private static func track(_ host: NSView, in container: NSView, active: Bool) {
        host.autoresizingMask = active ? [.width, .height] : []
        if active && host.frame != container.bounds { host.frame = container.bounds }
        host.isHidden = !active
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 页面的宿主视图。窗口每次重新计算标题栏的可拖动区域（切换页面、工具栏变化时）都会问各个宿主视图能否获得焦点，
    /// SwiftUI 为了回答要把整个页面的可聚焦控件遍历一遍；隐藏的页面也被遍历的话，打开过的页面越多切换越慢。
    /// 隐藏的页面本来就不该获得焦点，直接回答不能。
    final class PageHost: NSHostingView<AnyView> {
        override var acceptsFirstResponder: Bool { isHidden ? false : super.acceptsFirstResponder }
        #if DEBUG
        override func layout() {
            super.layout()
            if !isHidden { DevBridge.pageLaidOut() }
        }
        #endif
    }

    final class Coordinator {
        var hosts: [PageID: PageHost] = [:]
        var states: [PageID: PageState] = [:]
    }
}
