import SwiftUI

/// Jira：常用查询 / 搜索 / JQL 的问题列表，右侧为问题详情。
struct JiraPage: View {
    enum Mode: String { case mine, reported, recent, search, jql }
    enum Source: String { case local, jira }

    struct ListView: Codable, Equatable {
        var sort = "default"
        /// none / status / project / priority / assignee
        var group = "none"
        /// 每条问题下额外显示的字段
        var fields: [FieldInfo] = []
    }

    static let pageSize = 100
    /// 最多额外显示的字段数。
    static let maxFields = 5
    private static let viewKey = "nextworkzone.jira.view"
    private static let sourceKey = "nextworkzone.jira.searchSource"
    static let groups: [(String, String)] = [("none", "不分组"), ("status", "按状态"), ("project", "按项目"), ("priority", "按优先级"), ("assignee", "按经办人")]

    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var active: Bool { pageState.active }
    private var visit: Int { pageState.visit }
    @State private var mode: Mode = .mine
    @State private var query: (jql: String, label: String?) = (JQL.presets[0].jql, nil)
    @State private var customJql = ""
    @State private var form = JQL.SearchForm()
    @State private var view = JiraPage.loadView()
    @State private var source: Source = AppPreferences.shared.string(forKey: JiraPage.sourceKey) == "jira" ? .jira : .local
    @State private var indexStore = IndexStatusStore.shared
    @State private var viewedStore = ViewedStore.shared
    /// 本机搜索的结果（含匹配处的摘要）；不是本机搜索时为 nil
    @State private var hits: [String: IssueHit]?
    @State private var issues: [IssueSummary]?
    @State private var total = 0
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var filter = ""
    @State private var selected: String?
    /// 菜单操作修改了问题后递增，让详情原地重新加载
    @State private var detailVersion = 0
    @State private var collapsed: Set<String> = []
    @State private var creating = false
    @State private var createWarning: String?
    @State private var filters: [JiraFilter] = []
    @State private var saved = JQL.savedQueries()
    @State private var savingQuery = false
    @State private var managing = false
    @State private var choosingFields = false
    @State private var requestId = 0
    @State private var issueMenu = IssueMenu()
    @State private var searchDebounce = Debouncer()

    static func loadView() -> ListView {
        guard let data = AppPreferences.shared.data(forKey: viewKey), let v = try? JSONDecoder().decode(ListView.self, from: data) else { return ListView() }
        return v
    }

    private var jql: String { JQL.withOrder(query.jql, sort: view.sort) }
    private var fieldIds: [String] { view.fields.map(\.id) }
    /// 本机问题库还没有数据时只能用 Jira 搜索
    private var localSearch: Bool { mode == .search && source == .local && (indexStore.status?.count ?? 0) > 0 }
    private var loadKey: String { "\(jql)|\(fieldIds.joined(separator: ","))|\(localSearch)|\(model.isReady(.jira))" }

