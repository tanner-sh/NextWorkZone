import SwiftUI

/// 今天：需要处理的事、今天的待办、本周周报、我的未解决问题、今天的工作记录、最近的 Wiki 和项目。
struct HomePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 读设置后才知道连接了哪些系统；没连接的系统不显示卡片，底部用一行提示代替
        let loaded = model.settings != nil
        let missing = loaded ? [Service.jira, .confluence, .gitlab].filter { !model.isReady($0) } : []
        var half: [AnyView] = [AnyView(TodayTodosCard())]
        if model.isReady(.confluence) { half.append(AnyView(WeeklyCard())) }
        half.append(AnyView(WorkLogCard()))
        if model.isReady(.confluence) { half.append(AnyView(WikiRecentCard())) }
        if model.isReady(.gitlab) { half.append(AnyView(ProjectsCard())) }
        let rows = stride(from: 0, to: half.count, by: 2).map { Array(half[$0..<min($0 + 2, half.count)]) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 每分钟更新一次，问候语、日期跟着时间变
                TimelineView(.everyMinute) { context in
                    let hour = Calendar.current.component(.hour, from: context.date)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hour < 12 ? "上午好" : hour < 18 ? "下午好" : "晚上好").font(.largeTitle.weight(.semibold))
                        Text("\(Calendar.current.component(.month, from: context.date)) 月 \(Calendar.current.component(.day, from: context.date)) 日 · \(Fmt.weekday(Fmt.day(context.date)))")
                            .foregroundStyle(.secondary)
                    }
                }
                AttentionCard()
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    ForEach(rows.indices, id: \.self) { i in
                        GridRow {
                            ForEach(rows[i].indices, id: \.self) { j in rows[i][j] }
                            if rows[i].count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                        // 我的未解决问题占一整行，放在第一行之后
                        if i == 0 && model.isReady(.jira) {
                            GridRow { MyIssuesCard().gridCellColumns(2) }
                        }
                    }
                }
                if !missing.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        Text("连接 \(missing.map(\.label).joined(separator: "、")) 后，\(Self.benefit(missing))也会显示在这里。").foregroundStyle(.secondary)
                        Button("去设置") { model.navigate(NavTarget(.settings, toolTab: "connection")) }.buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private static func benefit(_ missing: [Service]) -> String {
        missing.map { s in
            switch s {
            case .jira: "分配给你的问题"
            case .confluence: "周报和最近的 Wiki"
            case .gitlab: "活跃的项目和待审核的合并请求"
            }
        }.joined(separator: "、")
    }
}

/// 卡片：标题、右侧操作、内容。
struct Card<Content: View, Actions: View>: View {
    var title: String
    var count: Int? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if let count { Text("\(count)").foregroundStyle(.secondary) }
                Spacer()
                actions()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .groupBackground()
    }
}

extension Card where Actions == EmptyView {
    init(title: String, count: Int? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, count: count, actions: { EmptyView() }, content: content)
    }
}

/// 卡片中的一行（可点击）。
struct HomeRow<Content: View>: View {
    var action: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(hover && action != nil ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { action?() }
    }
}

/// 加载状态：加载中、失败、未配置、完成。
enum Loadable<T> {
    case loading, off, failed(String), ok(T)

    var value: T? { if case .ok(let v) = self { v } else { nil } }
}

struct LoadableBody<T, Content: View>: View {
    var state: Loadable<T>
    var offLabel: String
    var settingsTab = "connection"
    @ViewBuilder var content: (T) -> Content

    var body: some View {
        switch state {
        case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        case .failed(let m): Text(m).font(.callout).foregroundStyle(.red)
        case .off:
            HStack(spacing: 4) {
                Text("尚未配置 \(offLabel)。").foregroundStyle(.secondary)
                Button("去设置") { AppModel.shared.navigate(NavTarget(.settings, toolTab: settingsTab)) }.buttonStyle(.link)
            }
            .font(.callout)
        case .ok(let v): content(v)
        }
    }
}

// MARK: - 需要处理

