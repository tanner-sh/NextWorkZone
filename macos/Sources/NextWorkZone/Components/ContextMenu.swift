import AppKit
import SwiftUI

/// 菜单项：右键菜单、“更多”按钮的菜单都用它描述，由 AppKit 的 NSMenu 显示。
/// 需要先查询才能列出的子菜单（例如可用的流转）在打开时显示“加载中”，查到后在打开的菜单中直接替换。
indirect enum MenuSpec {
    case item(String, icon: String? = nil, checked: Bool = false, disabled: Bool = false, destructive: Bool = false, confirm: String? = nil, action: @MainActor () -> Void)
    case submenu(String, icon: String? = nil, children: [MenuSpec])
    case lazy(String, icon: String? = nil, load: @MainActor () async throws -> [MenuSpec])
    /// 不可点击的说明文字
    case label(String)
    case separator

    /// 执行菜单项；需要确认的在菜单关闭后再弹出确认框。
    @MainActor
    static func perform(confirm: String?, _ action: @escaping @MainActor () -> Void) {
        guard let confirm else { return action() }
        // 菜单关闭后再弹出确认框
        Confirm.ask(confirm, then: action)
    }

    static func action(_ title: String, icon: String? = nil, checked: Bool = false, disabled: Bool = false, _ action: @escaping @MainActor () -> Void) -> MenuSpec {
        .item(title, icon: icon, checked: checked, disabled: disabled, action: action)
    }
}

@MainActor
enum MenuBuilder {
    static func menu(_ specs: [MenuSpec]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        fill(menu, specs)
        return menu
    }

    static func fill(_ menu: NSMenu, _ specs: [MenuSpec]) {
        menu.removeAllItems()
        var items: [NSMenuItem] = []
        for spec in specs {
            switch spec {
            case .separator:
                // 不在开头、结尾或连续出现
                if let last = items.last, !last.isSeparatorItem { items.append(.separator()) }
            case .label(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                items.append(item)
            case let .item(title, icon, checked, disabled, _, confirm, action):
                let item = ClosureMenuItem(title: title) { MenuSpec.perform(confirm: confirm, action) }
                item.state = checked ? .on : .off
                item.isEnabled = !disabled
                if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
                items.append(item)
            case let .submenu(title, icon, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
                item.submenu = MenuBuilder.menu(children)
                items.append(item)
            case let .lazy(title, icon, load):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
                let sub = NSMenu()
                sub.autoenablesItems = false
                let loading = NSMenuItem(title: "加载中…", action: nil, keyEquivalent: "")
                loading.isEnabled = false
                sub.addItem(loading)
                let loader = LazyLoader(load: load)
                sub.delegate = loader
                objc_setAssociatedObject(sub, &LazyLoader.key, loader, .OBJC_ASSOCIATION_RETAIN)
                item.submenu = sub
                items.append(item)
            }
        }
        while items.last?.isSeparatorItem == true { items.removeLast() }
        for item in items { menu.addItem(item) }
    }

    /// 在鼠标位置弹出菜单。
    static func popUp(_ specs: [MenuSpec], in view: NSView? = nil) {
        let menu = menu(specs)
        if let view, let window = view.window {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            menu.popUp(positioning: nil, at: point, in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// 打开时才加载的子菜单。
    private final class LazyLoader: NSObject, NSMenuDelegate {
        nonisolated(unsafe) static var key = 0
        let load: @MainActor () async throws -> [MenuSpec]
        private var started = false

        init(load: @escaping @MainActor () async throws -> [MenuSpec]) {
            self.load = load
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard !started else { return }
            started = true
            Task { @MainActor in
                do {
                    let specs = try await load()
                    MenuBuilder.fill(menu, specs.isEmpty ? [.label("没有可用的项")] : specs)
                } catch {
                    guard !isCancellation(error) else { return }
                    MenuBuilder.fill(menu, [.label("加载失败：\(errorMessage(error))")])
                    started = false
                }
            }
        }
    }
}

/// 需要确认的操作：确认框从当前窗口（或其中打开的表单）顶部滑出，只挡住这个窗口，不阻塞整个应用。
@MainActor
enum Confirm {
    static func ask(_ message: String, confirm: String = "确定", destructive: Bool = true) async -> Bool {
        let alert = NSAlert()
        // 旧的“再点一次确认…”提示改为确认框的标题
        alert.messageText = message.replacingOccurrences(of: "再点一次确认", with: "确认")
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        // 已经有表单时附着在最上层的表单上
        var window = NSApp.keyWindow ?? MainWindow.window
        while let sheet = window?.attachedSheet { window = sheet }
        guard let window, window.isVisible else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// 确认后执行。
    static func ask(_ message: String, confirm: String = "确定", destructive: Bool = true, then action: @escaping @MainActor () -> Void) {
        Task { if await ask(message, confirm: confirm, destructive: destructive) { action() } }
    }
}

// MARK: - SwiftUI 接入

/// 右键时显示原生菜单（菜单内容在右键时才生成）。
private struct NativeContextMenu: NSViewRepresentable {
    var specs: () -> [MenuSpec]
    var onOpen: (() -> Void)?

    func makeNSView(context: Context) -> MenuView {
        let view = MenuView()
        view.specs = specs
        view.onOpen = onOpen
        return view
    }

    func updateNSView(_ view: MenuView, context: Context) {
        view.specs = specs
        view.onOpen = onOpen
    }

    final class MenuView: NSView {
        var specs: (() -> [MenuSpec])?
        var onOpen: (() -> Void)?

        /// 查找右键位置下面的内容时为真：这期间所有菜单层都不拦截点击。
        private static var passthrough = false

        /// 只接收右键（和按住 Control 的点击），其余事件交给下面的 SwiftUI 内容。
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !Self.passthrough, let event = NSApp.currentEvent else { return nil }
            let isRight = event.type == .rightMouseDown || event.type == .rightMouseUp || ((event.type == .leftMouseDown || event.type == .leftMouseUp) && event.modifierFlags.contains(.control))
            return isRight ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let specs else { return nil }
            onOpen?()
            return MenuBuilder.menu(Self.contentSpecs(event) + specs())
        }

        /// 右键位置在富文本上时，先列出选中的文字、链接、图片等的操作（见 RichContextMenu），再接这一层自己的菜单。
        private static func contentSpecs(_ event: NSEvent) -> [MenuSpec] {
            guard let content = event.window?.contentView else { return [] }
            passthrough = true
            defer { passthrough = false }
            var view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
            while let v = view, !(v is RichNSTextView) { view = v.superview }
            guard let textView = view as? RichNSTextView else { return [] }
            let specs = RichContextMenu.specs(textView, at: textView.convert(event.locationInWindow, from: nil), service: textView.service)
            return specs.isEmpty ? [] : specs + [.separator]
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = menu(for: event) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) } else { super.mouseDown(with: event) }
        }
    }
}

extension View {
    /// 右键菜单（原生 NSMenu，可以包含打开时才加载的子菜单）。
    func contextMenu(specs: @escaping () -> [MenuSpec], onOpen: (() -> Void)? = nil) -> some View {
        overlay(NativeContextMenu(specs: specs, onOpen: onOpen))
    }
}

/// 点击后弹出菜单的按钮（例如“更多”）。
struct MenuButton<Label: View>: View {
    var specs: () -> [MenuSpec]
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            MenuBuilder.popUp(specs())
        } label: {
            label()
        }
    }
}
