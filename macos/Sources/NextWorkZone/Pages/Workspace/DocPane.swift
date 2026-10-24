import SwiftUI

/// 文档编辑面板：标题、标签、正文编辑器、反向链接，修改自动保存。
/// 日记的 id 为 daily-YYYY-MM-DD（不存在时首次输入后创建）。
struct DocPane<Header: View, Actions: View, Footer: View>: View {
    var docId: String
    var onSaved: ((Doc) -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    /// 标题下方的额外内容（知识库的来源、子页面等）
    @ViewBuilder var header: (Doc) -> Header
    /// 标题栏右侧的额外操作
    @ViewBuilder var actions: (Doc) -> Actions
    /// 正文下方的额外内容（日记的工作记录）
    @ViewBuilder var footer: (Doc) -> Footer

    @Environment(AppModel.self) private var model
    @State private var doc: Doc?
    @State private var error: String?
    @State private var saveError: String?
    @State private var notice: String?
    @State private var issueDraft: IssueDraft?
    @State private var titleDebounce = Debouncer()
    @State private var editingTitle = false
    /// 按顺序保存
    @State private var saving = Task<Void, Never> {}

    struct IssueDraft: Identifiable {
        let id = UUID()
        var summary: String
        var description: String
        var insert: (String) -> Void
    }

    var body: some View {
        Group {
            if let error {
                ErrorBox(message: error) { Task { await load() } }.padding(24)
            } else if let doc {
                content(doc)
            } else {
                LoadingView()
            }
        }
        .task(id: docId) { await load() }
        // 其他设备同步过来的修改：标题没在编辑时刷新
        .onWorkspaceChange { if !editingTitle { Task { await load() } } }
        .sheet(item: $issueDraft) { draft in
            CreateIssueSheet(initialSummary: draft.summary, initialDescription: draft.description) { key in
                draft.insert(key)
                notice = "已创建 \(key)"
            }
        }
    }

    private func load() async {
        do {
            let loaded: Doc?
            if docId.hasPrefix("daily-") {
                loaded = try await API.shared.wsDaily(String(docId.dropFirst(6)))
            } else {
                loaded = try await API.shared.wsDoc(docId)
            }
            guard let loaded else {
                error = "文档不存在或已被删除"
                return
            }
            // 正在编辑的内容以本地为准（保存后会再同步）
            if let current = doc, current.id == loaded.id {
                var merged = loaded
                merged.content = loaded.updatedAt >= current.updatedAt ? loaded.content : current.content
                if editingTitle { merged.title = current.title }
                doc = merged
            } else {
                doc = loaded
            }
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func save(_ patch: (inout Doc) -> Void) {
        guard var next = doc else { return }
        patch(&next)
        doc = next
        // 空日记不保存
        if next.kind == "daily" && next.createdAt == 0 && next.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        let previous = saving
        saving = Task {
            await previous.value
            do {
                var input = DocActions.input(next)
                if next.kind == "daily" && input.title.isEmpty { input.title = next.day ?? "" }
                let saved = try await API.shared.wsSaveDoc(input)
                // 保存期间又有新输入时只更新时间戳等字段，不覆盖正在编辑的内容
                if var d = doc {
                    d.id = saved.id
                    d.createdAt = saved.createdAt
                    d.updatedAt = saved.updatedAt
                    d.publishedUrl = saved.publishedUrl
                    doc = d
                }
                saveError = nil
                onSaved?(saved)
                Events.workspaceChanged()
            } catch {
                saveError = errorMessage(error)
            }
        }
    }

    private func content(_ doc: Doc) -> some View {
        let isDaily = doc.kind == "daily"
        let exists = doc.createdAt != 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    if isDaily {
                        Text(doc.day ?? "").font(.largeTitle.weight(.semibold))
                        Text(Fmt.weekday(doc.day ?? "")).foregroundStyle(.secondary)
                    } else {
                        TextField("", text: Binding(get: { doc.title }, set: { title in
                            self.doc?.title = title
                            editingTitle = true
                            titleDebounce.run(after: .milliseconds(500)) {
                                editingTitle = false
                                save { $0.title = title }
                            }
                        }), prompt: Text("无标题"))
                        .textFieldStyle(.plain)
                        .font(.largeTitle.weight(.semibold))
                    }
                    Spacer()
                    actions(doc)
                    if !isDaily {
                        Button { save { $0.pinned.toggle() } } label: { Image(systemName: doc.pinned ? "pin.slash" : "pin") }
                            .buttonStyle(.borderless).help(doc.pinned ? "取消置顶" : "置顶")
                    }
                    if exists {
                        Button { remove(doc) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除")
                    }
                }
                if !isDaily { TagsInput(tags: doc.tags) { tags in save { $0.tags = tags } } }
                header(doc)
                if let notice {
                    HStack {
                        Text(notice)
                        Spacer()
                        Button { self.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                NoteEditor(
                    docId: doc.id,
                    value: doc.content,
                    placeholder: isDaily ? "今天做了什么、遇到什么问题、明天要做什么…" : nil,
                    onChange: { md in save { $0.content = md } },
                    onCreateTodos: { lines in createTodos(lines, doc) },
                    onCreateIssue: { text, insert in
                        let lines = text.components(separatedBy: "\n")
                        issueDraft = IssueDraft(summary: lines[0].trimmingCharacters(in: .whitespaces), description: lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), insert: insert)
                    }
                )
                if let saveError { ErrorBox(message: "保存失败：\(saveError)") }
                footer(doc)
                if exists { BacklinksSection(system: "doc", itemKey: doc.id, title: "引用了本文的内容", hideEmpty: true) }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func createTodos(_ lines: [String], _ doc: Doc) {
        Task {
            do {
                for line in lines {
                    let title = line.replacing(/^[-*]\s*(\[[ xX]\]\s*)?/, with: "")
                    _ = try await API.shared.wsSaveTodo(TodoInput(title: title, refSystem: .some("doc"), refKey: .some(doc.id), refTitle: .some(doc.title.isEmpty ? doc.day : doc.title)))
                }
                Events.workspaceChanged()
                notice = "已创建 \(lines.count) 条待办"
            } catch {
                saveError = errorMessage(error)
            }
        }
    }

    private func remove(_ doc: Doc) {
        guard Confirm.ask(doc.kind == "page" ? "删除这个页面（含子页面）？" : "删除这篇\(doc.kind == "daily" ? "日记" : "笔记")？", confirm: "删除") else { return }
        Task {
            do {
                _ = try await API.shared.wsDeleteDoc(doc.id)
                Events.workspaceChanged()
                onDeleted?()
            } catch {
                saveError = errorMessage(error)
            }
        }
    }
}

extension DocPane where Header == EmptyView, Actions == EmptyView {
    init(docId: String, onSaved: ((Doc) -> Void)? = nil, onDeleted: (() -> Void)? = nil, @ViewBuilder footer: @escaping (Doc) -> Footer) {
        self.init(docId: docId, onSaved: onSaved, onDeleted: onDeleted, header: { _ in EmptyView() }, actions: { _ in EmptyView() }, footer: footer)
    }
}

/// 标签：回车或逗号添加，退格删除最后一个。
struct TagsInput: View {
    var tags: [String]
    var onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.secondary)
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 3) {
                    Text(t)
                    Button { onChange(tags.filter { $0 != t }) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).help("移除标签 \(t)")
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            TextField("", text: $draft, prompt: Text(tags.isEmpty ? "添加标签" : ""))
                .textFieldStyle(.plain)
                .frame(minWidth: 80)
                .onSubmit(add)
                .onChange(of: draft) { _, v in if v.hasSuffix(",") || v.hasSuffix("，") { draft = String(v.dropLast()); add() } }
                .onKeyPress(.delete) {
                    guard draft.isEmpty, !tags.isEmpty else { return .ignored }
                    onChange(Array(tags.dropLast()))
                    return .handled
                }
        }
    }

    private func add() {
        let tag = draft.trimmingCharacters(in: .whitespaces).replacing(/^#/, with: "")
        if !tag.isEmpty && !tags.contains(tag) { onChange(tags + [tag]) }
        draft = ""
    }
}

/// 日记下方的工作记录：当天在各处做过的事，可写入日记、生成日报。
struct WorkLogPanel: View {
    var day: String
    @Environment(AppModel.self) private var model
    @State private var log: WorkLog?
    @State private var loading = false
    @State private var error: String?
    @State private var open = true
    @State private var report: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { open.toggle() } label: {
                    Label {
                        Text("工作记录") + Text(log.map { $0.events.isEmpty ? "" : " \($0.events.count)" } ?? "").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                    }
                    .font(.headline)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(loading).help("刷新")
                Button("写入日记", systemImage: "doc.text", action: writeToDaily)
                    .disabled(log?.events.isEmpty ?? true)
                    .help("把整理后的工作记录写入（或更新）日记中的“工作记录”小节")
                Button("生成日报", systemImage: "list.clipboard") { if let log { report = WorkLogText.report(log) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(log == nil)
            }
            .controlSize(.small)
            if open {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                ForEach(log?.notes ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if log == nil && error == nil { ProgressView().controlSize(.small) }
                if let log, log.events.isEmpty {
                    Text("这一天还没有记录：Jira 上的流转和评论、GitLab 推送和合并请求、Wiki 编辑、完成的待办都会出现在这里。").font(.callout).foregroundStyle(.secondary)
                }
                if let log {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(WorkLogText.timeline(log.events).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text(WorkLogText.clock(row.at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: WorkLogText.icon(row.first.system)).font(.caption).foregroundStyle(.secondary)
                                if let target = WorkLogText.target(row.first) {
                                    Button(row.text) { model.navigate(target) }.buttonStyle(.plain).lineLimit(1).help(row.text)
                                } else {
                                    Text(row.text).lineLimit(1).help(row.text)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .task(id: day) { await load() }
        .sheet(item: Binding(get: { report.map { ReportText(text: $0) } }, set: { report = $0?.text })) { r in
            ReportSheet(day: day, text: r.text)
        }
    }

    private func load() async {
        loading = true
        do {
            log = try await API.shared.wsWorklog(day)
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
        loading = false
    }

    private func writeToDaily() {
        guard let log else { return }
        Task {
            do {
                let latest = try await API.shared.wsDaily(day)
                var input = DocActions.input(latest)
                input.kind = "daily"
                if input.title.isEmpty { input.title = day }
                input.content = WorkLogText.withWorkSection(latest.content, log)
                _ = try await API.shared.wsSaveDoc(input)
                Events.workspaceChanged()
                toast("已写入日记的“工作记录”")
            } catch {
                self.error = errorMessage(error)
            }
        }
    }
}