/// 需要我回应的动态、逾期或今天到期的问题、请我审核的合并请求。
/// 每条可以打开、标为已处理、转为待办或稍后提醒；处理之后有新变化时会再次出现。
struct AttentionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var todos: [Todo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showSnoozed = false

    var body: some View {
        let view = model.inbox
        let items = view?.items ?? []
        let snoozed = view?.snoozed ?? []
        Group {
            if let view, items.isEmpty, snoozed.isEmpty, view.notes.isEmpty, error == nil {
                // 没有任何需要处理的事：只占一行
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("没有需要处理的事").foregroundStyle(.secondary)
                    refreshButton
                }
                .help("@你、分配给你、评论，到期的问题和请你审核的合并请求会出现在这里")
            } else {
                Card(title: "需要处理", count: items.isEmpty ? nil : items.count, actions: { refreshButton }) {
                    if let error { Text(error).font(.callout).foregroundStyle(.red) }
                    ForEach(view?.notes ?? [], id: \.self) { n in Notice(text: n) }
                    if view == nil && error == nil { ProgressView().controlSize(.small) }
                    VStack(spacing: 2) {
                        ForEach(items) { item in row(item) }
                    }
                    if !snoozed.isEmpty {
                        DisclosureGroup(isExpanded: $showSnoozed) {
                            ForEach(snoozed) { item in
                                HStack {
                                    ItemIcon(item: item)
                                    Button(item.title.isEmpty ? "无标题" : item.title) { open(item) }.buttonStyle(.plain).lineLimit(1)
                                    Spacer()
                                    if let until = item.snoozeUntil { Text("\(Fmt.moment(until)) 提醒").font(.caption).foregroundStyle(.secondary) }
                                    Button("取消稍后", systemImage: "bell.slash") { run { await model.snooze(item, until: nil) } }.controlSize(.small)
                                }
                            }
                        } label: {
                            Text("稍后提醒 \(snoozed.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: "\(visit)|\(model.today)") {
            await refresh()
            await loadTodos()
        }
        .onWorkspaceChange { Task { await loadTodos() } }
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            Image(systemName: "arrow.clockwise").refreshing(loading)
        }
        .buttonStyle(.borderless)
        .help("刷新")
        .disabled(loading)
    }

    private func refresh() async {
        loading = true
        if await model.refreshInbox() == nil { error = "无法汇总需要处理的事" } else { error = nil }
        loading = false
    }

    private func loadTodos() async {
        todos = (try? await API.shared.wsTodos()) ?? []
    }

    private func run(_ task: @escaping () async throws -> Void) {
        Task {
            do { try await task() } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
                await model.refreshInbox()
            }
        }
    }

    private func open(_ item: InboxItem) {
        if let t = InboxText.target(item) { model.navigate(t) }
    }

    private func toTodo(_ item: InboxItem, _ due: String?) {
        run {
            _ = try await InboxText.toTodo(item, due: due, todos: todos)
            await loadTodos()
        }
    }

    private func snoozeMenu(_ item: InboxItem) -> [MenuSpec] {
        Fmt.momentPresets().map { p in .action(p.label, icon: "alarm") { run { await model.snooze(item, until: p.at) } } }
    }

    private func moreMenu(_ item: InboxItem) -> [MenuSpec] {
        let day = Fmt.today()
        return [
            .action("转为待办：今天", icon: "calendar") { toTodo(item, day) },
            .action("转为待办：明天", icon: "calendar") { toTodo(item, Fmt.addDays(day, 1)) },
            .action("转为待办：不设日期", icon: "checkmark.square") { toTodo(item, nil) },
            .separator,
            .submenu("稍后提醒", icon: "alarm", children: snoozeMenu(item)),
            .action("已处理", icon: "checkmark") { run { await model.handle(item) } },
        ]
    }

    private func row(_ item: InboxItem) -> some View {
        AttentionRow(item: item, open: { open(item) }, today: { toTodo(item, Fmt.today()) }, snooze: { MenuBuilder.popUp(snoozeMenu(item)) }, handled: { run { await model.handle(item) } }, more: { MenuBuilder.popUp(moreMenu(item)) })
            .contextMenu(specs: { moreMenu(item) })
    }

    /// 一行需要处理的事：常用的“已处理”一直显示，其余按钮在鼠标移到这一行上时出现（右键菜单中也有）。
    private struct AttentionRow: View {
        var item: InboxItem
        var open: () -> Void
        var today: () -> Void
        var snooze: () -> Void
        var handled: () -> Void
        var more: () -> Void
        @State private var hover = false

        var body: some View {
            let detail = InboxText.detail(item)
            HomeRow(action: open) {
                ItemIcon(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? "无标题" : item.title).lineLimit(1)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if item.source != "due" { Text(Fmt.time(ms: item.at)).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    Button("今天", action: today).controlSize(.small).help("转为今天的待办")
                    Button(action: snooze) { Image(systemName: "alarm") }.buttonStyle(.borderless).help("稍后提醒").accessibilityLabel("稍后提醒")
                    Button(action: more) { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("更多").accessibilityLabel("更多")
                }
                // 不显示时仍占位，鼠标移入时这一行不跳动
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
                Button(action: handled) { Image(systemName: "checkmark") }.buttonStyle(.borderless).help("已处理").accessibilityLabel("已处理")
            }
            .onHover { hover = $0 }
        }
    }

    private struct ItemIcon: View {
        var item: InboxItem
        var body: some View {
            let (icon, tint): (String, Color) = item.source == "due" ? ("clock", .orange) : item.source == "mr" ? ("arrow.triangle.pull", .purple) : item.system == "wiki" ? ("text.book.closed", .teal) : ("smallcircle.filled.circle", .blue)
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
        }
    }
}

// MARK: - 今天的待办

/// 到期（含逾期）的待办，可直接勾选；添加和安排在“待办”页（或 ⌘⇧N）。
struct TodayTodosCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var todos: [Todo]?
    /// 刚勾选完成、稍后移走的待办
    @State private var finishing: Set<String> = []

    var body: some View {
        let day = model.today
        let sorted = (todos ?? []).sorted { ($0.due ?? "", -$0.priority) < ($1.due ?? "", -$1.priority) }
        Card(title: "今天的待办", count: (todos?.isEmpty ?? true) ? nil : todos?.count, actions: {
            Button("写日记", systemImage: "calendar") { model.navigate(NavTarget(.notes, docId: "daily-\(day)")) }.buttonStyle(.borderless)
            Button("全部") { model.navigate(.todos) }.buttonStyle(.borderless)
        }) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sorted) { t in
                    HomeRow(action: { model.navigate(NavTarget(.todos, todoId: t.id)) }) {
                        CheckCircle(done: finishing.contains(t.id), priority: t.priority, size: 15) { complete(t) }
                        Text(t.title).lineLimit(1)
                        Spacer(minLength: 4)
                        if let key = t.refKey, t.refSystem == "jira" { Chip(text: key, icon: "smallcircle.filled.circle") }
                        if t.refKey != nil && t.refSystem == "wiki" { Chip(text: "Wiki", icon: "text.book.closed") }
                        if let due = t.due, due < day { Chip(text: Fmt.dayLabel(due), tint: .red) }
                    }
                    .contextMenu(specs: { TodoActions.menu(t) })
                }
                if let todos, todos.isEmpty {
                    Text("今天没有到期的待办。按 ⌘⇧N 随时记一条，或到待办中安排。").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(visit)|\(model.today)") { await load() }
        .onWorkspaceChange { Task { await load() } }
    }

    private func load() async {
        let day = model.today
        todos = (try? await API.shared.wsTodos())?.filter { !$0.done && ($0.due.map { $0 <= day } ?? false) || finishing.contains($0.id) } ?? []
    }

    /// 勾选后对勾先显示一会儿再移走，提示中可以撤销
    private func complete(_ todo: Todo) {
        guard !finishing.contains(todo.id) else { return }
        finishing.insert(todo.id)
        guarded {
            _ = try await TodoActions.setDone(todo, true)
            TodoActions.completed(todo)
            try? await Task.sleep(for: .seconds(1.5))
            finishing.remove(todo.id)
            withAnimation { todos?.removeAll { $0.id == todo.id } }
        }
    }
}

// MARK: - 周报

struct WeeklyCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var state: Loadable<WeeklyView> = .loading

    var body: some View {
        Card(title: "本周周报", actions: { Button("去填写") { model.navigate(.weekly) }.buttonStyle(.borderless) }) {
            LoadableBody(state: state, offLabel: "周报页面", settingsTab: "general") { view in status(view) }
        }
        .task(id: "\(model.isReady(.confluence))|\(model.settings?.weeklyPageId ?? "")|\(visit)") {
            guard model.settings != nil else { return }
            guard model.isReady(.confluence), !(model.settings?.weeklyPageId ?? "").isEmpty else { state = .off; return }
            do { state = .ok(try await API.shared.weeklyLoad()) } catch { if !isCancellation(error) { state = .failed(errorMessage(error)) } }
        }
    }

    @ViewBuilder
    private func status(_ view: WeeklyView) -> some View {
        if !view.currentWeekExists {
            Notice(text: "本周（\(view.currentWeekTitle)）的小节还没有创建。")
        } else if let entry = view.entry, entry.rowFound {
            let filled = !entry.content.isEmpty
            HStack(spacing: 12) {
                Image(systemName: filled ? "checkmark.circle.fill" : "clock").font(.title).foregroundStyle(filled ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filled ? "已填写" : "未填写").font(.title3.weight(.semibold))
                    Text("\(entry.sectionTitle) · \(filled ? "\(entry.content.filter { $0.level == 0 }.count) 个分组，\(entry.content.count) 条" : "可以从 Jira 和 GitLab 生成草稿")")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } else {
            Notice(text: "本周小节中没有找到「\(view.personName)」的行。")
        }
    }
}

// MARK: - 我的未解决问题

struct MyIssuesCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var state: Loadable<SearchResult> = .loading
    @State private var issueMenu = IssueMenu()

    var body: some View {
        let reminders = model.reminders?.items ?? []
        let rank = Dictionary(reminders.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        let dueCount = reminders.filter { $0.kind != "stale" }.count
        Card(title: "我的未解决问题", count: state.value?.total, actions: {
            if dueCount > 0 { Chip(text: "\(dueCount) 个快到期或已逾期", tint: .orange) }
            Button("全部") { model.navigate(.jira) }.buttonStyle(.borderless)
        }) {
            LoadableBody(state: state, offLabel: "Jira") { data in
                if data.issues.isEmpty {
                    Text("没有未解决的问题").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        // 需要提醒的问题排在前面
                        ForEach(data.issues.sorted { (rank[$0.key] ?? .max) < (rank[$1.key] ?? .max) }.prefix(8)) { i in
                            HomeRow(action: { model.navigate(NavTarget(.jira, issueKey: i.key)) }) {
                                SysImage(service: .jira, src: i.issueType.iconUrl, size: 16)
                                Text(i.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                                Text(i.summary).lineLimit(1)
                                Spacer(minLength: 8)
                                if let r = reminders.first(where: { $0.key == i.key }) { Chip(text: AppModel.reminderLabel(r.kind, r.days), tint: r.kind == "overdue" ? .red : .orange) }
                                StatusPill(status: i.status)
                                Text(Fmt.time(i.updated)).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            }
                            .contextMenu(specs: { issueMenu.specs(.summary(i)) { detail in patch(detail.summaryValue) } })
                        }
                    }
                }
            }
        }
        .issueMenuDialogs(issueMenu)
        .task(id: "\(model.isReady(.jira))|\(visit)") { await load() }
        .onEvent(Events.local.jiraActivity) { _ in Task { await load() } }
    }

    private func load() async {
        guard model.settings != nil else { return }
        guard model.isReady(.jira) else { state = .off; return }
        if let cached = try? await API.shared.jiraCachedSearch(JQL.myUnresolved), state.value == nil { state = .ok(cached) }
        do {
            let r = try await API.shared.jiraSearch(JQL.myUnresolved)
            state = .ok(r)
            model.issueCount = r.total
        } catch { if !isCancellation(error) { if state.value == nil { state = .failed(errorMessage(error)) } } }
    }

    /// 通过右键菜单修改过的问题，覆盖列表中的旧数据
    private func patch(_ issue: IssueSummary) {
        guard var data = state.value, let i = data.issues.firstIndex(where: { $0.key == issue.key }) else { return }
        data.issues[i] = issue
        state = .ok(data)
    }
}

// MARK: - 工作记录

/// 今天的工作记录：最近几件事，可直接生成日报。
struct WorkLogCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var state: Loadable<WorkLog> = .loading
    @State private var report: String?

    var body: some View {
        let day = model.today
        Card(title: "今天的工作记录", count: (state.value?.events.isEmpty ?? true) ? nil : state.value?.events.count, actions: {
            Button("生成日报") { if let log = state.value { report = WorkLogText.report(log) } }.buttonStyle(.borderless).disabled(state.value == nil)
            Button("日记") { model.navigate(NavTarget(.notes, docId: "daily-\(day)")) }.buttonStyle(.borderless)
        }) {
            LoadableBody(state: state, offLabel: "") { log in
                if log.events.isEmpty {
                    Text("今天还没有记录。Jira 上的流转和评论、代码推送、Wiki 编辑、完成的待办会自动出现在这里。").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(WorkLogText.timeline(log.events).suffix(6).reversed().enumerated()), id: \.offset) { _, row in
                            let target = WorkLogText.target(row.first)
                            HomeRow(action: target.map { t in { model.navigate(t) } }) {
                                Text(WorkLogText.clock(row.at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: WorkLogText.icon(row.first.system)).font(.caption).foregroundStyle(.secondary)
                                Text(row.text).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(visit)|\(day)") { await load(day) }
        // 完成待办等本机操作也会记进工作记录
        .onWorkspaceChange { Task { await load(day) } }
        .sheet(item: Binding(get: { report.map { ReportText(text: $0) } }, set: { report = $0?.text })) { r in
            ReportSheet(day: day, text: r.text)
        }
    }

    private func load(_ day: String) async {
        do { state = .ok(try await API.shared.wsWorklog(day)) } catch { if !isCancellation(error) { state = .failed(errorMessage(error)) } }
    }
}

struct ReportText: Identifiable {
    var text: String
    var id: String { text }
}

/// 日报：可以先修改再复制。
struct ReportSheet: View {
    var day: String
    @State var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("日报 · \(day)").font(.headline)
            TextEditor(text: $text).font(.body).frame(minHeight: 320).padding(4).fieldBackground()
            HStack {
                Text("可以先修改再复制").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("复制", systemImage: "doc.on.doc") {
                    Pasteboard.copy(text)
                    toast("日报已复制")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - 最近的 Wiki、项目

struct WikiRecentCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var state: Loadable<[WikiRecent]> = .loading

    var body: some View {
        Card(title: "最近查看的 Wiki", actions: { Button("全部") { model.navigate(.wiki) }.buttonStyle(.borderless) }) {
            LoadableBody(state: state, offLabel: "Wiki") { list in
                if list.isEmpty {
                    Text("还没有查看过 Wiki 页面").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(list.prefix(6)) { p in
                            HomeRow(action: { model.navigate(NavTarget(.wiki, wikiPage: p.id)) }) {
                                Text(p.title).lineLimit(1)
                                Text(p.space).font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                Text(Fmt.time(ms: p.at)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(model.isReady(.confluence))|\(visit)") {
            guard model.settings != nil else { return }
            guard model.isReady(.confluence) else { state = .off; return }
            do { state = .ok(try await API.shared.wikiRecent(limit: 8)) } catch { if !isCancellation(error) { state = .failed(errorMessage(error)) } }
        }
    }
}

struct ProjectsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var state: Loadable<[Project]> = .loading

    var body: some View {
        Card(title: "最近活跃的项目", actions: { Button("全部") { model.navigate(.gitlab) }.buttonStyle(.borderless) }) {
            LoadableBody(state: state, offLabel: "GitLab") { list in
                VStack(spacing: 2) {
                    ForEach(list.prefix(6)) { p in
                        HomeRow(action: { model.navigate(NavTarget(.gitlab, projectId: p.id)) }) {
                            Text(p.name).fontWeight(.medium).lineLimit(1)
                            Text(p.pathWithNamespace).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Fmt.time(p.lastActivityAt)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: "\(model.isReady(.gitlab))|\(visit)") {
            guard model.settings != nil else { return }
            guard model.isReady(.gitlab) else { state = .off; return }
            if let cached = try? await API.shared.glCachedProjects() { state = .ok(cached) }
            do { state = .ok(try await API.shared.glProjects()) } catch { if !isCancellation(error) { if state.value == nil { state = .failed(errorMessage(error)) } } }
        }
    }
}
