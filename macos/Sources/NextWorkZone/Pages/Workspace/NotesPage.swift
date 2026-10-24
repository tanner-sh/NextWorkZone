import SwiftUI

/// 笔记：每日日记 + 独立笔记。
struct NotesPage: View {
    enum Tab { case daily, notes }

    @Environment(AppModel.self) private var model
    @Environment(\.pageActive) private var active
    @State private var tab: Tab = .daily
    @State private var notes: [DocSummary]?
    @State private var days: [String] = []
    @State private var filter = ""
    @State private var selected = "daily-\(Fmt.today())"
    @State private var error: String?

    private var today: String { Fmt.today() }
    private var dayList: [String] { [today] + days.filter { $0 != today } }
    private var visibleNotes: [DocSummary] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return (notes ?? []).filter { q.isEmpty || "\($0.title) \($0.excerpt) \($0.tags.joined(separator: " "))".lowercased().contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 300)
            Divider()
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
        .task { await load() }
        .onWorkspaceChange { Task { await load() } }
        .onChange(of: model.current.nonce, initial: true) { take() }
    }

    /// 从其他页面（搜索、反向链接）跳转过来。
    private func take() {
        guard active, model.current.page == .notes, let id = model.current.docId else { return }
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
                await load()
            } catch {
                self.error = errorMessage(error)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $tab) {
                    Label("日记", systemImage: "calendar").tag(Tab.daily)
                    Label(notes.map { $0.isEmpty ? "笔记" : "笔记 \($0.count)" } ?? "笔记", systemImage: "note.text").tag(Tab.notes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(action: createNote) { Image(systemName: "plus") }.help("新建笔记")
            }
            if tab == .daily {
                DatePicker("跳到日期", selection: Binding(get: {
                    Fmt.date(ofDay: selected.hasPrefix("daily-") ? String(selected.dropFirst(6)) : today) ?? Date()
                }, set: { selected = "daily-\(Fmt.day($0))" }), in: ...Date(), displayedComponents: .date)
                .font(.callout)
            } else {
                TextField("", text: $filter, prompt: Text("筛选笔记")).textFieldStyle(.roundedBorder)
            }
            if let error { ErrorBox(message: error) { Task { await load() } } }
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
                        Text(filter.isEmpty ? "还没有笔记，点击右上角 + 新建" : "没有匹配的笔记").foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .padding([.horizontal, .top], 12)
    }

    private func dayMenu(_ day: String) -> [MenuSpec] {
        var specs: [MenuSpec] = [
            .action("打开") { selected = "daily-\(day)" },
            .action("新建笔记", icon: "plus", createNote),
        ]
        // 今天的日记还没写时不能删除
        if days.contains(day) {
            specs += [.separator, DocMenus.delete("daily-\(day)", label: "删除这天的日记") { if selected == "daily-\(day)" { selected = "daily-\(today)" } }]
        }
        return specs
    }

    private func noteMenu(_ n: DocSummary) -> [MenuSpec] {
        [
            .action("打开") { selected = n.id },
            .action("新建笔记", icon: "plus", createNote),
            .separator,
            DocMenus.pin(n),
            DocMenus.copyTitle(n.title),
            .separator,
            DocMenus.delete(n.id, label: "删除") { if selected == n.id { selected = "daily-\(today)" } },
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
    static func delete(_ id: String, label: String, beforeDelete: @escaping () -> Void) -> MenuSpec {
        .item(label, icon: "trash", destructive: true, confirm: "确认删除") {
            guarded {
                beforeDelete()
                _ = try await API.shared.wsDeleteDoc(id)
                Events.workspaceChanged()
            }
        }
    }
}
