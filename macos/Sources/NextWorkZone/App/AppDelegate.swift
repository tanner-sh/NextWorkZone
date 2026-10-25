import AppKit
import SwiftUI
import NWZCore

/// 应用入口：组装业务服务，创建主窗口、菜单、托盘和全局快捷键。
/// 关闭主窗口只是隐藏，应用继续在后台同步、提醒；从托盘或程序坞图标重新打开，⌘Q 或托盘菜单“退出”才退出。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let paths = AppPaths.current()
            API.shared = try API.make(paths: paths)
        } catch {
            let alert = NSAlert()
            alert.messageText = "启动 NextWorkZone 失败"
            alert.informativeText = errorMessage(error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = MainMenu.build()
        AppModel.shared.start()
        MainWindow.create()
        setupTray()
        setupShortcuts()
        MainWindow.show()
        // 剪贴板面板和快速记录窗口创建要 0.2 秒左右：主窗口显示后再创建，不推迟启动
        DispatchQueue.main.async {
            ClipboardPanel.shared.prepare()
            CaptureWindow.shared.prepare()
        }
        #if DEBUG
        DevBridge.start()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspace = API.shared?.workspace
        let jira = API.shared?.jira, wiki = API.shared?.wiki, sessions = API.shared?.sessions
        API.shared?.clipboard.stop()
        Task { await jira?.stop(); await wiki?.stop(); await sessions?.stop(); if let service = try? await workspace?.value { await service.stop() } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 托盘（菜单栏图标）

    private func setupTray() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "tray-template", withExtension: "png"), let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
        } else {
            item.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "NextWorkZone")
        }
        item.button?.toolTip = "NextWorkZone"
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: title, action: action)
            menu.addItem(i)
            return i
        }
        _ = add("打开 NextWorkZone") { MainWindow.show() }
        menu.addItem(.separator())
        _ = add("快速记录…") { CaptureWindow.shared.toggle() }
        _ = add("记一条待办…") {
            MainWindow.show()
            AppModel.shared.quickTodoOpen = true
        }
        _ = add("搜索…") {
            MainWindow.show()
            AppModel.shared.paletteOpen = true
        }
        menu.addItem(.separator())
        _ = add("剪贴板…") { ClipboardPanel.shared.toggle() }
        pauseItem = add("暂停记录剪贴板") { API.shared.clipboard.togglePaused() }
        menu.addItem(.separator())
        for (page, title) in [(PageID.home, "今天"), (.todos, "待办"), (.notes, "笔记"), (.jira, "Jira"), (.activity, "动态"), (.weekly, "周报"), (.wiki, "Wiki")] {
            _ = add(title) { AppModel.shared.navigate(page) }
        }
        menu.addItem(.separator())
        _ = add("设置…") { AppModel.shared.navigate(.settings) }
        _ = add("退出 NextWorkZone") { NSApp.terminate(nil) }
        item.menu = menu
        statusItem = item
    }

    func updateClipboardPause(_ paused: Bool) {
        pauseItem?.title = paused ? "恢复记录剪贴板" : "暂停记录剪贴板"
    }

    // MARK: 全局快捷键

    private func setupShortcuts() {
        HotKeys.shared.setHandler("capture") { CaptureWindow.shared.toggle() }
        HotKeys.shared.setHandler("clipboard") { ClipboardPanel.shared.toggle() }
        HotKeys.shared.initial("capture", API.shared.configuredShortcut("capture"))
        HotKeys.shared.initial("clipboard", API.shared.configuredShortcut("clipboard"))
    }
}

/// 点击时执行闭包的菜单项。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", modifiers: NSEvent.ModifierFlags = [.command], action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// 业务服务需要的平台能力：事件、通知、打开文件、全局快捷键、剪贴板面板。回调可能来自任意线程。
final class AppHost: NWZCore.AppHost, @unchecked Sendable {
    func emit(_ event: ServiceEvent) { Events.post(event) }

    func notify(title: String, body: String) {
        Notifier.send(title, body)
    }

    func openPath(path: String) -> String? {
        let ok = onMain { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        return ok ? nil : "无法打开 \(path)"
    }

    func setShortcut(action: String, shortcut: String) -> String? {
        onMain { HotKeys.shared.set(action, shortcut) }
    }

    func shortcutError(action: String) -> String? {
        onMain { HotKeys.shared.error(action) }
    }

    func hideClipboardPanel(restore: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { ClipboardPanel.shared.hide(restore: restore) } }
    }

    func clipboardPaused(paused: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.updateClipboardPause(paused) }
        }
    }

    private func onMain<T: Sendable>(_ f: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(f) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(f) }
    }
}

/// 主窗口：内容为 SwiftUI 的 [`RootView`]。关闭时只是隐藏。
@MainActor
enum MainWindow {
    private(set) static var window: NSWindow?
    private static let delegate = WindowDelegate()

    static func create() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: RootView().environment(AppModel.shared))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.title = "NextWorkZone"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 960, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.setFrameAutosaveName("NextWorkZoneMain")
        if window.frame.width < 960 { window.setContentSize(NSSize(width: 1280, height: 820)) }
        if !window.setFrameUsingName("NextWorkZoneMain") { window.center() }
        self.window = window
    }

    static func show() {
        guard let window else { return }
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static var isVisible: Bool { window?.isVisible ?? false }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }
    }
}
