import AppKit

/// 菜单栏：应用、编辑、显示（切换页面）、窗口。页面快捷键 ⌘1–⌘9、⌘0 与 Tauri 版相同。
@MainActor
enum MainMenu {
    /// 侧栏中的页面顺序（⌘1 起）。
    static let pageOrder: [PageID] = [.home, .todos, .notes, .kb, .jira, .wiki, .gitlab, .activity, .weekly, .stats]

    static let pageTitles: [PageID: String] = [
        .home: "今天", .todos: "待办", .notes: "笔记", .kb: "知识库", .jira: "Jira", .wiki: "Wiki", .gitlab: "GitLab",
        .activity: "动态", .weekly: "周报", .stats: "统计", .settings: "设置", .search: "搜索", .tools: "工具",
    ]

    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 NextWorkZone", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(title: "设置…", keyEquivalent: ",") { AppModel.shared.navigate(.settings) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 NextWorkZone", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 NextWorkZone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, "NextWorkZone"))

        let file = NSMenu(title: "文件")
        file.addItem(ClosureMenuItem(title: "记一条待办…", keyEquivalent: "n", modifiers: [.command, .shift]) {
            MainWindow.show()
            AppModel.shared.quickTodoOpen = true
        })
        file.addItem(ClosureMenuItem(title: "快速记录…") { CaptureWindow.shared.toggle() })
        file.addItem(.separator())
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, "文件"))

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "粘贴并匹配样式", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "查找")
        let findItem = find.addItem(withTitle: "查找…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        let next = find.addItem(withTitle: "查找下一个", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        next.tag = Int(NSTextFinder.Action.nextMatch.rawValue)
        let prev = find.addItem(withTitle: "查找上一个", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        prev.keyEquivalentModifierMask = [.command, .shift]
        prev.tag = Int(NSTextFinder.Action.previousMatch.rawValue)
        edit.addItem(submenu(find, "查找"))
        let format = NSMenu(title: "格式")
        format.addItem(withTitle: "粗体", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "b").tag = Int(NSFontTraitMask.boldFontMask.rawValue)
        format.addItem(withTitle: "斜体", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "i").tag = Int(NSFontTraitMask.italicFontMask.rawValue)
        format.addItem(withTitle: "下划线", action: #selector(NSText.underline(_:)), keyEquivalent: "u")
        for item in format.items where item.action == #selector(NSFontManager.addFontTrait(_:)) { item.target = NSFontManager.shared }
        edit.addItem(submenu(format, "格式"))
        main.addItem(submenu(edit, "编辑"))

        let view = NSMenu(title: "显示")
        view.addItem(ClosureMenuItem(title: "搜索…", keyEquivalent: "k") {
            MainWindow.show()
            AppModel.shared.paletteOpen.toggle()
        })
        view.addItem(.separator())
        for (i, page) in pageOrder.enumerated() {
            view.addItem(ClosureMenuItem(title: pageTitles[page] ?? page.rawValue, keyEquivalent: String((i + 1) % 10)) { AppModel.shared.navigate(page) })
        }
        view.addItem(.separator())
        let full = view.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view, "显示"))

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(ClosureMenuItem(title: "NextWorkZone", keyEquivalent: "0", modifiers: [.command, .shift]) { MainWindow.show() })
        main.addItem(submenu(window, "窗口"))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }
}
