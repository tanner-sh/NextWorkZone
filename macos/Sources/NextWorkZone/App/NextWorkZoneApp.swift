import AppKit
import SwiftUI
import NWZCore

/// 应用入口：主窗口、设置窗口、菜单栏图标和菜单栏命令都由 SwiftUI 场景提供；
/// 业务服务的组装、全局快捷键、剪贴板面板等 AppKit 部分在 AppDelegate 中。
@main
struct NextWorkZoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("NextWorkZone", id: MainWindow.id) {
            RootView()
                .environment(AppModel.shared)
                .background(MainWindow.Reader())
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .keyboardShortcut("0", modifiers: [.command, .shift])
        .commands { AppCommands() }

        // 在新窗口中打开的问题、Wiki 页面、文档；重新启动时不恢复
        WindowGroup(id: DetailWindows.id, for: DetailTarget.self) { $target in
            DetailWindow(target: target)
        }
        .defaultSize(width: 1000, height: 780)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)

        Window("预览", id: DetailWindows.previewId) {
            PreviewWindowView()
        }
        .defaultSize(width: 1280, height: 820)
        .restorationBehavior(.disabled)
        // 不在“窗口”菜单中列出（没有内容时打开是空窗口）
        .commandsRemoved()

        // 名字和业务的 Settings 类型相同，写全称
        SwiftUI.Settings {
            SettingsPage()
                .environment(AppModel.shared)
        }

        MenuBarExtra {
            TrayMenu()
        } label: {
            TrayIcon()
        }
    }
}

/// 菜单栏图标的菜单。
private struct TrayMenu: View {
    @Environment(\.openSettings) private var openSettings
    @State private var model = AppModel.shared

    var body: some View {
        Button("打开 NextWorkZone") { MainWindow.show() }
        Divider()
        Button("快速记录…") { CaptureWindow.shared.toggle() }
        Button("记一条待办…") {
            MainWindow.show()
            model.quickTodoOpen = true
        }
        Button("搜索…") {
            MainWindow.show()
            model.paletteOpen = true
        }
        Divider()
        Button("剪贴板…") { ClipboardPanel.shared.toggle() }
        Button(model.clipboardPaused ? "恢复记录剪贴板" : "暂停记录剪贴板") { API.shared.clipboard.togglePaused() }
        Divider()
        ForEach([PageID.home, .todos, .notes, .jira, .activity, .weekly, .wiki], id: \.self) { page in
            Button(AppCommands.pageTitles[page] ?? page.rawValue) { model.navigate(page) }
        }
        Divider()
        Button("设置…") {
            NSApp.activate()
            openSettings()
        }
        Button("退出 NextWorkZone") { NSApp.terminate(nil) }
    }
}

private struct TrayIcon: View {
    private static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "tray-template", withExtension: "png"), let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "NextWorkZone")!
    }()

    var body: some View {
        Image(nsImage: Self.image).help("NextWorkZone")
    }
}

/// 主窗口（SwiftUI 的 Window 场景创建）。关闭时只是隐藏：保留的页面、滚动位置和选中项都还在，再打开时立即显示。
@MainActor
enum MainWindow {
    static let id = "main"
    private(set) static var window: NSWindow?

    static func show() {
        guard let window else { return }
        // 在窗口里点侧栏导航时窗口本来就在最前面，不必每次都和窗口服务器往返一趟
        if NSApp.isActive && window.isKeyWindow && window.isVisible { return }
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static var isVisible: Bool { window?.isVisible ?? false }

    /// 关闭按钮和 ⌘W：主窗口只隐藏，其他窗口照常关闭。
    static func closeKeyWindow() {
        guard let key = NSApp.keyWindow else { return }
        if key === window { key.orderOut(nil) } else { key.performClose(nil) }
    }

    /// 取得 SwiftUI 创建的窗口，补上 SwiftUI 场景没有的设置。
    struct Reader: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { ReaderView() }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    private final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, MainWindow.window !== window else { return }
            MainWindow.window = window
            window.titlebarAppearsTransparent = true
            // 关闭按钮改为隐藏窗口（SwiftUI 关闭窗口会销毁整个视图树）
            if let close = window.standardWindowButton(.closeButton) {
                close.target = CloseTarget.shared
                close.action = #selector(CloseTarget.hide(_:))
            }
            #if DEBUG
            DevBridge.windowReady(window)
            #endif
        }
    }

    @MainActor
    private final class CloseTarget: NSObject {
        static let shared = CloseTarget()
        @objc func hide(_ sender: Any?) { MainWindow.window?.orderOut(nil) }
    }
}
