import AppKit
import SwiftUI

/// Jira 字段的富文本编辑器：可视化模式下编辑 Jira 渲染出的内容，修改后转换回 wiki 标记；文本模式直接编辑 wiki 标记。
/// 可视化模式下未做修改时保持原始 wiki 不变，避免无谓的格式变化。
struct JiraTextEditor: View {
    @Binding var text: String
    /// 用于解析 `!附件名!`；创建问题时为空
    var issueKey: String?
    /// 粘贴图片后回调；不提供时不支持粘贴图片
    var onImage: ((PendingImage) -> Void)?
    var minHeight: CGFloat = 80
    var placeholder = ""
    var onSubmit: (() -> Void)? = nil

    private static let modeKey = "nextworkzone.jira.editorMode"
    /// 渲染前把待上传图片换成占位地址，渲染后再换回本地预览，否则 Jira 会报“找不到附件”
    private static let pendingPrefix = "https://pending.nextworkzone.invalid/"
    private static let colors = ["#de350b", "#ff991f", "#00875a", "#0065ff", "#6554c0", "#97a0af"]

    @State private var visual = AppPreferences.shared.string(forKey: JiraTextEditor.modeKey) != "text"
    @State private var controller = RichEditorController()
    @State private var doc: RichDoc?
    /// 最近一次载入或产生的 wiki；外部传入的值与之不同时说明内容被外部替换，需要重新渲染
    @State private var emitted: String?
    @State private var loading = false
    @State private var warning: String?
    @State private var error: String?
    /// 本次粘贴的图片：文件名 → 本地路径
    @State private var previews: [String: String] = [:]
    @State private var converting = Task<Void, Never> {}
    @State private var linkDraft: String?
    @State private var mention: String?
    @State private var users: [UserRef] = []
    @State private var activeUser = 0
    @State private var userSearch = Debouncer()
    /// 文本模式中替换光标前的文字
    @State private var plainInserter = MarkupTextView.Inserter()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if visual { toolbar }
            ZStack(alignment: .topLeading) {
                if visual {
                    if let doc {
                        RichEditorView(
                            doc: doc,
                            service: .jira,
                            controller: controller,
                            placeholder: placeholder,
                            minHeight: minHeight,
                            onChange: convert,
                            onOpenLink: { Links.open($0) },
                            onOpenIssue: { AppModel.shared.navigate(NavTarget(.jira, issueKey: $0)) },
                            onImage: onImage == nil ? nil : { data, mime, index in try await pasteImage(data, mime: mime, index: index) },
                            submit: onSubmit,
                            onMention: mentionChanged,
                            onKey: mentionKey
                        )
                    } else {
                        Color.clear.frame(height: minHeight)
                    }
                    if loading { ProgressView().controlSize(.small).padding(6) }
                } else {
                    MarkupTextView(text: $text, minHeight: minHeight, submit: onSubmit, onMention: mentionChanged, onKey: mentionKey, inserter: plainInserter)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if let mention { mentionList(mention) }
            if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Picker("", selection: Binding(get: { visual }, set: switchMode)) {
                    Text("可视化").tag(true)
                    Text("文本").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Text(!visual ? "Jira wiki 标记语法 · 输入 @ 提及同事" : onImage != nil ? "可直接粘贴截图 · 输入 @ 提及同事" : "输入 @ 提及同事")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(visual)|\(text)") { if visual && text != emitted { await load(text) } }
    }

    // MARK: wiki ⇄ 可视化

    private func load(_ wiki: String) async {
        emitted = wiki
        error = nil
        guard !wiki.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            doc = .empty
            warning = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            var markup = wiki
            for name in previews.keys {
                markup = markup.replacingOccurrences(of: "!\(name)", with: "!\(Self.pendingPrefix)\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)")
            }
            let html = try await API.shared.jiraRenderWiki(markup, issueKey: issueKey)
            var rendered = try await Rich.fromHTML(html)
            rendered = mapImages(rendered) { img in
                guard img.src.hasPrefix(Self.pendingPrefix) else { return img }
                let name = String(img.src.dropFirst(Self.pendingPrefix.count)).removingPercentEncoding ?? ""
                var out = img
                out.src = previews[name].map { URL(fileURLWithPath: $0).absoluteString } ?? img.src
                out.file = name
                return out
            }
            // 渲染期间内容又被替换
            guard emitted == wiki else { return }
            var unsupported = false
            rendered.walk { if case .opaque = $0 { unsupported = true } }
            warning = unsupported ? "内容包含可视化模式无法完整保留的格式（宏或插件内容），在此模式下修改可能丢失这些格式，建议切换到文本模式编辑。" : nil
            doc = rendered
        } catch {
            self.error = "无法显示可视化内容：\(errorMessage(error))"
            doc = doc ?? .empty
        }
    }

    /// 按顺序转换，避免较早的结果覆盖较新的。
    private func convert(_ next: RichDoc) {
        let previous = converting
        converting = Task {
            await previous.value
            do {
                let wiki = try await Rich.toWiki(next)
                emitted = wiki
                text = wiki
            } catch {
                self.error = errorMessage(error)
            }
        }
    }

    private func switchMode(_ toVisual: Bool) {
        guard toVisual != visual else { return }
        if !toVisual, let current = controller.doc {
            // 立即提交尚未转换的修改
            Task {
                await converting.value
                if let wiki = try? await Rich.toWiki(current), current != doc {
                    emitted = wiki
                    text = wiki
                }
            }
        }
        if toVisual { emitted = nil }
        visual = toVisual
        AppPreferences.shared.set(toVisual ? "visual" : "text", forKey: Self.modeKey)
    }

    private func mapImages(_ doc: RichDoc, _ f: (RichImage) -> RichImage) -> RichDoc {
        func inl(_ list: [RichInline]) -> [RichInline] { list.map { if case .image(let img) = $0 { return .image(f(img)) } else { return $0 } } }
        func blocks(_ list: [RichBlock]) -> [RichBlock] {
            list.map { b in
                switch b {
                case .para(let l): return .para(inl(l))
                case .heading(let level, let l, let id): return .heading(level: level, inl(l), id: id)
                case .list(let o, let s, let items): return .list(ordered: o, start: s, items: items.map { RichItem(task: $0.task, blocks: blocks($0.blocks)) })
                case .quote(let bs): return .quote(blocks(bs))
                case .panel(let k, let t, let bs): return .panel(kind: k, title: t, blocks: blocks(bs))
                case .table(let rows): return .table(rows.map { RichRow(cells: $0.cells.map { RichCell(head: $0.head, blocks: blocks($0.blocks), colspan: $0.colspan, rowspan: $0.rowspan) }) })
                default: return b
                }
            }
        }
        return RichDoc(blocks: blocks(doc.blocks))
    }

    // MARK: 粘贴图片

    /// 与 Jira 网页粘贴截图的命名方式一致：image-2026-10-22-09-30-15-123.png
    private static func imageName(mime: String, index: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
        let ext = (mime.components(separatedBy: "/").last ?? "png").replacingOccurrences(of: "jpeg", with: "jpg")
        return "image-\(f.string(from: Date()))\(index > 0 ? "-\(index)" : "").\(ext)"
    }

    private func pasteImage(_ data: Data, mime: String, index: Int) async throws -> RichImage {
        let filename = Self.imageName(mime: mime, index: index)
        let path = try await API.shared.jiraSavePastedImage(base64: data.base64EncodedString(), filename: filename)
        previews[filename] = path
        onImage?(PendingImage(filename: filename, path: path))
        return RichImage(src: URL(fileURLWithPath: path).absoluteString, file: filename)
    }

    // MARK: @提及

    private func mentionChanged(_ query: String?) {
        guard query != mention else { return }
        mention = query
        activeUser = 0
        guard let query, !query.isEmpty else {
            users = []
            return
        }
        userSearch.run(after: .milliseconds(200)) {
            let list = (try? await API.shared.jiraFindUsers(query, field: "mention", issueKey: issueKey, projectKey: nil)) ?? []
            guard mention == query else { return }
            users = Array(list.prefix(8))
            activeUser = 0
        }
    }

    /// 候选列表的上下键、回车、Esc。
    private func mentionKey(_ event: NSEvent) -> Bool {
        guard mention != nil else { return false }
        switch event.keyCode {
        case 53:
            mention = nil
            return true
        case 125, 126:
            guard !users.isEmpty else { return false }
            activeUser = (activeUser + (event.keyCode == 125 ? 1 : users.count - 1)) % users.count
            return true
        case 36, 76, 48:
            guard users.indices.contains(activeUser) else { return false }
            pick(users[activeUser])
            return true
        default:
            return false
        }
    }

    private func pick(_ user: UserRef) {
        guard let query = mention else { return }
        mention = nil
        if visual {
            controller.insertInline(.mention(name: user.displayName, user: user.name), replacing: (query as NSString).length + 1)
            controller.focus()
        } else {
            plainInserter.replaceBeforeCaret((query as NSString).length + 1, with: "[~\(user.name)] ")
        }
    }

    private func mentionList(_ query: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if query.isEmpty {
                Text("输入姓名或用户名").font(.caption).foregroundStyle(.secondary).padding(6)
            } else if users.isEmpty {
                Text("没有匹配的用户").font(.caption).foregroundStyle(.secondary).padding(6)
            }
            ForEach(Array(users.enumerated()), id: \.element.name) { i, u in
                HStack {
                    Avatar(name: u.displayName, size: 18)
                    Text(u.displayName)
                    Text(u.name).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(i == activeUser ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .rowTap { pick(u) }
            }
        }
        .padding(4)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4, y: 2)
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("正文") { if let h = controller.heading { controller.toggleHeading(h) } }
                ForEach(1...4, id: \.self) { level in Button("标题 \(level)") { controller.toggleHeading(level) } }
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("段落格式")
            tool("bold", "粗体（⌘B）", controller.marks.contains(.bold)) { controller.toggleMark(.bold) }
            tool("italic", "斜体（⌘I）", controller.marks.contains(.italic)) { controller.toggleMark(.italic) }
            tool("underline", "下划线（⌘U）", controller.marks.contains(.underline)) { controller.toggleMark(.underline) }
            tool("strikethrough", "删除线", controller.marks.contains(.strike)) { controller.toggleMark(.strike) }
            tool("chevron.left.forwardslash.chevron.right", "行内代码", controller.marks.contains(.code)) { controller.toggleMark(.code) }
            Menu {
                Button("默认颜色") { controller.setColor(nil) }
                ForEach(Self.colors, id: \.self) { c in
                    Button { controller.setColor(c) } label: { Label(c, systemImage: "circle.fill").foregroundStyle(ClipFmt.color(c)) }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("文字颜色")
            tool("link", "链接", controller.link != nil) { linkDraft = controller.link ?? "https://" }
            Divider().frame(height: 14)
            tool("list.bullet", "无序列表", controller.list == .bullet) { controller.toggleList(.bullet) }
            tool("list.number", "有序列表", controller.list == .ordered) { controller.toggleList(.ordered) }
            tool("text.quote", "引用", controller.quote) { controller.toggleQuote() }
            tool("curlybraces.square", "代码块（原样显示）", controller.code) { controller.toggleCode() }
            tool("tablecells", "插入表格", false) { controller.insertTable() }
            tool("minus", "分隔线", false) { controller.insertRule() }
            if controller.table {
                Divider().frame(height: 14)
                ForEach([("+行", RichOps.TableOp.addRow), ("+列", .addCol), ("−行", .deleteRow), ("−列", .deleteCol), ("删表", .deleteTable)], id: \.0) { title, op in
                    Button(title) { controller.tableOp(op) }.font(.caption)
                }
            }
            if let draft = linkDraft {
                TextField("", text: Binding(get: { draft }, set: { linkDraft = $0 }), prompt: Text("链接地址"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(applyLink)
                    .onKeyPress(.escape) { linkDraft = nil; return .handled }
                Button("确定", action: applyLink).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
    }

    private func tool(_ icon: String, _ title: String, _ active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 22)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .help(title)
    }

    private func applyLink() {
        let url = linkDraft?.trimmingCharacters(in: .whitespaces) ?? ""
        linkDraft = nil
        controller.setLink(url.isEmpty || url == "https://" ? nil : url)
        controller.focus()
    }
}

/// 文本模式（wiki 标记）的编辑框：等宽字体，高度随内容；报告光标前正在输入的 @提及，⌘↩ 提交。
struct MarkupTextView: NSViewRepresentable {
    @Binding var text: String
    var minHeight: CGFloat
    var submit: (() -> Void)?
    var onMention: (String?) -> Void
    var onKey: (NSEvent) -> Bool
    var inserter: Inserter

    /// 让外部在光标处替换文字（选中提及的用户后）。
    @MainActor
    final class Inserter {
        weak var textView: NSTextView?

        func replaceBeforeCaret(_ count: Int, with text: String) {
            guard let tv = textView else { return }
            let sel = tv.selectedRange()
            let range = NSRange(location: max(0, sel.location - count), length: min(count, sel.location) + sel.length)
            tv.insertText(text, replacementRange: range)
            tv.window?.makeFirstResponder(tv)
        }
    }

    private static let mentionPattern = try! NSRegularExpression(pattern: "(?:^|[\\s\u{00a0}(（])@([^\\s\u{00a0}@\\[\\]]{0,20})$")

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeyTextView {
        let tv = KeyTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = false
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 2
        tv.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.string = text
        return tv
    }

    func updateNSView(_ tv: KeyTextView, context: Context) {
        context.coordinator.parent = self
        tv.onKey = onKey
        inserter.textView = tv
        if tv.string != text { tv.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: KeyTextView, context: Context) -> CGSize? {
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = (proposed ?? (tv.frame.width >= RichNSTextView.minLayoutWidth ? tv.frame.width : 600)).rounded()
        guard let container = tv.textContainer, let layout = tv.layoutManager else { return nil }
        if width < RichNSTextView.minLayoutWidth { return CGSize(width: width, height: minHeight) }
        defer {
            if tv.frame.width >= RichNSTextView.minLayoutWidth { container.containerSize = NSSize(width: tv.frame.width, height: .greatestFiniteMagnitude) }
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(minHeight, ceil(layout.usedRect(for: container).height) + 8))
    }

    final class KeyTextView: NSTextView {
        var onKey: ((NSEvent) -> Bool)?

        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if newSize.width >= RichNSTextView.minLayoutWidth { textContainer?.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkupTextView!
        private var height: CGFloat = 0

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            report(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            report(tv)
        }

        private func report(_ tv: NSTextView) {
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return parent.onMention(nil) }
            let ns = tv.string as NSString
            let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let before = NSRange(location: line.location, length: sel.location - line.location)
            if let m = MarkupTextView.mentionPattern.firstMatch(in: tv.string, range: before) {
                parent.onMention(ns.substring(with: m.range(at: 1)))
            } else {
                parent.onMention(nil)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true, let submit = parent.submit {
                submit()
                return true
            }
            return false
        }
    }
}
