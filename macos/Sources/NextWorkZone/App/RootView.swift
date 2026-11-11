import SwiftUI

/// 主窗口：侧栏 + 内容区。侧栏中的页面切走后只隐藏、不销毁（见 KeptPages）：
/// 回来时立即显示，滚动位置、选中项、搜索条件和展开状态都还在；需要最新数据的页面按 `PageState.visit` 在后台刷新（切换完成后才刷新，且有最小间隔）。
/// 其余页面（搜索、工具）每次打开时重新创建。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var kept: [PageID] = []
    @State private var columns: NavigationSplitViewVisibility = .automatic
    /// 各保留页面第几次刷新（见 scheduleVisit）
    @State private var visits: [PageID: Int] = [:]
    /// 各保留页面上次刷新（或创建）的时间
    @State private var refreshed: [PageID: Date] = [:]
    @State private var pendingVisit: Task<Void, Never>?

    /// 回到页面后等多久再在后台刷新：等页面内容切换完，刷新不和切换抢主线程；中途又切走的页面不刷新。
    static let visitDelay: TimeInterval = 0.35
    /// 同一个页面两次后台刷新的最小间隔：来回切换时不必每次都重新加载（今天页一次要重新加载七张卡片）。
    /// 没到间隔时推迟到间隔满了再刷新（仍停在这个页面的话），所以停在页面上看到的数据最多旧这么久。
    static let visitInterval: TimeInterval = 30

    /// 按钮栏中不显示标题的页面：左侧有切换视图的分段控件（它本身就说明了在哪儿，侧栏也标明了当前页面），
    /// 标题只会夹在几组按钮之间。没有分段控件的页面（今天、知识库、周报）标题在最左边。
    static let untitled: Set<PageID> = [.todos, .notes, .jira, .wiki, .gitlab, .activity, .stats, .tools, .search]

    static let keepAlive: Set<PageID> = [.home, .todos, .notes, .kb, .jira, .wiki, .gitlab, .activity, .weekly, .stats]

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                // 显示、隐藏侧栏的按钮由侧栏和按钮栏自己画（窗口没有系统工具栏）
                .toolbar(removing: .sidebarToggle)
        } detail: {
            // 页面铺到窗口最上面，顶部是页面自己的按钮栏（见 PageChrome）：各保留页面的宿主视图不留窗口的安全区，其余页面忽略它
            ZStack {
                KeptPages(pages: kept, active: model.current.page, visits: visits) { page, state in
                    AnyView(pageView(page).modifier(MainPageBar(page: page))
                        .environment(\.page, state).environment(\.windowChrome, .main).environment(model))
                }
                if !Self.keepAlive.contains(model.current.page) {
                    pageView(model.current.page)
                        .modifier(MainPageBar(page: model.current.page))
                        .id(model.current.page)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            // 窗口的名字（“窗口”菜单、调度中心中）；页面的标题画在按钮栏里
            .navigationTitle("NextWorkZone")
        }
        .windowBarChrome(.main)
        .onChange(of: columns, initial: true) { _, c in WindowChrome.main.sidebarHidden = c == .detailOnly }
        .onAppear {
            WindowChrome.main.toggleSidebar = { withAnimation { columns = columns == .detailOnly ? .all : .detailOnly } }
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
        .onAppear {
            model.openSettingsAction = openSettings
            model.openWindowAction = openWindow
        }
        // 从通知等处回到应用：当前页面按再次显示处理，在后台刷新
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if kept.contains(model.current.page) { scheduleVisit(model.current.page) }
        }
        .onChange(of: model.current.page, initial: true) { _, page in
            guard Self.keepAlive.contains(page) else { return }
            pendingVisit?.cancel()
            if kept.contains(page) {
                scheduleVisit(page)
            } else {
                // 第一次显示：页面创建时自己加载
                kept.append(page)
                refreshed[page] = Date()
            }
        }
    }

    /// 保留的页面再次显示（或从别的应用回来）：稍后让它在后台刷新（`PageState.visit` 加一）。
    private func scheduleVisit(_ page: PageID) {
        pendingVisit?.cancel()
        let since = Date().timeIntervalSince(refreshed[page] ?? .distantPast)
        let wait = max(Self.visitDelay, Self.visitInterval - since)
        pendingVisit = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, model.current.page == page else { return }
            refreshed[page] = Date()
            visits[page, default: 0] += 1
        }
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
        case .settings: EmptyView()
        case .search: SearchPage()
        }
    }
}

/// 主窗口中页面的按钮栏：没有分段控件的页面在最左边显示标题和副标题。
private struct MainPageBar: ViewModifier {
    var page: PageID

