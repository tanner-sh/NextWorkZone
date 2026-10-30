import AppKit
import SwiftUI

/// 菜单栏命令。应用、编辑、窗口菜单的标准项目由 SwiftUI 提供，这里补上：
/// 文件（记待办、快速记录、关闭窗口只隐藏主窗口）、格式和查找、显示（搜索、⌘1–⌘9、⌘0 切换页面），
/// 以及跟随当前页面的菜单（新建、刷新，和选中的问题、待办等的操作，与右键菜单相同）。
struct AppCommands: Commands {
    /// 侧栏中的页面顺序（⌘1 起）。
    static let pageOrder: [PageID] = [.home, .todos, .notes, .kb, .jira, .wiki, .gitlab, .activity, .weekly, .stats]

    static let pageTitles: [PageID: String] = [
        .home: "今天", .todos: "待办", .notes: "笔记", .kb: "知识库", .jira: "Jira", .wiki: "Wiki", .gitlab: "GitLab",
        .activity: "动态", .weekly: "周报", .stats: "统计", .settings: "设置", .search: "搜索", .tools: "工具",
    ]

    @FocusedValue(\.pageCommands) private var page

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("记一条待办…") {
                MainWindow.show()
                AppModel.shared.quickTodoOpen = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("快速记录…") { CaptureWindow.shared.toggle() }
        }
        CommandGroup(replacing: .saveItem) {
            Button("关闭窗口") { MainWindow.closeKeyWindow() }.keyboardShortcut("w")
        }
        CommandGroup(after: .pasteboard) {
            Button("粘贴并匹配样式") { NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil) }
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
        }
        TextEditingCommands()
        TextFormattingCommands()
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Button("进入全屏幕") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
        // 没有帮助文档
        CommandGroup(replacing: .help) {}
        CommandGroup(before: .sidebar) {
            Button("搜索…") {
                MainWindow.show()
                AppModel.shared.paletteOpen.toggle()
            }
            .keyboardShortcut("k")
            Divider()
            ForEach(Array(Self.pageOrder.enumerated()), id: \.element) { i, page in
                Button(Self.pageTitles[page] ?? page.rawValue) { AppModel.shared.navigate(page) }
                    .keyboardShortcut(KeyEquivalent(Character(String((i + 1) % 10))))
            }
            Divider()
        }
        CommandMenu(page?.title ?? "操作") {
            if let page {
                if let newItem = page.newItem {
                    Button(newItem.title, action: newItem.action).keyboardShortcut("n")
                }
                if let refresh = page.refresh {
                    Button("刷新", action: refresh).keyboardShortcut("r")
                }
                if page.newItem != nil || page.refresh != nil, !page.specs.isEmpty { Divider() }
                MenuSpecItems(specs: page.specs)
            } else {
                Button("刷新") {}.keyboardShortcut("r").disabled(true)
            }
        }
    }
}

/// 当前页面提供给菜单栏的命令：页面级的新建、刷新，以及选中内容的操作（通常和它的右键菜单相同）。
struct PageCommands {
    /// 菜单标题，例如“问题”“待办”
    var title: String
    var newItem: (title: String, action: () -> Void)?
    var refresh: (() -> Void)?
    var specs: [MenuSpec] = []
}

private struct PageCommandsKey: FocusedValueKey {
    typealias Value = PageCommands
}

extension FocusedValues {
    var pageCommands: PageCommands? {
        get { self[PageCommandsKey.self] }
        set { self[PageCommandsKey.self] = newValue }
    }
}

extension View {
    /// 页面的菜单栏命令（见 PageCommands）：页面显示、主窗口在前面时出现在菜单栏中。
    func pageCommands(_ commands: @escaping () -> PageCommands) -> some View {
        modifier(PageCommandsModifier(commands: commands))
    }
}

private struct PageCommandsModifier: ViewModifier {
    @Environment(\.page) private var pageState
    let commands: () -> PageCommands

    func body(content: Content) -> some View {
        // 保留的页面隐藏后不提供命令
        content.focusedSceneValue(\.pageCommands, pageState.active ? commands() : nil)
    }
}

/// 用 SwiftUI 菜单显示 MenuSpec（菜单栏中）。打开时才加载的子菜单改为点击后在鼠标处弹出加载好的菜单。
private struct MenuSpecItems: View {
    var specs: [MenuSpec]

    var body: some View {
        ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
            switch spec {
            case .separator:
                Divider()
            case .label(let text):
                Text(text)
            case let .item(title, icon, checked, disabled, destructive, confirm, action):
                Group {
                    if checked {
                        // 菜单中的 Toggle 显示为带对勾的项目
                        Toggle(isOn: Binding(get: { true }, set: { _ in MenuSpec.perform(confirm: confirm, action) })) { MenuSpecLabel(title: title, icon: icon) }
                    } else {
                        Button(role: destructive ? .destructive : nil) { MenuSpec.perform(confirm: confirm, action) } label: { MenuSpecLabel(title: title, icon: icon) }
                    }
                }
                .disabled(disabled)
            case let .submenu(title, icon, children):
                Menu {
                    MenuSpecItems(specs: children)
                } label: {
                    MenuSpecLabel(title: title, icon: icon)
                }
            case let .lazy(title, icon, load):
                Button {
                    Task { @MainActor in
                        do {
                            let specs = try await load()
                            MenuBuilder.popUp(specs.isEmpty ? [.label("没有可用的项")] : specs, in: MainWindow.window?.contentView)
                        } catch {
                            if !isCancellation(error) { toast("加载失败：\(errorMessage(error))", error: true) }
                        }
                    }
                } label: {
                    MenuSpecLabel(title: title + "…", icon: icon)
                }
            }
        }
    }
}

private struct MenuSpecLabel: View {
    var title: String
    var icon: String?

    var body: some View {
        if let icon { Label(title, systemImage: icon) } else { Text(title) }
    }
}
