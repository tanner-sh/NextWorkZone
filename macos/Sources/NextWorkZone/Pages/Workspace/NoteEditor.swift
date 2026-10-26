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

    @Environment(AppModel.self) private var model
    /// 由外部提供时（DocPane 把格式栏固定在滚动区顶部）与外部的格式栏共用
    var sharedController: RichEditorController? = nil
    /// 是否在编辑器上方显示格式栏；为 false 时由外部用 NoteFormatBar 显示
    var showsToolbar = true
    @ViewBuilder var footer: () -> Footer

    @State private var ownController = RichEditorController()
    private var controller: RichEditorController { sharedController ?? ownController }
    @State private var doc: RichDoc?
    /// 最近一次载入或保存的 Markdown
    @State private var emitted: String?
    @State private var saving = Task<Void, Never> {}
    @State private var docPicker = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsToolbar { NoteFormatBar(controller: controller, onCreateTodos: onCreateTodos, onCreateIssue: onCreateIssue) }
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
}

extension NoteEditor where Footer == EmptyView {
    init(docId: String?, value: String, placeholder: String? = nil, onChange: @escaping (String) -> Void, onCreateTodos: (([String]) -> Void)? = nil, onCreateIssue: ((String, @escaping (String) -> Void) -> Void)? = nil, controller: RichEditorController? = nil, showsToolbar: Bool = true) {
        self.init(docId: docId, value: value, placeholder: placeholder ?? "开始记录…  输入 [[ 链接其他文档，粘贴截图，写问题键自动关联", onChange: onChange, onCreateTodos: onCreateTodos, onCreateIssue: onCreateIssue, sharedController: controller, showsToolbar: showsToolbar) { EmptyView() }
    }
}

/// 工作空间文档的格式栏：标题、文字样式、列表与块、撤销；在表格中时显示表格操作；选中文字后可以转为待办、创建 Jira 问题。
struct NoteFormatBar: View {
    var controller: RichEditorController
    var onCreateTodos: (([String]) -> Void)? = nil
    var onCreateIssue: ((String, @escaping (String) -> Void) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @State private var linkDraft: String?

    var body: some View {
        FormatBar {
            FormatGroup {
                ForEach(1...3, id: \.self) { level in
                    FormatTextButton(label: "H\(level)", title: "标题 \(level)", active: controller.heading == level) { controller.toggleHeading(level) }
                }
            }
            FormatGroup {
                FormatButton("bold", "粗体（⌘B）", controller.marks.contains(.bold)) { controller.toggleMark(.bold) }
                FormatButton("italic", "斜体（⌘I）", controller.marks.contains(.italic)) { controller.toggleMark(.italic) }
                FormatButton("strikethrough", "删除线（⇧⌘X）", controller.marks.contains(.strike)) { controller.toggleMark(.strike) }
                FormatButton("chevron.left.forwardslash.chevron.right", "行内代码（⌘E）", controller.marks.contains(.code)) { controller.toggleMark(.code) }
                FormatButton("link", "链接（输入 [[ 链接文档）", controller.link != nil) { linkDraft = controller.link ?? "https://" }
            }
            FormatGroup {
                FormatButton("list.bullet", "无序列表", controller.list == .bullet) { controller.toggleList(.bullet) }
                FormatButton("list.number", "有序列表", controller.list == .ordered) { controller.toggleList(.ordered) }
                FormatButton("checklist", "任务列表", controller.list == .task) { controller.toggleList(.task) }
                FormatButton("text.quote", "引用", controller.quote) { controller.toggleQuote() }
                FormatButton("curlybraces.square", "代码块", controller.code) { controller.toggleCode() }
                FormatButton("tablecells", "插入表格") { controller.insertTable() }
                FormatButton("minus", "分隔线") { controller.insertRule() }
            }
            FormatGroup {
                FormatButton("arrow.uturn.backward", "撤销（⌘Z）", disabled: !controller.canUndo) { controller.undo() }
                FormatButton("arrow.uturn.forward", "重做（⇧⌘Z）", disabled: !controller.canRedo) { controller.redo() }
            }
            if controller.table {
                FormatGroup {
                    FormatTextButton(label: "+行") { controller.tableOp(.addRow) }
                    FormatTextButton(label: "+列") { controller.tableOp(.addCol) }
                    FormatTextButton(label: "−行") { controller.tableOp(.deleteRow) }
                    FormatTextButton(label: "−列") { controller.tableOp(.deleteCol) }
                    FormatTextButton(label: "删表") { controller.tableOp(.deleteTable) }
                }
            }
            if let draft = linkDraft {
                FormatGroup {
                    TextField("", text: Binding(get: { draft }, set: { linkDraft = $0 }), prompt: Text("链接地址，留空则移除链接"))
                        .textFieldStyle(.plain)
                        .frame(width: 240)
                        .padding(.horizontal, 6)
                        .onSubmit(applyLink)
                        .onKeyPress(.escape) { linkDraft = nil; return .handled }
                    FormatTextButton(label: "确定", action: applyLink)
                }
            }
            Spacer(minLength: 8)
            let selected = controller.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty && (onCreateTodos != nil || (onCreateIssue != nil && model.isReady(.jira))) {
                FormatGroup {
                    if let onCreateTodos {
                        Button("转为待办", systemImage: "checkmark.square") {
                            onCreateTodos(controller.selectedText.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                        }
                        .padding(.horizontal, 4)
                        .help("每行一条待办")
                    }
                    if let onCreateIssue, model.isReady(.jira) {
                        Button("创建 Jira 问题", systemImage: "smallcircle.filled.circle") {
                            onCreateIssue(controller.selectedText.replacingOccurrences(of: "\u{2028}", with: "\n")) { key in controller.insertAfterSelection(" \(key)") }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .controlSize(.small)
            }
        }
        .animation(.snappy(duration: 0.2), value: controller.table)
    }

    private func applyLink() {
        let url = linkDraft?.trimmingCharacters(in: .whitespaces) ?? ""
        linkDraft = nil
        controller.setLink(url.isEmpty || url == "https://" ? nil : url)
        controller.focus()
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
                .selectionBackground(i == index, radius: 5)
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
