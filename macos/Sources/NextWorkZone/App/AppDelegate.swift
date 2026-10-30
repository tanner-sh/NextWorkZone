import AppKit
import SwiftUI
import NWZCore

/// 应用的 AppKit 部分：组装业务服务，注册全局快捷键，准备剪贴板面板和快速记录窗口。
/// 关闭主窗口只是隐藏，应用继续在后台同步、提醒；从菜单栏图标或程序坞图标重新打开，⌘Q 或菜单栏图标的“退出”才退出。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 在 SwiftUI 创建窗口之前组装服务：主窗口的内容一出现就要用到。
    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            let paths = AppPaths.current()
            API.shared = try API.make(paths: paths)
        } catch {
            let alert = NSAlert()
            alert.messageText = "启动 NextWorkZone 失败"
            alert.informativeText = errorMessage(error)
            alert.runModal()
            exit(1)
        }
        AppModel.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupShortcuts()
        ListClickFocus.install()
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

    /// 点程序坞图标：显示隐藏的主窗口（不让 SwiftUI 另外处理）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
            MainActor.assumeIsolated { AppModel.shared.clipboardPaused = paused }
        }
    }

    private func onMain<T: Sendable>(_ f: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(f) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(f) }
    }
}
