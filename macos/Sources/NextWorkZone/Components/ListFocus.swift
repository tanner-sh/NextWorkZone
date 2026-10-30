import AppKit

/// 点击列表的行时让列表获得键盘焦点。
///
/// SwiftUI 的列表处理了点击选中，却没有让列表成为第一响应者（选中行是灰色而不是强调色）：
/// 方向键不能移动选中项，⌘C、⌫ 等交给列表的命令（onCopyCommand、onDeleteCommand）也不可用。
/// 点击之后，如果焦点没有落到行中的输入框等控件上，就交给所在的列表。
@MainActor
enum ListClickFocus {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = event.window, let root = window.contentView?.superview,
               let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) {
                var view: NSView? = hit
                while let v = view, !(v is NSTableView) { view = v.superview }
                if let table = view as? NSTableView {
                    // 等 SwiftUI 处理完这次点击（选中、按钮、开始编辑）再看焦点在哪里
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { focus(table, in: window) }
                    }
                }
            }
            return event
        }
    }

    private static func focus(_ table: NSTableView, in window: NSWindow) {
        guard table.window === window, !table.isHiddenOrHasHiddenAncestor else { return }
        // 已经在列表或行中的控件上（例如点进了行里的输入框）
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: table) { return }
        window.makeFirstResponder(table)
    }
}
