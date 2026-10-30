import SwiftUI

/// 待办：今天 / 未安排 / 计划 / 全部 / 已完成，右侧编辑详情。
struct TodoPage: View {
    enum ViewKind: String, CaseIterable, Identifiable {
        case today, unscheduled, upcoming, all, done
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: "今天"
            case .unscheduled: "未安排"
            case .upcoming: "计划"
            case .all: "全部"
            case .done: "已完成"
            }
        }
        var empty: String {
            switch self {
            case .today: "今天没有到期的待办"
            case .unscheduled: "没有未安排日期的待办"
            case .upcoming: "没有计划中的待办"
            case .all: "没有未完成的待办"
            case .done: "还没有完成的待办"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var active: Bool { pageState.active }
    @State private var todos: [Todo]?
    @State private var error: String?
    @State private var view: ViewKind = .today
    @State private var selected: String?
    @State private var syncNote: String?
    @State private var promoting: Todo?
    @State private var newTitle = ""
    @FocusState private var newFocused: Bool

    private var day: String { Fmt.today() }

    static func inView(_ todo: Todo, _ view: ViewKind, _ day: String) -> Bool {
        if view == .done { return todo.done }
        if todo.done { return false }
        switch view {
        case .today: return todo.due.map { $0 <= day } ?? false
        case .unscheduled: return todo.due == nil
        case .upcoming: return todo.due.map { $0 > day } ?? false
        default: return true
        }
    }

    /// 列表排序：完成的按完成时间倒序；未完成的按截止日期、优先级、手动顺序。
    static func ordered(_ a: Todo, _ b: Todo, _ view: ViewKind) -> Bool {
        if view == .done { return (a.completedAt ?? 0) > (b.completedAt ?? 0) }
        if view == .upcoming || view == .today, a.due != b.due { return (a.due ?? "") < (b.due ?? "") }
        if a.priority != b.priority { return a.priority > b.priority }
        if a.sort != b.sort { return a.sort < b.sort }
        return a.createdAt < b.createdAt
    }

    private var visible: [Todo] {
        (todos ?? []).filter { Self.inView($0, view, day) }.sorted { Self.ordered($0, $1, view) }
    }

    private func count(_ v: ViewKind) -> Int { (todos ?? []).filter { Self.inView($0, v, day) }.count }

    var body: some View {
        SplitPane("todos", minWidth: 320, idealWidth: 400, maxWidth: 560, trailingMin: 420) {
            listPane
        } trailing: {
            detailPane
        }
        .pageToolbar {
            ToolbarItem(placement: .navigation) {
                Picker("视图", selection: $view) {
                    ForEach(ViewKind.allCases) { v in
                        let n = count(v)
                        Text(v != .done && n > 0 ? "\(v.label) \(n)" : v.label).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .pageCommands {
            let todo = todos?.first { $0.id == selected }
            return PageCommands(
                title: "待办",
                newItem: ("新建待办", { newFocused = true }),
                refresh: { Task { await load() } },
                specs: todo.map { TodoActions.menu($0, onSaved: replace, onDeleted: removeLocal, onPromote: model.isReady(.jira) ? { promoting = $0 } : nil) } ?? []
            )
        }
        .task {
            await load()
            // 打开页面时同步一次分配给我的 Jira 问题
            if let r = try? await API.shared.wsRefreshJiraTodos(), r.added + r.completed + r.reopened > 0 {
                syncNote = [r.added > 0 ? "新增 \(r.added) 个" : nil, r.completed > 0 ? "完成 \(r.completed) 个" : nil, r.reopened > 0 ? "恢复 \(r.reopened) 个" : nil].compactMap { $0 }.joined(separator: "、") + "来自 Jira 的待办"
                Events.workspaceChanged()
            }
        }
        .onWorkspaceChange { Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.navigated)) { _ in takeTarget() }
        .onAppear { takeTarget() }
        .sheet(item: $promoting) { todo in
            CreateIssueSheet(initialSummary: todo.title, initialDescription: todo.notes) { key in
                guarded { replace(try await TodoActions.save(todo) { $0.refSystem = "jira"; $0.refKey = key; $0.refTitle = todo.title }) }
            }
        }
    }

    private func takeTarget() {
        if let t = model.take(.todos), let id = t.todoId { selected = id }
    }

    private func load() async {
        do {
            todos = try await API.shared.wsTodos()
            error = nil
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
    }

    private func replace(_ todo: Todo) {
        if var list = todos {
            if let i = list.firstIndex(where: { $0.id == todo.id }) { list[i] = todo } else { list.insert(todo, at: 0) }
            todos = list
        }
        Events.workspaceChanged()
    }

    private func removeLocal(_ todo: Todo) {
        todos?.removeAll { $0.id == todo.id }
        if selected == todo.id { selected = nil }
    }

    // MARK: 列表

    private var listPane: some View {
        List(selection: $selected) {
            ForEach(visible) { todo in
                TodoRow(todo: todo, day: day, onToggle: { toggle(todo) }, onPlan: view == .unscheduled ? { due in plan(todo, due) } : nil)
                    .tag(todo.id)
                    .contextMenu(specs: { TodoActions.menu(todo, onSaved: replace, onDeleted: removeLocal, onPromote: model.isReady(.jira) ? { promoting = $0 } : nil) })
            }
            if todos != nil && visible.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(view.empty).foregroundStyle(.secondary)
                    if view == .today && count(.unscheduled) > 0 {
                        Button("从 \(count(.unscheduled)) 个未安排的待办中挑几个") { view = .unscheduled }.buttonStyle(.link)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.inset)
        .overlay { if todos == nil && error == nil { ProgressView() } }
        .listHeader(inset: 12) {
            HStack {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField(view == .today ? "添加今天的待办，回车保存" : "添加待办，回车保存", text: $newTitle)
                    .textFieldStyle(.plain)
                    .focused($newFocused)
                    .onSubmit(add)
            }
            .padding(8)
            .fieldBackground()
            if let syncNote {
                HStack {
                    Text(syncNote).font(.callout)
                    Spacer()
                    Button("关闭", systemImage: "xmark") { self.syncNote = nil }.labelStyle(.iconOnly).buttonStyle(.plain)
                }
                .padding(8)
                .noticeBackground(.green)
            }
            if let error { ErrorBox(message: error) { Task { await load() } } }
        }
        .padding(.top, 12)
    }

    private func add() {
        let text = newTitle.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // 在“今天”“计划”视图中添加的待办分别默认今天、明天到期
        let due: String? = view == .today ? Fmt.today() : view == .upcoming ? Fmt.addDays(Fmt.today(), 1) : nil
        guarded {
            let todo = try await API.shared.wsSaveTodo(TodoInput(title: text, due: .some(due)))
            replace(todo)
            selected = todo.id
            newTitle = ""
        }
    }

    private func toggle(_ todo: Todo) {
        guarded { replace(try await API.shared.wsSetTodoDone(todo.id, done: !todo.done)) }
    }

    /// 安排日期（“未安排”中的今天、明天）
    private func plan(_ todo: Todo, _ due: String) {
        guarded { replace(try await TodoActions.save(todo) { $0.due = due }) }
    }

    // MARK: 详情

    @ViewBuilder
    private var detailPane: some View {
        if let todo = todos?.first(where: { $0.id == selected }) {
            TodoDetail(todo: todo, onSaved: replace, onDeleted: { removeLocal(todo); Events.workspaceChanged() })
                .id(todo.id)
        } else {
            VStack(spacing: 6) {
                Text("选择左侧的待办查看详情").foregroundStyle(.secondary)
                Text("随时按 ⌘⇧N 快速记一条待办").font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 完成勾选框：颜色表示优先级。
struct CheckCircle: View {
    var done: Bool
    var priority: Int = 0
    var size: CGFloat = 18
    var action: () -> Void

    static func color(_ priority: Int) -> Color {
        switch priority {
        case 3: .red
        case 2: .orange
        case 1: .blue
        default: .secondary
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Self.color(priority), lineWidth: 1.5)
                if done {
                    Circle().fill(Color.accentColor)
                    Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(done ? "标记为未完成" : "标记为完成")
    }
}

/// 小标签（截止日期、提醒、关联问题等）。
struct Chip: View {
    var text: String
    var icon: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 10)) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.1), in: Capsule())
    }
}

private struct TodoRow: View {
    var todo: Todo
    var day: String
    var onToggle: () -> Void
    var onPlan: ((String) -> Void)?

    var body: some View {
        let overdue = !todo.done && (todo.due.map { $0 < day } ?? false)
        HStack(alignment: .top, spacing: 10) {
            CheckCircle(done: todo.done, priority: todo.priority, action: onToggle).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title.isEmpty ? "无标题" : todo.title)
                    .foregroundStyle(todo.title.isEmpty || todo.done ? .secondary : .primary)
                    .strikethrough(todo.done)
                    .lineLimit(2)
                let hasMeta = todo.due != nil || todo.refKey != nil || !todo.notes.isEmpty || todo.priority > 0 || todo.remindAt != nil || todo.repeat != nil || !todo.checklist.isEmpty
                if hasMeta {
                    HStack(spacing: 6) {
                        if let due = todo.due { Chip(text: Fmt.dayLabel(due), tint: overdue ? .red : due == day ? .accentColor : .secondary) }
                        if let remind = todo.remindAt, !todo.done { Chip(text: Fmt.moment(remind), icon: "bell", tint: remind < Fmt.nowMs() ? .red : .secondary) }
                        if let r = todo.repeat { Chip(text: Fmt.repeatLabels[r] ?? r, icon: "repeat") }
                        if !todo.checklist.isEmpty { Chip(text: "\(todo.checklist.filter(\.done).count)/\(todo.checklist.count)", icon: "checklist") }
                        if todo.priority > 0 { Chip(text: TodoActions.priorities[todo.priority], icon: "flag.fill", tint: CheckCircle.color(todo.priority)) }
                        if let key = todo.refKey {
                            if todo.refSystem == "wiki" { Chip(text: todo.refTitle ?? "Wiki 页面", icon: "text.book.closed") } else { Chip(text: key, icon: "smallcircle.filled.circle") }
                        }
                        if !todo.notes.isEmpty {
                            Text(todo.notes.components(separatedBy: "\n")[0]).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if let onPlan {
                HStack(spacing: 4) {
                    Button("今天") { onPlan(day) }
                    Button("明天") { onPlan(Fmt.addDays(day, 1)) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

/// 可以为空的日期选择。
struct OptionalDatePicker: View {
    @Binding var day: String?
    var components: DatePickerComponents = .date

    var body: some View {
        if let value = day, let date = Fmt.date(ofDay: value) {
            DatePicker("", selection: Binding(get: { date }, set: { day = Fmt.day($0) }), displayedComponents: components)
                .labelsHidden()
                .datePickerStyle(.field)
        } else {
            Button("设置日期") { day = Fmt.today() }
        }
    }
}

private struct TodoDetail: View {
    var todo: Todo
    var onSaved: (Todo) -> Void
    var onDeleted: () -> Void

    @Environment(AppModel.self) private var model
    @State private var draft: Todo
    @State private var error: String?
    @State private var promoting = false
    @State private var newCheck = ""
    @State private var debouncer = Debouncer()
    @State private var typing = false

    init(todo: Todo, onSaved: @escaping (Todo) -> Void, onDeleted: @escaping () -> Void) {
        self.todo = todo
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _draft = State(initialValue: todo)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    CheckCircle(done: draft.done, priority: draft.priority, size: 22) { update { $0.done.toggle() } }
                    TextField("待办标题", text: Binding(get: { draft.title }, set: { v in update(debounce: true) { $0.title = v } }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                }
                if draft.autoDone && draft.done {
                    Text("关联的 Jira 问题已解决或不再分配给你，已自动完成。").font(.callout).foregroundStyle(.secondary)
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("截止日期").foregroundStyle(.secondary)
                        HStack {
                            OptionalDatePicker(day: Binding(get: { draft.due }, set: { v in update { $0.due = v } }))
                            Button("今天") { update { $0.due = Fmt.today() } }
                            Button("明天") { update { $0.due = Fmt.addDays(Fmt.today(), 1) } }
                            Button("下周一") { update { $0.due = Fmt.nextMonday() } }
                            if draft.due != nil { Button("清除") { update { $0.due = nil } }.buttonStyle(.borderless) }
                        }
                        .controlSize(.small)
                    }
                    GridRow {
                        Text("优先级").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { draft.priority }, set: { v in update { $0.priority = v } })) {
                            ForEach(0..<4) { p in Text(TodoActions.priorities[p]).tag(p) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("提醒").foregroundStyle(.secondary)
                        HStack {
                            if let remind = draft.remindAt {
                                DatePicker("", selection: Binding(get: { Date(timeIntervalSince1970: Double(remind) / 1000) }, set: { d in update { $0.remindAt = Int64(d.timeIntervalSince1970 * 1000) } }), displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                                    .datePickerStyle(.field)
                            }
                            ForEach(Fmt.momentPresets(), id: \.label) { p in
                                Button(p.label) { update { $0.remindAt = p.at } }
                            }
                            if draft.remindAt != nil { Button("清除") { update { $0.remindAt = nil } }.buttonStyle(.borderless) }
                        }
                        .controlSize(.small)
                    }
                    GridRow {
                        Text("重复").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { draft.repeat ?? "" }, set: { v in
                            // 重复的待办需要一个起始日期，没有截止日期时从今天开始
                            update { $0.repeat = v.isEmpty ? nil : v; if !v.isEmpty && $0.due == nil { $0.due = Fmt.today() } }
                        })) {
                            Text("不重复").tag("")
                            ForEach(["daily", "weekdays", "weekly", "monthly"], id: \.self) { r in Text(Fmt.repeatLabels[r]!).tag(r) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if draft.refSystem == "wiki", let key = draft.refKey {
                        GridRow {
                            Text("Wiki 页面").foregroundStyle(.secondary)
                            HStack {
                                Button(draft.refTitle ?? key) { model.navigate(NavTarget(.wiki, wikiPage: key)) }.buttonStyle(.link)
                                if todo.source == "wiki" { Text("页面任务，勾选后同步到 Wiki").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    } else {
                        GridRow {
                            Text("关联问题").foregroundStyle(.secondary)
                            if draft.refSystem == "jira", let key = draft.refKey {
                                HStack {
                                    Button(key) { model.navigate(NavTarget(.jira, issueKey: key)) }.buttonStyle(.link)
                                    Text(draft.refTitle ?? "").lineLimit(1)
                                    Button("取消关联", systemImage: "xmark") { update { $0.refSystem = nil; $0.refKey = nil; $0.refTitle = nil } }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                }
                            } else if model.isReady(.jira) {
                                SearchPicker<IssueChoice>(
                                    selected: [],
                                    onChange: { list in if let c = list.first { update { $0.refSystem = "jira"; $0.refKey = c.key; $0.refTitle = c.summary } } },
                                    search: { q in q.isEmpty ? [] : try await API.shared.jiraPickIssues(q, projectKey: nil, standardOnly: false).map { IssueChoice(key: $0.key, summary: $0.summary) } },
                                    label: { $0.key },
                                    detail: { $0.summary },
                                    placeholder: "输入问题键或概要搜索 Jira 问题"
                                )
                            } else {
                                Text("配置 Jira 后可关联问题").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if draft.repeat != nil {
                    Text("完成后自动生成下一次\(draft.remindAt != nil ? "，提醒时间随之顺延" : "")。").font(.callout).foregroundStyle(.secondary)
                }

                checklist

                VStack(alignment: .leading, spacing: 6) {
                    Text("备注").foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { draft.notes }, set: { v in update(debounce: true) { $0.notes = v } }))
                        .font(.body)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .fieldBackground()
                }

                if let error { ErrorBox(message: error) }

                Text("创建于 \(Date(timeIntervalSince1970: Double(todo.createdAt) / 1000).formatted(date: .numeric, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .pageToolbar {
            // 待办的操作放在窗口工具栏右侧
            if draft.refKey == nil && model.isReady(.jira) {
                ToolbarItem {
                    Button("创建为 Jira 问题", systemImage: "smallcircle.filled.circle") { promoting = true }.help("创建为 Jira 问题")
                }
            }
            ToolbarItem {
                Button(draft.refSystem == "jira" ? "删除待办" : "删除", systemImage: "trash", role: .destructive) {
                    let note = draft.refSystem == "jira" ? (TodoActions.fromJiraSync(todo) ? "只删除待办，不影响 Jira 问题，之后也不会再自动添加。" : "只删除待办，不影响 Jira 问题。") : ""
                    if Confirm.ask("确认删除这个待办？" + (note.isEmpty ? "" : "\n" + note)) {
                        guarded {
                            try await API.shared.wsDeleteTodo(todo.id)
                            onDeleted()
                        }
                    }
                }
                .help(draft.refSystem == "jira" ? "删除待办（不影响 Jira 问题）" : "删除待办")
            }
        }
        .onChange(of: todo) { _, new in
            // 外部更新（例如同步、勾选完成）时刷新未在编辑的字段
            let (title, notes) = (draft.title, draft.notes)
            draft = new
            if typing { draft.title = title; draft.notes = notes }
        }
        .onDisappear {
            if typing { save(draft) }
        }
        .sheet(isPresented: $promoting) {
            CreateIssueSheet(initialSummary: draft.title, initialDescription: draft.notes) { key in
                let title = draft.title
                update { $0.refSystem = "jira"; $0.refKey = key; $0.refTitle = title }
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("检查项").foregroundStyle(.secondary)
                if !draft.checklist.isEmpty { Text("\(draft.checklist.filter(\.done).count)/\(draft.checklist.count)").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(draft.checklist) { item in
                HStack {
                    CheckCircle(done: item.done, size: 15) { update { t in if let i = t.checklist.firstIndex(where: { $0.id == item.id }) { t.checklist[i].done.toggle() } } }
                    TextField("", text: Binding(get: { item.text }, set: { v in update(debounce: true) { t in if let i = t.checklist.firstIndex(where: { $0.id == item.id }) { t.checklist[i].text = v } } }))
                        .textFieldStyle(.plain)
                        .strikethrough(item.done)
                    Button("删除", systemImage: "xmark") { update { $0.checklist.removeAll { $0.id == item.id } } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("添加检查项，回车保存", text: $newCheck)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let text = newCheck.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        update { $0.checklist.append(ChecklistItem(id: UUID().uuidString.lowercased(), text: text, done: false)) }
                        newCheck = ""
                    }
            }
        }
    }

    /// 文字输入停顿后保存，其他修改立即保存。
    private func update(debounce: Bool = false, _ patch: (inout Todo) -> Void) {
        patch(&draft)
        if debounce {
            typing = true
            debouncer.run(after: .milliseconds(500)) {
                typing = false
                save(draft)
            }
        } else {
            debouncer.cancel()
            typing = false
            save(draft)
        }
    }

    private func save(_ next: Todo) {
        Task {
            do {
                onSaved(try await API.shared.wsSaveTodo(TodoInput(next)))
                error = nil
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
            }
        }
    }
}

/// ⌘⇧N：在任何页面快速记一条待办。
struct QuickTodoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var due = 1
    @State private var saving = false
    @State private var error: String?

    private let options: [(String, () -> String?)] = [("不设日期", { nil }), ("今天", { Fmt.today() }), ("明天", { Fmt.addDays(Fmt.today(), 1) })]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建待办").font(.headline)
            TextField("要做什么？", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Picker("", selection: $due) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].0).tag(i) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let error { ErrorBox(message: error) }
            HStack {
                Text("↵ 保存 · Esc 关闭").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let text = title.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        saving = true
        Task {
            do {
                _ = try await API.shared.wsSaveTodo(TodoInput(title: text, due: .some(options[due].1())))
                Events.workspaceChanged()
                dismiss()
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
                saving = false
            }
        }
    }
}