    func body(content: Content) -> some View {
        let titled = !RootView.untitled.contains(page)
        content.pageBarRoot(title: titled ? AppCommands.pageTitles[page] ?? "" : "", subtitle: titled ? PageTitles.shared.subtitles[page] ?? "" : "")
    }
}

/// 页面的显示状态。每个保留的页面一个，切换页面时只改它的属性：只有读了这些属性的视图会更新。
/// 改成环境值的话，每次切换整个页面都要检查一遍（环境变化要逐个视图比较用到的值），切到问题列表等较大的页面要多花几十毫秒。
// 只在主线程使用；不标 @MainActor，才能作为环境值的默认值
@Observable
final class PageState {
    /// 页面是否正在显示。切走后保留的页面隐藏时为 false：不应响应快捷键、接收拖入的文件。
    var active: Bool
    /// 保留的页面再次显示后该在后台刷新时加一（首次显示为 0；切换完成后才加，且有最小间隔，见 RootView.scheduleVisit）。
    /// 放进 `.task(id:)` 就能在回到页面时后台刷新，已显示的内容不清空。
    var visit: Int

    init(active: Bool = true, visit: Int = 0) { self.active = active; self.visit = visit }

    /// 不保留的页面（搜索、工具）：一直显示，每次打开都重新创建
    nonisolated(unsafe) static let always = PageState()
}

private struct PageStateKey: EnvironmentKey {
    static var defaultValue: PageState { .always }
}

extension EnvironmentValues {
    /// 所在页面的显示状态（见 PageState）。
    var page: PageState {
        get { self[PageStateKey.self] }
        set { self[PageStateKey.self] = newValue }
    }
}

/// 侧栏：搜索入口、页面分组、工具。设置在单独的设置窗口中（⌘,）。
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// 正有内容拖到其上的页面
    @State private var dropTarget: PageID?
    @State private var springTask: Task<Void, Never>?

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
        }
        .listStyle(.sidebar)
        // 侧栏顶部（红绿灯右边）：隐藏侧栏的按钮；空白处拖动窗口
        .overlay(alignment: .top) {
            HStack {
                Spacer()
                Button("隐藏边栏", systemImage: "sidebar.leading") { WindowChrome.main.toggleSidebar() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .frame(width: PageBarMetrics.itemHeight, height: PageBarMetrics.itemHeight)
                    .contentShape(Rectangle())
                    .help("隐藏边栏")
            }
            .padding(.trailing, 6)
            .frame(height: PageBarMetrics.height)
            .background {
                Color.clear.contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .simultaneousGesture(TapGesture(count: 2).onEnded { TitlebarFix.titlebarDoubleClick() })
                    .allowsWindowActivationEvents(true)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarLoginStatus() }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        let count = model.count(entry.id)
        let alert = entry.id == .jira && model.overdue > 0
        let index = AppCommands.pageOrder.firstIndex(of: entry.id)
        let note = alert ? "\n\(model.overdue) 个问题已逾期或今天到期" : entry.id == .todos ? count.map { "\n\($0) 个待办今天到期或已逾期" } ?? "" : ""
        let label = Label(entry.label, systemImage: entry.icon)
            .badge(count.map { Text("\($0)").foregroundStyle(alert ? Color.red : Color.secondary) })
            .tag(entry.id.rawValue)
            .help("\(entry.label)\(index.map { "（⌘\(($0 + 1) % 10)）" } ?? "")\(note)")
        // 问题、Wiki 页面、合并请求或文字拖到“待办”上加为待办，拖到“笔记”上追加到今天的日记，不用离开当前页面；
        // 停在“待办”“笔记”“知识库”上不放，稍后切换到那个页面（像访达的弹簧文件夹），可以放到页面中的具体位置
        if [.todos, .notes, .kb].contains(entry.id) {
            label.dropDestination(for: DroppedWork.self) { items, _ in
                springTask?.cancel()
                switch entry.id {
                case .todos: DroppedWork.addTodos(items)
                case .notes: DroppedWork.appendToDaily(items)
                default: return false
                }
                return !items.isEmpty
            } isTargeted: { targeted in
                springTask?.cancel()
                if targeted {
                    dropTarget = entry.id
                    springTask = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        if !Task.isCancelled, dropTarget == entry.id { model.navigate(entry.id) }
                    }
                } else if dropTarget == entry.id {
                    dropTarget = nil
                }
            }
            .listRowBackground(dropTarget == entry.id ? Color.accentColor.opacity(0.25).clipShape(.rect(cornerRadius: 6)) : nil)
        } else {
            label
        }
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
