import AppKit
import SwiftUI

/// 工作空间文档编辑器：Markdown 存储，所见即所得编辑，支持任务列表、表格、图片、问题键识别和 [[ 文档链接。
struct NoteEditor<Footer: View>: View {
    /// 当前文档 id，[[ 链接列表中排除自己
    var docId: String?
    /// 内容（Markdown）；外部内容变化（例如同步）且未在编辑时更新显示
    var value: String
    var placeholder = "开始记录…  输入 [[ 链接其他文档，粘贴截图，写问题键自动关联"
    var onChange: (String) -> Void
    /// 选中文字后“转为待办”
    var onCreateTodos: (([String]) -> Void)? = nil
    /// 选中文字后“创建 Jira 问题”；第二个参数在选中内容后插入问题键
    var onCreateIssue: ((String, @escaping (String) -> Void) -> Void)? = nil
    @ViewBuilder var footer: () -> Footer

    @Environment(AppModel.self) private var model
    @State private var controller = RichEditorController()
    @State private var doc: RichDoc?
    /// 最近一次载入或保存的 Markdown
    @State private var emitted: String?
    @State private var saving = Task<Void, Never> {}
    @State private var linkDraft: String?
    @State private var docPicker = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            if let doc {
                RichEditorView(
                    doc: doc,
                    service: .confluence,
                    controller: controller,
                    placeholder: placeholder,
                    minHeight: 160,
                    onChange: save,
                    onOpenLink: openLink,
                    onOpenIssue: { model.navigate(NavTarget(.jira, issueKey: $0)) },
                    onImage: { data, mime, _ in
                        let asset = try await API.shared.wsSaveAsset(base64: data.base64EncodedString(), mime: mime)
                        return RichImage(src: "ws://asset/\(asset.id)")
                    },
                    onDocLinkTrigger: { _ in docPicker = true }
                )
                .popover(isPresented: $docPicker, arrowEdge: .bottom) {
                    DocLinkPicker(currentId: docId) { id, title in
                        docPicker = false
                        controller.insertLink(text: title.isEmpty ? "无标题" : title, href: "ws://doc/\(id)", replacing: 2)
                        controller.focus()
                    }
                }
            } else {
                LoadingView().frame(height: 160)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("⌘+点击打开链接和问题 · 输入 [[ 链接文档 · 可粘贴截图").font(.caption).foregroundStyle(.secondary)
                Spacer()
                footer()
            }
        }
        .task(id: value) { await load() }
    }

    private func load() async {
        guard value != emitted else { return }
        do {
            doc = try await Rich.fromMarkdown(value)
            emitted = value
        } catch {
            self.error = "内容解析失败：\(errorMessage(error))"
            doc = doc ?? .empty
        }
    }

    /// 按顺序转换并保存，避免较早的结果覆盖较新的。
    private func save(_ next: RichDoc) {
        let previous = saving
        saving = Task {
            await previous.value
            do {
                let md = try await Rich.toMarkdown(next)
                guard md != emitted else { return }
                emitted = md
                onChange(md)
            } catch {
                self.error = "保存失败：\(errorMessage(error))"
            }
        }
    }

    private func openLink(_ href: String) {
        if href.hasPrefix("ws://doc/") {
            let id = String(href.dropFirst(9))
            Task {
                if let target = (try? await API.shared.wsDoc(id)) ?? nil {
                    model.navigate(NavTarget(target.kind == "page" ? .kb : .notes, docId: target.id))
                }
            }
        } else {
            Links.open(href)
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 2) {
            group {
                ForEach(1...3, id: \.self) { level in
                    Button { controller.toggleHeading(level) } label: {
                        Text("H\(level)").font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 24)
                            .background(controller.heading == level ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .help("标题 \(level)")
                }
            }
            group {
                tool("bold", "粗体（⌘B）", controller.marks.contains(.bold)) { controller.toggleMark(.bold) }
                tool("italic", "斜体（⌘I）", controller.marks.contains(.italic)) { controller.toggleMark(.italic) }
                tool("strikethrough", "删除线（⇧⌘X）", controller.marks.contains(.strike)) { controller.toggleMark(.strike) }
                tool("chevron.left.forwardslash.chevron.right", "行内代码（⌘E）", controller.marks.contains(.code)) { controller.toggleMark(.code) }
                tool("link", "链接（输入 [[ 链接文档）", controller.link != nil) { linkDraft = controller.link ?? "https://" }
            }
            group {
                tool("list.bullet", "无序列表", controller.list == .bullet) { controller.toggleList(.bullet) }
                tool("list.number", "有序列表", controller.list == .ordered) { controller.toggleList(.ordered) }
                tool("checklist", "任务列表", controller.list == .task) { controller.toggleList(.task) }
                tool("text.quote", "引用", controller.quote) { controller.toggleQuote() }
                tool("curlybraces.square", "代码块", controller.code) { controller.toggleCode() }
                tool("tablecells", "插入表格", false) { controller.insertTable() }
                tool("minus", "分隔线", false) { controller.insertRule() }
            }
            group {
                tool("arrow.uturn.backward", "撤销（⌘Z）", false, disabled: !controller.canUndo) { controller.undo() }
                tool("arrow.uturn.forward", "重做（⇧⌘Z）", false, disabled: !controller.canRedo) { controller.redo() }
            }
            if controller.table {
                group {
                    textTool("+行") { controller.tableOp(.addRow) }
                    textTool("+列") { controller.tableOp(.addCol) }
                    textTool("−行") { controller.tableOp(.deleteRow) }
                    textTool("−列") { controller.tableOp(.deleteCol) }
                    textTool("删表") { controller.tableOp(.deleteTable) }
                }
            }
            if let draft = linkDraft {
                HStack(spacing: 4) {
                    TextField("", text: Binding(get: { draft }, set: { linkDraft = $0 }), prompt: Text("链接地址，留空则移除链接"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(applyLink)
                        .onKeyPress(.escape) { linkDraft = nil; return .handled }
                    Button("确定", action: applyLink).controlSize(.small)
                }
            }
            Spacer(minLength: 8)
            let selected = controller.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty, let onCreateTodos {
                Button("转为待办", systemImage: "checkmark.square") {
                    onCreateTodos(controller.selectedText.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                }
                .controlSize(.small)
                .help("每行一条待办")
            }
            if !selected.isEmpty, let onCreateIssue, model.isReady(.jira) {
                Button("创建 Jira 问题", systemImage: "smallcircle.filled.circle") {
                    onCreateIssue(controller.selectedText.replacingOccurrences(of: "\u{2028}", with: "\n")) { key in controller.insertAfterSelection(" \(key)") }
                }
                .controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 4)
            .overlay(alignment: .trailing) { Divider().frame(height: 14) }
    }

    private func tool(_ icon: String, _ title: String, _ active: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 24)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .help(title)
        .disabled(disabled)
    }

    private func textTool(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.caption).padding(.horizontal, 4)
    }

    private func applyLink() {
        let url = linkDraft?.trimmingCharacters(in: .whitespaces) ?? ""
        linkDraft = nil
        controller.setLink(url.isEmpty || url == "https://" ? nil : url)
        controller.focus()
    }
}

extension NoteEditor where Footer == EmptyView {
    init(docId: String?, value: String, placeholder: String? = nil, onChange: @escaping (String) -> Void, onCreateTodos: (([String]) -> Void)? = nil, onCreateIssue: ((String, @escaping (String) -> Void) -> Void)? = nil) {
        self.init(docId: docId, value: value, placeholder: placeholder ?? "开始记录…  输入 [[ 链接其他文档，粘贴截图，写问题键自动关联", onChange: onChange, onCreateTodos: onCreateTodos, onCreateIssue: onCreateIssue) { EmptyView() }
    }
}

/// 输入 [[ 后选择要链接的文档；没有匹配时可直接新建笔记。
struct DocLinkPicker: View {
    var currentId: String?
    var onPick: (String, String) -> Void
    @State private var query = ""
    @State private var docs: [DocSummary] = []
    @State private var index = 0

    private static let kindLabel = ["note": "笔记", "page": "知识库", "daily": "日记"]

    private var choices: [(id: String?, title: String, kind: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = docs.filter { $0.id != currentId && (q.isEmpty || $0.title.lowercased().contains(q)) }
        var list: [(String?, String, String)] = matched.prefix(8).map { ($0.id, $0.title, $0.kind) }
        if !q.isEmpty && !matched.contains(where: { $0.title.lowercased() == q }) { list.append((nil, query.trimmingCharacters(in: .whitespaces), "new")) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $query, prompt: Text("搜索文档标题"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { pick(index) }
                .onKeyPress(.downArrow) { index = min(index + 1, max(choices.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onChange(of: query) { index = 0 }
            let list = choices
            if list.isEmpty {
                Text("没有文档").font(.caption).foregroundStyle(.secondary).padding(6)
            }
            ForEach(Array(list.enumerated()), id: \.offset) { i, c in
                HStack {
                    Image(systemName: c.kind == "new" ? "plus" : c.kind == "page" ? "book" : "note.text").foregroundStyle(.secondary)
                    Text(c.kind == "new" ? "新建笔记“\(c.title)”" : (c.title.isEmpty ? "无标题" : c.title)).lineLimit(1)
                    Spacer()
                    if c.kind != "new" { Text(Self.kindLabel[c.kind] ?? "").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(i == index ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .rowTap { pick(i) }
            }
        }
        .padding(10)
        .frame(width: 320)
        .task {
            async let notes = API.shared.wsDocs("note")
            async let pages = API.shared.wsDocs("page")
            docs = ((try? await pages) ?? []) + ((try? await notes) ?? [])
        }
    }

    private func pick(_ i: Int) {
        let list = choices
        guard list.indices.contains(i) else { return }
        let c = list[i]
        if let id = c.id {
            onPick(id, c.title)
        } else {
            Task {
                guard let doc = try? await API.shared.wsSaveDoc(DocInput(kind: "note", title: c.title, content: "")) else { return }
                Events.workspaceChanged()
                onPick(doc.id, doc.title)
            }
        }
    }
}
