import SwiftUI

/// 主窗口：侧栏 + 内容区。侧栏中的页面切走后只隐藏、不销毁（见 KeptPages）：
/// 回来时立即显示，滚动位置、选中项、搜索条件和展开状态都还在；需要最新数据的页面按 `pageVisit` 在后台刷新。
/// 其余页面（搜索、工具）每次打开时重新创建。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var kept: [PageID] = []
    /// 各保留页面第几次显示
    @State private var visits: [PageID: Int] = [:]

    /// 不在窗口中显示标题的页面：侧栏已经标明当前页面，标题夹在列表和详情两组工具栏按钮之间显得突兀；条数等信息放在列表上方
    static let untitled: Set<PageID> = [.jira, .gitlab]

    static let keepAlive: Set<PageID> = [.home, .todos, .notes, .kb, .jira, .wiki, .gitlab, .activity, .weekly, .stats, .settings]

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ZStack {
                KeptPages(pages: kept, active: model.current.page) { page, active in
                    AnyView(pageView(page).environment(\.pageActive, active).environment(\.pageVisit, visits[page] ?? 0).environment(model))
                }
                if !Self.keepAlive.contains(model.current.page) {
                    pageView(model.current.page)
                        .id(model.current.page)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(Self.untitled.contains(model.current.page) ? "" : title)
            .navigationSubtitle(Self.untitled.contains(model.current.page) ? "" : PageTitles.shared.subtitles[model.current.page] ?? "")
        }
        // 窗口的最小尺寸由 SwiftUI 内容决定（NSHostingController 会覆盖 window.minSize）；
        // 太窄时列表加详情的页面挤成一个字宽，长 Wiki 页面会排成几十万点高，画面出现黑块
        .frame(minWidth: 960, minHeight: 600)
        .overlay { ToastOverlay() }
        .overlay {
            if model.paletteOpen {
                CommandPalette()
            }
        }
        .sheet(isPresented: $model.quickTodoOpen) {
            QuickTodoSheet()
        }
        // 富文本右键菜单中的问题菜单（流转、分配需要的对话框）
        .issueMenuDialogs(IssueMenu.shared)
        .onChange(of: model.current.page, initial: true) { _, page in
            guard Self.keepAlive.contains(page) else { return }
            if kept.contains(page) { visits[page, default: 0] += 1 } else { kept.append(page) }
        }
    }

    private var title: String {
        if model.current.page == .tools { return Tools.byId(model.current.tool)?.name ?? Tools.all[0].name }
        return MainMenu.pageTitles[model.current.page] ?? "NextWorkZone"
    }

    @ViewBuilder
    private func pageView(_ page: PageID) -> some View {
        switch page {
        case .home: HomePage()
        case .todos: TodoPage()
        case .notes: NotesPage()
        case .kb: KnowledgePage()
        case .jira: JiraPage()
        case .activity: ActivityPage()
        case .weekly: WeeklyPage()
        case .wiki: WikiPage()
        case .gitlab: GitlabPage()
        case .stats: StatsPage()
        case .tools: ToolsPage()
        case .settings: SettingsPage()
        case .search: SearchPage()
        }
    }
}

private struct PageActiveKey: EnvironmentKey {
    static let defaultValue = true
}

private struct PageVisitKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// 页面是否正在显示。切走后保留的页面隐藏时为 false：不应响应快捷键、接收拖入的文件。
    var pageActive: Bool {
        get { self[PageActiveKey.self] }
        set { self[PageActiveKey.self] = newValue }
    }

    /// 保留的页面再次显示时加一（首次显示为 0）。放进 `.task(id:)` 就能在回到页面时后台刷新，已显示的内容不清空。
    var pageVisit: Int {
        get { self[PageVisitKey.self] }
        set { self[PageVisitKey.self] = newValue }
    }
}

