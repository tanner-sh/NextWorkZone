import SwiftUI

/// Wiki 页面编辑器：普通内容（段落、标题、列表、表格、文字格式）可视化编辑；
/// 宏、图片、页面链接、任务列表等显示为不可编辑的块，保存时原样保留。
/// 自动保存草稿；保存前显示改动，页面在编辑期间被别人改过时不覆盖。
struct WikiPageEditor: View {
    var target: WikiEditing
    var onClose: () -> Void
    var onSaved: (String) -> Void

    @Environment(\.pageActive) private var active
    @State private var session: WikiEditSession?
    @State private var doc: RichDoc?
    @State private var error: String?
    @State private var title = ""
    @State private var dirty = false
    @State private var draft: Draft?
    @State private var preview: Preview?
    @State private var checking = false
    @State private var linkDraft: String?
    @State private var controller = RichEditorController()
    @State private var draftSave = Debouncer()
    /// 保存时保留未修改内容所需的片段和基准
    @State private var baseline: RichEditBaseline?

    /// 未保存的修改暂存在本机。
    struct Draft: Codable {
        var title: String
        var doc: RichDoc
        /// 草稿基于的页面版本
        var version: Int
        var savedAt: Int64
    }

    struct Preview: Identifiable {
        let id = UUID()
        var xhtml: String
        var result: WikiSavePreview
    }

    private var pageId: String? { if case .edit(let id) = target { id } else { nil } }

    private var draftKey: String {
        switch target {
        case .edit(let id): "nextworkzone.wiki.nativeDraft.\(id)"
        case .new(let r): "nextworkzone.wiki.nativeDraft.new:\(r.space):\(r.parent ?? "")"
        }
    }

    private func readDraft() -> Draft? {
        AppPreferences.shared.data(forKey: draftKey).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
    }

    private func writeDraft(_ d: Draft?) {
        if let d, let data = try? JSONEncoder().encode(d) { AppPreferences.shared.set(data, forKey: draftKey) } else { AppPreferences.shared.removeObject(forKey: draftKey) }
    }

    var body: some View {
        Group {
            if let error, session == nil {
                VStack(alignment: .leading) {
                    ErrorBox(message: error)
                    Button("返回", action: onClose)
                }
                .padding(24)
            } else {
                content
            }
        }
        .task { await load() }
        .sheet(item: $preview) { p in
            if let session {
                SaveSheet(target: target, session: session, title: title, xhtml: p.xhtml, result: p.result) { id in
                    writeDraft(nil)
                    preview = nil
                    dirty = false
                    onSaved(id)
                }
            }
        }
    }