    var body: some View {
        Group {
            if model.settings == nil {
                LoadingView()
            } else if !model.isReady(.jira) {
                NotConfigured(label: "Jira")
            } else {
                SplitPane("jira", minWidth: 340, idealWidth: 420, maxWidth: 620) {
                    listPane
                } trailing: {
                    detailPane
                }
                .pageToolbar { toolbar }
                .pageCommands {
                    let issue = issues?.first { $0.key == selected }
                    return PageCommands(
                        title: "问题",
                        newItem: ("新建问题…", { creating = true }),
                        refresh: { Task { await load() } },
                        specs: issue.map { issueMenu.specs(.summary($0), onUpdated: menuUpdated) } ?? []
                    )
                }
            }
        }
        .issueMenuDialogs(issueMenu)
        .onAppear {
            indexStore.start()
            takeTarget()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.navigated)) { _ in takeTarget() }
        .task(id: model.isReady(.jira)) {
            if model.isReady(.jira) { filters = (try? await API.shared.jiraFavouriteFilters()) ?? [] }
        }
        .task(id: loadKey) {
            guard model.isReady(.jira), !localSearch else { return }
            hits = nil
            await load()
        }
        // 回到 Jira 页面或回到应用时刷新
        .onChange(of: visit) { refreshInPlace() }
        // 有了新的 Jira 动态：正在显示的列表也要更新
        .onEvent(Events.local.jiraActivity) { _ in if active { refreshInPlace() } }
        .onChange(of: form) { searchLocal() }
        .onChange(of: localSearch) { searchLocal() }
        .onChange(of: indexStore.status?.lastSync) { searchLocal() }
        .onChange(of: view) { AppPreferences.shared.set(try? JSONEncoder().encode(view), forKey: Self.viewKey) }
        .sheet(isPresented: $creating) {
            CreateIssueSheet { key in
                selected = key
                Task { await load() }
            }
        }
        .sheet(isPresented: $savingQuery) {
            SaveQuerySheet(jql: query.jql, initialName: query.label ?? "") { name in
                updateSaved(saved.filter { $0.name != name } + [JQL.SavedQuery(name: name, jql: query.jql)])
                query.label = name
                toast("已保存“\(name)”")
            }
        }
        .sheet(isPresented: $managing) { ManageQueriesSheet(saved: $saved) }
        .sheet(isPresented: $choosingFields) {
            FieldChooserSheet(selected: Binding(get: { view.fields }, set: { fields in
                // 去掉的字段如果正用于排序，改回默认排序
                if view.sort.hasPrefix("field:") && !fields.contains(where: { view.sort.hasPrefix("field:\($0.id):") }) { view.sort = "default" }
                view.fields = fields
            }))
        }
    }

    private func takeTarget() {
        guard let t = model.take(.jira) else { return }
        if let key = t.issueKey { selected = key }
        if let j = t.jql {
            mode = .jql
            customJql = j
            query = (j, nil)
        }
    }

    // MARK: 加载

    private func load() async {
        requestId += 1
        let id = requestId
        error = nil
        loading = true
        let cached = (try? await API.shared.jiraCachedSearch(jql, fields: fieldIds)) ?? nil
        if id == requestId, let cached {
            issues = cached.issues
            total = cached.total
        }
        do {
            let result = try await API.shared.jiraSearch(jql, startAt: 0, maxResults: Self.pageSize, fields: fieldIds)
            guard id == requestId else { return }
            issues = result.issues
            total = result.total
            // 侧栏的问题数跟着最新结果走，不必等下一轮轮询
            if query.jql == JQL.myUnresolved { model.issueCount = result.total }
        } catch {
            guard !isCancellation(error) else { return }
            if id == requestId {
                self.error = errorMessage(error)
                if cached == nil { issues = [] }
            }
        }
        if id == requestId { loading = false }
        viewedStore.load(issues?.map(\.key) ?? [])
        selectFirst()
    }

    /// 在原地刷新列表（本机搜索的结果不需要）；加载过更多时不刷新，免得列表变短。
    private func refreshInPlace() {
        if model.isReady(.jira) && !localSearch && (issues?.count ?? 0) <= Self.pageSize { Task { await load() } }
    }

    /// 本机搜索：输入时即时搜索。
    private func searchLocal() {
        guard localSearch, JQL.search(form) != nil else { return }
        requestId += 1
        let id = requestId
        let f = form
        searchDebounce.run(after: .milliseconds(120)) {
            error = nil
            do {
                let list = try await API.shared.jiraIndexSearch(IndexQuery(text: f.text, project: f.project, state: f.state, mine: f.who == "me", limit: 200))
                guard id == requestId else { return }
                hits = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                issues = list.map(\.summaryValue)
                total = list.count
                loading = false
                viewedStore.load(list.map(\.key))
                selectFirst()
            } catch {
                guard !isCancellation(error) else { return }
                if id == requestId { self.error = errorMessage(error) }
            }
        }
    }

    private func loadMore() {
        guard let current = issues else { return }
        let id = requestId
        loadingMore = true
        Task {
            do {
                let result = try await API.shared.jiraSearch(jql, startAt: current.count, maxResults: Self.pageSize, fields: fieldIds)
                guard id == requestId else { return }
                let known = Set(current.map(\.key))
                issues = current + result.issues.filter { !known.contains($0.key) }
                total = result.total
                viewedStore.load(result.issues.map(\.key))
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
            }
            loadingMore = false
        }
    }

    /// 列表变化后若尚未选中任何问题，默认选中第一条。
    private func selectFirst() {
        if selected == nil, let first = visible.first { selected = first.key }
    }

    private var visible: [IssueSummary] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard let issues else { return [] }
        if q.isEmpty { return issues }
        return issues.filter { "\($0.key) \($0.summary) \($0.project.name) \($0.status.name) \($0.assignee ?? "")".lowercased().contains(q) }
    }

    private func groupOf(_ issue: IssueSummary) -> String {
        switch view.group {
        case "status": issue.status.name
        case "project": issue.project.name
        case "priority": issue.priority?.name ?? "无优先级"
        case "assignee": issue.assignee ?? "未分配"
        default: ""
        }
    }

    private var grouped: [(name: String, issues: [IssueSummary])] {
        if view.group == "none" { return [("", visible)] }
        var order: [String] = []
        var map: [String: [IssueSummary]] = [:]
        for issue in visible {
            let g = groupOf(issue)
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(issue)
        }
        return order.map { ($0, map[$0]!) }
    }

    private func onIssueChanged(_ updated: IssueSummary) {
        guard var list = issues, let i = list.firstIndex(where: { $0.key == updated.key }) else { return }
        // 只列未解决问题时，刚解决的问题立即移出列表（右侧详情保持不变）
        if updated.resolution != nil, query.jql.contains(/(?i)resolution\s*=\s*unresolved/) {
            list.remove(at: i)
            issues = list
            total = max(total - 1, list.count)
            return
        }
        var u = updated
        u.extra = list[i].extra
        list[i] = u
        issues = list
        // 只列分配给我的问题时，分配给别人后同样移出
        if query.jql.contains(/(?i)assignee\s*=\s*currentUser\(\)/) {
            Task {
                guard let me = try? await API.shared.jiraMe(), updated.assigneeName != me, var list = issues, let i = list.firstIndex(where: { $0.key == updated.key }) else { return }
                list.remove(at: i)
                issues = list
                total = max(total - 1, list.count)
            }
        }
    }

    private func menuUpdated(_ detail: IssueDetail) {
        onIssueChanged(detail.summaryValue)
        model.issueChanged()
        Task { await viewedStore.markViewed(key: detail.key, updated: detail.updated) }
        if detail.key == selected { detailVersion += 1 }
    }

    // MARK: 模式

    private func chooseMode(_ next: Mode) {
        mode = next
        if let preset = JQL.presets.first(where: { $0.id == next.rawValue }) { query = (preset.jql, nil) }
        if next == .search, let built = JQL.search(form) { query = (built, nil) }
        // 切换到 JQL 时带上当前查询，方便在此基础上修改
        if next == .jql && customJql.trimmingCharacters(in: .whitespaces).isEmpty { customJql = query.jql }
    }

    private func runQuery(_ jql: String, label: String?) {
        mode = .jql
        customJql = jql
        query = (jql, label)
    }

    private func updateSaved(_ list: [JQL.SavedQuery]) {
        saved = list
        JQL.storeSavedQueries(list)
    }

    private func savedMenu() -> [MenuSpec] {
        var specs: [MenuSpec] = []
        if !filters.isEmpty {
            specs.append(.label("Jira 收藏的过滤器"))
            specs += filters.map { f in .action(f.name, checked: query.jql == f.jql) { runQuery(f.jql, label: f.name) } }
            specs.append(.separator)
        }
        if !saved.isEmpty {
            specs.append(.label("本机保存的查询"))
            specs += saved.map { q in .action(q.name, checked: query.jql == q.jql) { runQuery(q.jql, label: q.name) } }
            specs.append(.separator)
        }
        specs.append(.action("保存当前查询…", icon: "plus") { savingQuery = true })
        if !saved.isEmpty { specs.append(.action("管理保存的查询…") { managing = true }) }
        return specs
    }

    private func viewMenu() -> [MenuSpec] {
        func sortItem(_ id: String, _ label: String) -> MenuSpec { .action(label, checked: view.sort == id) { view.sort = id } }
        var sorts = JQL.sorts.map { s in sortItem(s.id, s.id == "default" ? (mode == .search && !form.text.trimmingCharacters(in: .whitespaces).isEmpty ? "按相关度" : "默认") : s.label) }
        // 额外显示的字段也可以用来排序（例如按截止日期从早到晚）
        if !view.fields.isEmpty { sorts.append(.separator) }
        for f in view.fields {
            sorts.append(sortItem(JQL.fieldSort(f.id, "asc"), "\(f.name) ↑"))
            sorts.append(sortItem(JQL.fieldSort(f.id, "desc"), "\(f.name) ↓"))
        }
        return [
            .submenu("排序", children: sorts),
            .submenu("分组", children: Self.groups.map { g in .action(g.1, checked: view.group == g.0) { view.group = g.0 } }),
            .separator,
            .action(view.fields.isEmpty ? "显示更多字段…" : "显示字段（\(view.fields.count)）…") { choosingFields = true },
        ]
    }

    // MARK: 工具栏

    /// 列表的操作在左侧：切换查询方式、常用查询、排序分组、刷新；新建在最右侧（问题的操作由 IssueView 放在它前面）。
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("查询方式", selection: Binding(get: { mode }, set: { chooseMode($0) })) {
                ForEach(JQL.presets, id: \.id) { p in Text(p.label).tag(Mode(rawValue: p.id)!) }
                Text("搜索").tag(Mode.search)
                Text("JQL").tag(Mode.jql)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .navigation) {
            Button("常用查询", systemImage: "bookmark") { MenuBuilder.popUp(savedMenu()) }.help("常用查询")
            Button("排序与分组", systemImage: view.sort != "default" || view.group != "none" ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") { MenuBuilder.popUp(viewMenu()) }
                .help("排序与分组")
            Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }.refreshing(loading).disabled(loading).help("刷新")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("新建问题", systemImage: "plus") { creating = true }.help("新建问题")
        }
    }

    /// 筛选框右侧的说明：常用查询的名称和条数（只加载了一部分、本机搜索时说明；筛选时为筛出的条数）。
    /// 窗口不显示 Jira 页面的标题（侧栏已经标明），条数放在列表上方。
    private var listSummary: String {
        guard let issues, !(mode == .search && JQL.search(form) == nil) else { return "" }
        if !filter.trimmingCharacters(in: .whitespaces).isEmpty { return "\(visible.count) / \(issues.count) 条" }
        let count = localSearch ? "本机问题库中找到 \(total >= 200 ? "200+" : "\(total)") 条"
            : total > issues.count ? "共 \(total) 条，已显示 \(issues.count) 条" : "\(total) 条"
        return [query.label, count].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: 列表

    /// 搜索条件、筛选框贴在列表顶上：列表滚到它们下面时渐隐。
    private var listPane: some View {
        Group {
            if mode == .search && JQL.search(form) == nil {
                Text("输入关键词搜索问题，例如报错信息、功能名称，多个关键词用空格分开。可以限定项目、只看已解决的，找同事处理过的类似问题。" + (source == .local && (indexStore.status?.count ?? 0) > 0 ? " 本机问题库会同时搜索描述和评论，输入即出结果。" : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                issueList
            }
        }
        .listHeader { listControls }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var listControls: some View {
        if mode == .search {
            SearchPanel(form: $form, source: Binding(get: { source }, set: { source = $0; AppPreferences.shared.set($0.rawValue, forKey: Self.sourceKey) }), index: indexStore.status) { f in
                if let built = JQL.search(f) { query = (built, nil) }
            }
        }
        if mode == .jql {
            TextField("输入 JQL，回车查询", text: $customJql)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .onSubmit {
                    let j = customJql.trimmingCharacters(in: .whitespaces)
                    if !j.isEmpty { query = (j, nil) }
                }
        }
        FilterField(prompt: "筛选当前列表", text: $filter, trailing: listSummary)
        if let error { ErrorBox(message: error) { Task { await load() } } }
        if let createWarning { ErrorBox(message: createWarning) }
    }

    private var issueList: some View {
        let multiProject = Set((issues ?? []).map(\.project.name)).count > 1
        let reminders = Dictionary((model.reminders?.items ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return List(selection: $selected) {
            ForEach(grouped, id: \.name) { g in
                if g.name.isEmpty {
                    rows(g.issues, multiProject: multiProject, reminders: reminders)
                } else {
                    Section(isExpanded: Binding(get: { !collapsed.contains(g.name) }, set: { open in if open { collapsed.remove(g.name) } else { collapsed.insert(g.name) } })) {
                        rows(g.issues, multiProject: multiProject, reminders: reminders)
                    } header: {
                        HStack {
                            Text(g.name)
                            Text("\(g.issues.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if issues != nil, visible.isEmpty { Text("没有匹配的问题").foregroundStyle(.secondary) }
            if let issues, total > issues.count, filter.isEmpty {
                Button(loadingMore ? "加载中…" : "加载更多（还有 \(total - issues.count) 条）", action: loadMore)
                    .disabled(loadingMore)
                    .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.inset)
        .overlay { if issues == nil && error == nil { ProgressView() } }
        .copyLinks { (issues ?? []).filter { $0.key == selected }.map(WorkLink.issue) }
        // 双击在新窗口中打开（右键菜单仍是各行自己的菜单）
        .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() }, primaryAction: { keys in
            if let key = keys.first { DetailWindows.open(.issue(key)) }
        })
    }

    @ViewBuilder
    private func rows(_ list: [IssueSummary], multiProject: Bool, reminders: [String: Reminder]) -> some View {
        ForEach(list) { issue in
            IssueRow(issue: issue, hit: hits?[issue.key], query: hits != nil ? form.text : "", fields: view.fields, multiProject: multiProject, reminder: reminders[issue.key], unseen: viewedStore.isUnseen(issue), showReporter: mode == .mine)
                .tag(issue.key)
                .draggable(WorkLink.issue(issue))
                .contextMenu(specs: { issueMenu.specs(.summary(issue), onUpdated: menuUpdated) })
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            IssueView(issueKey: selected, version: detailVersion, onChanged: onIssueChanged)
                .id(selected)
        } else {
            Text("选择左侧的问题查看详情").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 列表中的一条问题。
private struct IssueRow: View {
    var issue: IssueSummary
    var hit: IssueHit?
    var query: String
    var fields: [FieldInfo]
    var multiProject: Bool
    var reminder: Reminder?
    var unseen: Bool
    /// 自己的未解决问题经办人都是自己，显示报告人更有用
    var showReporter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if unseen { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("上次查看之后有新变化").accessibilityLabel("有新变化") }
                SysImage(service: .jira, src: issue.issueType.iconUrl, size: 16, fallback: "ticket")
                Text(issue.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                if issue.resolution == nil, let r = reminder { Chip(text: AppModel.reminderLabel(r.kind, r.days), tint: r.kind == "overdue" || r.kind == "today" ? .red : .orange) }
                if let res = issue.resolution, issue.status.category == "done" { Text(res).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                StatusPill(status: issue.status)
            }
            Text(query.isEmpty ? AttributedString(issue.summary) : highlighted(issue.summary, query)).lineLimit(2)
            if let s = hit?.snippet {
                (Text(s.source == "comment" ? "\(s.author ?? "")：" : "描述：").foregroundStyle(.secondary) + Text(highlighted(s.text, query)))
                    .font(.caption)
                    .lineLimit(2)
            }
            // 最后一行：额外字段或所属项目，然后是更新时间和人
            HStack(spacing: 8) {
                let extras = fields.filter { !(issue.extra?[$0.id] ?? "").isEmpty }
                if !extras.isEmpty {
                    extras.reduce(Text("")) { acc, f in
                        let v = issue.extra![f.id]!
                        return acc + Text(f.name + " ").foregroundStyle(.secondary) + Text((f.kind == "datetime" ? Fmt.time(v) : v) + "  ")
                    }
                    .lineLimit(1)
                    .help(extras.map { "\($0.name)：\(issue.extra![$0.id]!)" }.joined(separator: "\n"))
                } else if multiProject {
                    Text(issue.project.name).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Fmt.time(issue.updated))
                let person = showReporter ? issue.reporter : issue.assignee
                if let person {
                    HStack(spacing: 3) {
                        Avatar(name: person, size: 16)
                        if !showReporter { Text(person) }
                    }
                    .help(showReporter ? "报告人：\(person)" : "经办人：\(person)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        // 读屏时整行作为一项：问题键、概要、状态、时间和人
        .accessibilityElement(children: .combine)
    }
}

/// 关键词搜索：关键词、项目、解决状态、是否我经办过；可选本机问题库或 Jira。
private struct SearchPanel: View {
    @Binding var form: JQL.SearchForm
    @Binding var source: JiraPage.Source
    var index: IndexStatus?
    var onSearch: (JQL.SearchForm) -> Void
    @State private var draft = JQL.SearchForm()
    @State private var jiraProjects: [CreateProject] = []
    @FocusState private var focused: Bool

    private var local: Bool { source == .local && (index?.count ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FilterField(prompt: "关键词或问题键，回车搜索", text: Binding(get: { draft.text }, set: { change { $0.text = $1 }($0, true) }), focus: $focused) { form = draft; onSearch(draft) }
            HStack {
                Picker("", selection: Binding(get: { draft.project }, set: { change { $0.project = $1 }($0, false) })) {
                    Text("全部项目").tag("")
                    if local {
                        ForEach(index?.projects ?? []) { p in Text(p.name).tag(p.key) }
                    } else {
                        ForEach(jiraProjects) { p in Text(p.name).tag(p.key) }
                    }
                }
                .help("项目")
                Picker("", selection: Binding(get: { draft.state }, set: { change { $0.state = $1 }($0, false) })) {
                    Text("全部状态").tag("all")
                    Text("未解决").tag("unresolved")
                    Text("已解决").tag("resolved")
                }
                .help("解决状态")
                Picker("", selection: Binding(get: { draft.who }, set: { change { $0.who = $1 }($0, false) })) {
                    Text("所有人").tag("anyone")
                    Text(local ? "我参与过的" : "我经办过的").tag("me")
                }
                .help("经办人")
                Picker("", selection: $source) {
                    Text("本机").tag(JiraPage.Source.local).disabled(index?.enabled != true)
                    Text("Jira").tag(JiraPage.Source.jira)
                }
                .help(index.map { $0.count > 0 ? "本机问题库有 \($0.count) 个问题" : "搜索范围" } ?? "搜索范围")
            }
            .labelsHidden()
            .controlSize(.small)
            if source == .local, let index, index.enabled, index.count == 0 {
                Text(index.running ? "本机问题库正在建立\(index.progress.map { "（\($0.scope) \($0.done)/\($0.total)）" } ?? "")，暂时使用 Jira 搜索。" : "本机问题库还没有数据，暂时使用 Jira 搜索。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            draft = form
            focused = true
        }
        .task {
            if let cached = try? await API.shared.jiraCachedCreateProjects() { jiraProjects = cached }
            if let fresh = try? await API.shared.jiraCreateProjects() { jiraProjects = fresh }
        }
    }

    /// 下拉选项修改后立即搜索；关键词在本机搜索时即时搜索，Jira 搜索时回车搜索。
    private func change<V>(_ patch: @escaping (inout JQL.SearchForm, V) -> Void) -> (V, Bool) -> Void {
        { value, isText in
            patch(&draft, value)
            if !isText || local {
                form = draft
                onSearch(draft)
            }
        }
    }
}

/// 选择列表中额外显示的字段（最多 5 个）。
private struct FieldChooserSheet: View {
    @Binding var selected: [FieldInfo]
    @Environment(\.dismiss) private var dismiss
    @State private var all: [FieldInfo]?
    @State private var error: String?
    @State private var filter = ""

    private static let kindNames = ["date": "日期", "datetime": "时间", "array": "多选", "user": "用户", "string": "文本", "number": "数字", "option": "单选", "priority": "优先级", "version": "版本"]
    /// 列表本身已显示的字段不再提供
    private static let shown: Set<String> = ["summary", "status", "issuetype", "project", "updated", "assignee", "reporter", "resolution", "issuekey", "thumbnail"]

    var body: some View {
        let q = filter.lowercased()
        let candidates = (all ?? []).filter { f in !Self.shown.contains(f.id) && !selected.contains(where: { $0.id == f.id }) && (q.isEmpty || f.name.lowercased().contains(q) || f.id.contains(q)) }
        let full = selected.count >= JiraPage.maxFields
        VStack(alignment: .leading, spacing: 10) {
            Text("列表显示的字段").font(.headline)
            Text("选中的字段显示在每条问题的概要下方，也可以在“排序”中按这些字段排序。最多 \(JiraPage.maxFields) 个。").font(.callout).foregroundStyle(.secondary)
            if !selected.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selected) { f in
                        HStack(spacing: 3) {
                            Text(f.name)
                            Button { selected.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).accessibilityLabel("移除字段 \(f.name)")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3).chipBackground()
                    }
                }
            }
            FilterField(prompt: "搜索字段名称", text: $filter)
            if let error { ErrorBox(message: error) }
            List(candidates.prefix(200)) { f in
                Button {
                    selected.append(f)
                } label: {
                    HStack {
                        Text(f.name)
                        Spacer()
                        Text("\(f.custom ? "自定义" : "系统") · \(Self.kindNames[f.kind] ?? f.kind)").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(full)
                .help(full ? "最多选择 \(JiraPage.maxFields) 个字段" : f.id)
            }
            .frame(height: 320)
            .overlay { if all == nil && error == nil { ProgressView() } }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            // 先显示缓存，再取最新的字段列表（Jira 中可能新增了字段）
            all = try? await API.shared.jiraFields()
            do { all = try await API.shared.jiraFields(refresh: true) } catch { if !isCancellation(error) { if all == nil { self.error = errorMessage(error) } } }
        }
    }
}

private struct SaveQuerySheet: View {
    var jql: String
    var initialName: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("保存当前查询").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            Text("JQL").font(.callout).foregroundStyle(.secondary)
            Text(jql).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading).fieldBackground()
            Text("保存在本机，点击工具栏的书签按钮即可使用。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { name = initialName }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onSave(n)
        dismiss()
    }
}

private struct ManageQueriesSheet: View {
    @Binding var saved: [JQL.SavedQuery]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("保存的查询").font(.headline)
            if saved.isEmpty { Text("没有保存的查询").foregroundStyle(.secondary) }
            List {
                ForEach(Array(saved.enumerated()), id: \.element.name) { i, q in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(q.name)
                            Text(q.jql).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("上移") { update { $0.swapAt(i, i - 1) } }.disabled(i == 0)
                        Button("删除", role: .destructive) { update { $0.remove(at: i) } }
                    }
                }
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func update(_ change: (inout [JQL.SavedQuery]) -> Void) {
        change(&saved)
        JQL.storeSavedQueries(saved)
    }
}
