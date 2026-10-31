import SwiftUI

/// 笔记：每日日记 + 独立笔记。
struct NotesPage: View {
    enum Tab { case daily, notes }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .daily
    @State private var notes: [DocSummary]?
    @State private var days: [String] = []
    @State private var filter = ""
    @State private var selected = "daily-\(Fmt.today())"
    @State private var error: String?
    @State private var showDeleted = false
    /// 刚新建、还没写内容的笔记：切到别处时还是空的就删掉，不留下空笔记
    @State private var fresh: String?

    private var today: String { model.today }
    private var dayList: [String] { [today] + days.filter { $0 != today } }
    private var visibleNotes: [DocSummary] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return (notes ?? []).filter { q.isEmpty || "\($0.title) \($0.excerpt) \($0.tags.joined(separator: " "))".lowercased().contains(q) }
    }

    var body: some View {
        SplitPane("notes", minWidth: 240, idealWidth: 300, maxWidth: 440, trailingMin: 420) {
            sidebar
        } trailing: {
            // 切换文档时重新创建面板
            DocPane(docId: selected, onSaved: { doc in
                // 列表里的标题、摘要随编辑更新
                if doc.kind == "note", let i = notes?.firstIndex(where: { $0.id == doc.id }) {
                    notes?[i].title = doc.title
                    notes?[i].updatedAt = doc.updatedAt
                    notes?[i].pinned = doc.pinned
                    notes?[i].tags = doc.tags
                }
            }, onDeleted: {
                selected = "daily-\(Fmt.today())"
                tab = .daily
                Task { await load() }
            }) { doc in
                if doc.kind == "daily", let day = doc.day { WorkLogPanel(day: day).id(day) }
            }
            .id(selected)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageToolbar {
            ToolbarItem(placement: .navigation) {
                Picker("显示", selection: $tab) {
                    Text("日记").tag(Tab.daily)
                    Text(notes.map { $0.isEmpty ? "笔记" : "笔记 \($0.count)" } ?? "笔记").tag(Tab.notes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .navigation) {
                Button("新建笔记", systemImage: "square.and.pencil", action: createNote).help("新建笔记（⌘N）")
                Button("最近删除", systemImage: "trash") { showDeleted = true }.help("最近删除的笔记和日记")
            }
        }
        .sheet(isPresented: $showDeleted) {
            RecentlyDeletedSheet(kinds: ["note", "daily"]) { doc in
                Task {
                    await load()
                    tab = doc.kind == "daily" ? .daily : .notes
                    selected = doc.id
                }
            }
        }
        .onChange(of: selected) { old, _ in discardIfEmpty(old) }
        // 过了零点：正看着的“今天”的日记换成新的一天
        .onChange(of: model.today) { old, new in
            if selected == "daily-\(old)" { selected = "daily-\(new)" }
        }
        .pageCommands { PageCommands(title: "笔记", newItem: ("新建笔记", createNote), refresh: { Task { await load() } }) }
        .task { await load() }
        .onWorkspaceChange { Task { await load() } }
        .onAppear { take() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.navigated)) { _ in take() }
    }

    /// 从其他页面（搜索、反向链接）跳转过来。导航通知在页面重新显示之前发出，所以按当前页面判断，而不是 active。
    private func take() {
        guard model.current.page == .notes, let id = model.current.docId else { return }
        selected = id
        tab = id.hasPrefix("daily-") ? .daily : .notes
    }

    private func load() async {
        do {
            async let n = API.shared.wsDocs("note")
            async let d = API.shared.wsDailyDays()
            (notes, days) = try await (n, d)
            error = nil
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
    }

    private func createNote() {
        Task {
            do {
                let doc = try await API.shared.wsSaveDoc(DocInput(kind: "note", title: "", content: ""))
                Events.workspaceChanged()
                tab = .notes
                filter = ""
                selected = doc.id
                fresh = doc.id
                await load()
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
            }
        }
    }

    /// 新建后什么都没写就切走的笔记直接删掉（不进“最近删除”，也不提示）。
    private func discardIfEmpty(_ id: String) {
        guard let fresh, fresh == id else { return }
        self.fresh = nil
        Task {
            // 稍等片刻，切走前刚输入的内容先保存好；保存过（修改时间变了）就不算空笔记
            try? await Task.sleep(for: .seconds(1))
            guard let doc = try? await API.shared.wsDoc(id), doc.updatedAt == doc.createdAt, doc.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, doc.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, doc.tags.isEmpty else { return }
            _ = try? await API.shared.wsDeleteDoc(id)
            Events.workspaceChanged()
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { selected }, set: { if let v = $0 { selected = v } })) {
            if tab == .daily {
                ForEach(dayList, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day == today ? "今天" : day).fontWeight(.medium)
                        Text(day == today ? "\(day) · \(Fmt.weekday(day))" : Fmt.weekday(day)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag("daily-\(day)")
                    .contextMenu(specs: { dayMenu(day) })
                }
            } else {
                ForEach(visibleNotes) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if n.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                            Text(n.title.isEmpty ? "无标题" : n.title).fontWeight(.medium).lineLimit(1)
                        }
                        if !n.excerpt.isEmpty { Text(n.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        Text(Fmt.time(ms: n.updatedAt) + (n.tags.isEmpty ? "" : " · " + n.tags.map { "#\($0)" }.joined(separator: " "))).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(n.id)
                    .contextMenu(specs: { noteMenu(n) })
                }
                if notes != nil && visibleNotes.isEmpty {
                    Text(filter.isEmpty ? "还没有笔记，按 ⌘N 或点击工具栏中的新建按钮" : "没有匹配的笔记").foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // ⌫ 或“编辑 > 删除”：删除选中的笔记（日记不在这里删除）
        .onDeleteCommand {
            guard tab == .notes, let n = notes?.first(where: { $0.id == selected }) else { return }
            guarded {
                selected = "daily-\(today)"
                try await DocActions.delete(n.id, title: n.title)
            }
        }
        .listHeader {
            if tab == .daily {
                DayJumpButton(date: Binding(get: {
                    Fmt.date(ofDay: selected.hasPrefix("daily-") ? String(selected.dropFirst(6)) : today) ?? Date()
                }, set: { selected = "daily-\(Fmt.day($0))" }))
            } else {
                FilterField(prompt: "筛选笔记", text: $filter)
            }
            if let error { ErrorBox(message: error) { Task { await load() } } }
        }
        .padding([.horizontal, .top], 12)
    }

    private func dayMenu(_ day: String) -> [MenuSpec] {
        var specs: [MenuSpec] = [
            .action("打开") { selected = "daily-\(day)" },
            DetailWindows.menuItem(.doc("daily-\(day)")),
            .action("新建笔记", icon: "plus", createNote),
        ]
        // 今天的日记还没写时不能删除
        if days.contains(day) {
            specs += [.separator, DocMenus.delete("daily-\(day)", title: "\(day) 的日记", label: "删除这天的日记") { if selected == "daily-\(day)" { selected = "daily-\(today)" } }]
        }
        return specs
    }

    private func noteMenu(_ n: DocSummary) -> [MenuSpec] {
        [
            .action("打开") { selected = n.id },
            DetailWindows.menuItem(.doc(n.id)),
            .action("新建笔记", icon: "plus", createNote),
            .separator,
            DocMenus.pin(n),
            DocMenus.copyTitle(n.title),
            .separator,
            DocMenus.delete(n.id, title: n.title, label: "删除") { if selected == n.id { selected = "daily-\(today)" } },
        ]
    }
}

/// 文档（笔记、日记、知识库页面）右键菜单的共用部分。
@MainActor
enum DocMenus {
    static func pin(_ doc: DocSummary) -> MenuSpec {
        .action(doc.pinned ? "取消置顶" : "置顶", icon: doc.pinned ? "pin.slash" : "pin") {
            guarded {
                guard let full = try await API.shared.wsDoc(doc.id) else { return }
                var input = DocActions.input(full)
                input.pinned = !full.pinned
                _ = try await API.shared.wsSaveDoc(input)
                Events.workspaceChanged()
            }
        }
    }

    static func copyTitle(_ title: String) -> MenuSpec {
        .action("复制标题", icon: "doc.on.doc", disabled: title.isEmpty) {
            Pasteboard.copy(title)
            toast("已复制")
        }
    }

    /// `beforeDelete` 在删除前调用，用于先关闭正在编辑的文档。
    static func delete(_ id: String, title: String, label: String, beforeDelete: @escaping () -> Void) -> MenuSpec {
        .item(label, icon: "trash", destructive: true) {
            guarded {
                beforeDelete()
                try await DocActions.delete(id, title: title)
            }
        }
    }
}

/// 跳到某天的日记：点按钮弹出日历（之前是带上下箭头的日期输入框，要逐位调整）。
private struct DayJumpButton: View {
    @Binding var date: Date
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("跳到日期…", systemImage: "calendar")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .help("选择一天，查看那天的日记")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DatePicker("", selection: Binding(get: { date }, set: { date = $0; open = false }), in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
        }
    }
}