    private func load() async {
        do {
            let s: WikiEditSession
            switch target {
            case .edit(let id): s = try await API.shared.wikiEdit(id)
            case .new(let r): s = try await API.shared.wikiNewPage(space: r.space, template: r.template, storage: r.storage)
            }
            var loaded = try await Rich.editLoad(s.html)
            loaded.doc = await withLabels(loaded.doc, users: s.users, pageId: s.pageId)
            baseline = RichEditBaseline(loaded)
            session = s
            doc = loaded.doc
            if case .new(let r) = target { title = r.title } else { title = s.title }
            // 草稿基于的版本与当前一致时才能恢复，否则会覆盖别人的修改
            if let saved = readDraft(), saved.version == s.version { draft = saved }
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// 占位块显示用户名、问题的概要和状态（只影响显示，保存时原样保留）。
    #if DEBUG
    /// 调试通道：不经界面，按编辑器的流程把页面（不修改或改掉第一段）转回 XHTML 并预览保存（只读）。
    static func debugRoundTrip(page: String, edit: Bool) async throws -> WikiSavePreview {
        let s = try await API.shared.wikiEdit(page)
        let loaded = try await Rich.editLoad(s.html)
        let base = RichEditBaseline(loaded)
        // 编辑器显示整篇后再读出
        var r = RichRenderer(service: .confluence, editing: true)
        var shown = loaded.doc
        if case .para? = shown.blocks.last {} else { shown.blocks.append(.para([])) }
        var edited = RichFlat.build(RichFlat.parse(r.render(shown)).paras)
        if edit, let i = edited.blocks.firstIndex(where: { if case .para(let l) = $0 { !l.isEmpty } else { false } }) {
            edited.blocks[i] = .para([.text("调试修改", [], link: nil, color: nil)])
        }
        let xhtml = try await base.xhtml(edited)
        return try await API.shared.wikiPreviewSave(page: page, xhtml: xhtml, fragments: s.fragments)
    }
    #endif

    private func withLabels(_ doc: RichDoc, users: [String], pageId: String?) async -> RichDoc {
        var names: [String: String] = [:]
        if !users.isEmpty { names = (try? await API.shared.wikiUsers(users)) ?? [:] }
        var keys: [String] = []
        doc.walk { b in
            if case .opaque(let o) = b, let k = o.issue { keys.append(k) }
            if case .para(let inl) = b { for i in inl { if case .opaque(let o) = i, let k = o.issue { keys.append(k) } } }
        }
        let issues = keys.isEmpty ? [:] : await IssueLookup.fetch(Array(Set(keys)))
        func label(_ o: RichOpaque) -> RichOpaque {
            var o = o
            if let u = o.user, let n = names[u] { o.label = "@\(n)" }
            if let k = o.issue, let i = issues[k] { o.label = "\(i.key) \(i.summary) · \(i.status.name)" }
            // 页面附件中的图片：显示图片本身
            if let img = o.image, img.hasPrefix("attachment:"), let pageId {
                let file = String(img.dropFirst("attachment:".count))
                o.image = "/download/attachments/\(pageId)/\(file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file)"
            }
            return o
        }
        func inl(_ list: [RichInline]) -> [RichInline] { list.map { if case .opaque(let o) = $0 { return .opaque(label(o)) } else { return $0 } } }
        func blocks(_ list: [RichBlock]) -> [RichBlock] {
            list.map { b in
                switch b {
                case .para(let l): return .para(inl(l))
                case .heading(let level, let l, let id): return .heading(level: level, inl(l), id: id)
                case .opaque(let o): return .opaque(label(o))
                case .list(let ordered, let s, let items): return .list(ordered: ordered, start: s, items: items.map { RichItem(task: $0.task, blocks: blocks($0.blocks)) })
                case .quote(let bs): return .quote(blocks(bs))
                case .panel(let k, let t, let bs): return .panel(kind: k, title: t, blocks: blocks(bs))
                case .table(let rows): return .table(rows.map { RichRow(cells: $0.cells.map { RichCell(head: $0.head, blocks: blocks($0.blocks), colspan: $0.colspan, rowspan: $0.rowspan) }) })
                default: return b
                }
            }
        }
        return RichDoc(blocks: blocks(doc.blocks))
    }

    private func changed(_ next: RichDoc) {
        dirty = true
        guard let session else { return }
        let t = title
        draftSave.run(after: .milliseconds(800)) {
            writeDraft(Draft(title: t, doc: next, version: session.version, savedAt: Fmt.nowMs()))
        }
    }

    private func review() {
        guard let session, let baseline, !checking, let current = controller.doc else { return }
        checking = true
        error = nil
        Task {
            do {
                let xhtml = try await baseline.xhtml(current)
                let result = try await API.shared.wikiPreviewSave(page: pageId, xhtml: xhtml, fragments: session.fragments)
                preview = Preview(xhtml: xhtml, result: result)
            } catch {
                self.error = errorMessage(error)
            }
            checking = false
        }
    }

    private func close() {
        guard dirty else { return onClose() }
        let alert = NSAlert()
        alert.messageText = "放弃编辑？"
        alert.informativeText = "修改尚未保存到 Wiki。草稿保留在本机，下次编辑同一页面（且页面没有被别人修改）时可以恢复。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "保留草稿并退出")
        alert.addButton(withTitle: "丢弃修改")
        switch alert.runModal() {
        case .alertSecondButtonReturn: onClose()
        case .alertThirdButtonReturn:
            writeDraft(nil)
            onClose()
        default: break
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("", text: $title, prompt: Text("页面标题"))
                    .textFieldStyle(.plain)
                    .font(.title.weight(.semibold))
                    .onChange(of: title) { if session != nil && dirty, let d = controller.doc { changed(d) } }
                Text((pageId != nil ? (session.map { "基于第 \($0.version) 版编辑" } ?? "") : "新页面") + (dirty ? " · 已自动保存草稿" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let d = draft {
                HStack {
                    Text("有一份 \(Fmt.time(ms: d.savedAt)) 未保存的草稿。")
                    Spacer()
                    Button("恢复草稿") {
                        doc = d.doc
                        title = d.title
                        draft = nil
                        dirty = true
                    }
                    Button("丢弃") {
                        writeDraft(nil)
                        draft = nil
                    }
                }
                .padding(10)
                .noticeBackground(.orange)
            }
            if let error { ErrorBox(message: error) }
            toolbar
            if let doc {
                ScrollView {
                    RichEditorView(
                        doc: doc,
                        service: .confluence,
                        controller: controller,
                        minHeight: 300,
                        onChange: changed,
                        onOpenLink: { Links.open($0) },
                        onOpenIssue: { AppModel.shared.navigate(NavTarget(.jira, issueKey: $0)) }
                    )
                    .padding(.bottom, 40)
                }
            } else {
                LoadingView()
            }
            Text("灰色的块是宏、图片、页面链接、任务等暂不支持在这里编辑的内容，保存时原样保留；可以在网页上编辑它们。暂不支持在这里粘贴图片。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .pageToolbar {
            ToolbarItem {
                Button("取消", systemImage: "xmark", action: close).help("退出编辑")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button(checking ? "检查中…" : pageId != nil ? "保存…" : "创建…", systemImage: "square.and.arrow.down", action: review)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .disabled(session == nil || checking)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            tool("arrow.uturn.backward", "撤销（⌘Z）", false) { controller.undo() }
            tool("arrow.uturn.forward", "重做（⇧⌘Z）", false) { controller.redo() }
            Divider().frame(height: 14)
            tool("paragraphsign", "正文", controller.heading == nil) { if let h = controller.heading { controller.toggleHeading(h) } }
            ForEach(1...3, id: \.self) { level in
                Button { controller.toggleHeading(level) } label: {
                    Text("H\(level)").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 22)
                        .selectionBackground(controller.heading == level, radius: 5)
                }
                .help("\(level) 级标题")
            }
            Divider().frame(height: 14)
            tool("bold", "粗体（⌘B）", controller.marks.contains(.bold)) { controller.toggleMark(.bold) }
            tool("italic", "斜体（⌘I）", controller.marks.contains(.italic)) { controller.toggleMark(.italic) }
            tool("underline", "下划线（⌘U）", controller.marks.contains(.underline)) { controller.toggleMark(.underline) }
            tool("strikethrough", "删除线", controller.marks.contains(.strike)) { controller.toggleMark(.strike) }
            tool("chevron.left.forwardslash.chevron.right", "行内代码", controller.marks.contains(.code)) { controller.toggleMark(.code) }
            tool("link", "链接", controller.link != nil) { linkDraft = controller.link ?? "" }
            Divider().frame(height: 14)
            tool("list.bullet", "无序列表", controller.list == .bullet) { controller.toggleList(.bullet) }
            tool("list.number", "有序列表", controller.list == .ordered) { controller.toggleList(.ordered) }
            tool("text.quote", "引用", controller.quote) { controller.toggleQuote() }
            tool("tablecells", "插入表格", false) { controller.insertTable() }
            tool("minus", "分隔线", false) { controller.insertRule() }
            if controller.table {
                Divider().frame(height: 14)
                ForEach([("+行", RichOps.TableOp.addRow), ("+列", .addCol), ("−行", .deleteRow), ("−列", .deleteCol), ("删表", .deleteTable)], id: \.0) { t, op in
                    Button(t) { controller.tableOp(op) }.font(.caption)
                }
            }
            if let draft = linkDraft {
                TextField("", text: Binding(get: { draft }, set: { linkDraft = $0 }), prompt: Text("粘贴链接地址，回车插入"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit {
                        let url = linkDraft?.trimmingCharacters(in: .whitespaces) ?? ""
                        linkDraft = nil
                        controller.setLink(url.isEmpty ? nil : url)
                        controller.focus()
                    }
                    .onKeyPress(.escape) { linkDraft = nil; return .handled }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
    }

    private func tool(_ icon: String, _ title: String, _ active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 22)
                .selectionBackground(active, radius: 5)
        }
        .help(title)
    }
}

/// 保存前确认：显示改动、填写修改说明，选择是否为小修改（不通知关注者）。
private struct SaveSheet: View {
    var target: WikiEditing
    var session: WikiEditSession
    var title: String
    var xhtml: String
    var result: WikiSavePreview
    var onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var minor = false
    @State private var saving = false
    @State private var error: String?

    private var isEdit: Bool { if case .edit = target { true } else { false } }
    private var titleChanged: Bool { isEdit && title.trimmingCharacters(in: .whitespaces) != session.title }
    private var nothing: Bool { isEdit && !result.changed && !titleChanged }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEdit ? "保存到 Wiki" : "创建 Wiki 页面").font(.title3.weight(.semibold))
            if title.trimmingCharacters(in: .whitespaces).isEmpty { ErrorBox(message: "请填写页面标题") }
            if nothing {
                Text("内容没有变化。").foregroundStyle(.secondary)
            } else if isEdit {
                if titleChanged {
                    HStack(spacing: 4) {
                        Text("标题：")
                        Text(session.title).strikethrough().foregroundStyle(.secondary)
                        Text("→ \(title)")
                    }
                }
                ScrollView { TextDiffView(diff: result.diff) }.frame(maxHeight: 380)
                TextField("修改说明（可选）", text: $message, prompt: Text("例如：补充部署步骤"))
                Toggle("小修改（不通知关注这个页面的人）", isOn: $minor).toggleStyle(.checkbox)
                Text("保存时会检查页面是否在你开始编辑后被别人修改过；如果是，不会覆盖，请刷新后重新编辑。").font(.caption).foregroundStyle(.secondary)
            } else if case .new(let r) = target {
                Text("将在 **\(r.space)** 空间\(r.parentTitle.map { "的「\($0)」下" } ?? "顶层")创建页面「\(title)」。")
            }
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("返回编辑") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : isEdit ? "保存" : "创建", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || nothing || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                switch target {
                case .edit(let id):
                    _ = try await API.shared.wikiSave(page: id, title: title, xhtml: xhtml, fragments: session.fragments, baseVersion: session.version, minorEdit: minor, message: message)
                    toast("已保存到 Wiki")
                    onSaved(id)
                case .new(let r):
                    let id = try await API.shared.wikiCreate(space: r.space, parent: r.parent, title: title, xhtml: xhtml, fragments: session.fragments)
                    toast("已创建页面")
                    onSaved(id)
                }
            } catch {
                self.error = errorMessage(error)
            }
            saving = false
        }
    }
}