/// 侧栏：搜索入口、页面分组、工具、设置。
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    private struct Entry: Identifiable {
        var id: PageID
        var label: String
        var icon: String
    }

    private let groups: [(String, [Entry])] = [
        ("工作空间", [Entry(id: .home, label: "今天", icon: "square.grid.2x2"), Entry(id: .todos, label: "待办", icon: "checkmark.square"), Entry(id: .notes, label: "笔记", icon: "note.text"), Entry(id: .kb, label: "知识库", icon: "book")]),
        ("集成", [Entry(id: .jira, label: "Jira", icon: "smallcircle.filled.circle"), Entry(id: .wiki, label: "Wiki", icon: "text.book.closed"), Entry(id: .gitlab, label: "GitLab", icon: "arrow.triangle.branch")]),
        // 回看发生了什么：动态、周报、统计（需要处理的事在今天页）
        ("回顾", [Entry(id: .activity, label: "动态", icon: "bell"), Entry(id: .weekly, label: "周报", icon: "square.and.pencil"), Entry(id: .stats, label: "统计", icon: "chart.bar")]),
    ]

    var body: some View {
        let selection = Binding<String?>(
            get: { model.current.page == .tools ? "tool:\(model.current.tool ?? Tools.all[0].id)" : model.current.page.rawValue },
            set: { value in
                guard let value else { return }
                if value.hasPrefix("tool:") { model.navigate(NavTarget(.tools, tool: String(value.dropFirst(5)))) }
                else if let page = PageID(rawValue: value), page != model.current.page { model.navigate(page) }
            }
        )
        List(selection: selection) {
            Button {
                model.paletteOpen = true
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("搜索")
                    Spacer()
                    Text("⌘K").font(.caption).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.fieldFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("搜索问题、项目、文档，或跳转到页面")
            .listRowSeparator(.hidden)

            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { entry in
                        row(entry)
                    }
                }
            }
            let tools = Tools.all.filter { !model.hiddenTools.contains($0.id) }
            if !tools.isEmpty {
                Section("工具") {
                    ForEach(tools) { tool in
                        Label(tool.name, systemImage: tool.icon).tag("tool:\(tool.id)")
                    }
                }
            }
            Section {
                Label("设置", systemImage: "gearshape").tag(PageID.settings.rawValue)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        let count = model.count(entry.id)
        let alert = entry.id == .jira && model.overdue > 0
        let index = MainMenu.pageOrder.firstIndex(of: entry.id)
        Label(entry.label, systemImage: entry.icon)
            .badge(count.map { Text("\($0)").foregroundStyle(alert ? Color.red : Color.secondary) })
            .tag(entry.id.rawValue)
            .help("\(entry.label)\(index.map { "（⌘\(($0 + 1) % 10)）" } ?? "")\(alert ? "\n\(model.overdue) 个问题已逾期或今天到期" : "")")
    }
}

/// 小工具的注册表：侧边栏的“工具”分组、⌘K 搜索、设置页的“工具”卡片都据此生成。
struct ToolDef: Identifiable {
    var id: String
    var name: String
    var icon: String
    /// 一句话说明，显示在设置页和搜索结果中
    var description: String
    /// ⌘K 搜索的关键词（含拼音首字母）
    var keywords: String
}

enum Tools {
    static let all: [ToolDef] = [
        ToolDef(id: "clipboard", name: "剪贴板", icon: "list.clipboard", description: "记录复制过的文字、图片和文件，按快捷键随时搜索、粘贴；常用内容可以置顶。", keywords: "clipboard paste 剪贴板 粘贴 复制 历史 jtb"),
    ]

    static func byId(_ id: String?) -> ToolDef? { all.first { $0.id == id } }
}

/// 工具页面：按注册表找到对应的工具。
struct ToolsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch Tools.byId(model.current.tool)?.id ?? Tools.all[0].id {
        default: ClipboardPage(tab: model.current.toolTab, query: model.current.toolQuery)
        }
    }
}
