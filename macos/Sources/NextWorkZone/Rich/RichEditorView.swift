import AppKit
import SwiftUI

/// 富文本编辑器的命令与状态（工具栏使用）。
@MainActor @Observable
final class RichEditorController {
    fileprivate weak var textView: EditorTextView?

    // 光标处的状态
    var heading: Int?
    var list: RichOps.ListKind?
    var quote = false
    var code = false
    var table = false
    var marks: Marks = []
    var link: String?
    var selectedText = ""
    var canUndo = false
    var canRedo = false
    /// 高度变化时加一，让 SwiftUI 重新计算编辑器的大小
    var version = 0

    /// 当前内容（文档模型）。
    var doc: RichDoc? { textView.map { RichFlat.build(RichFlat.parse($0.textStorage!).paras) } }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    func toggleMark(_ mark: Marks) { textView?.toggleMark(mark) }

    func toggleHeading(_ level: Int) {
        textView?.structural { paras, sel, range in RichOps.setHeading(paras, range: range, level: self.heading == level ? nil : level, caret: sel) }
    }

    func toggleList(_ kind: RichOps.ListKind) {
        textView?.structural { paras, sel, range in RichOps.toggleList(paras, range: range, kind: kind, caret: sel) }
    }

    func toggleQuote() {
        textView?.structural { paras, sel, range in RichOps.toggleQuote(paras, range: range, caret: sel) }
    }

    func toggleCode() {
        textView?.structural { paras, _, range in RichOps.toggleCode(paras, range: range) }
    }

    func insertTable() {
        textView?.structural { paras, _, range in RichOps.insertAfter(paras, index: range.upperBound, RichOps.table(rows: 3, cols: 3), caretAt: 0) }
    }

    func insertRule() {
        textView?.structural { paras, _, range in RichOps.insertAfter(paras, index: range.upperBound, [FlatPara(kind: .rule, path: [])], caretAt: 1) }
    }

    func tableOp(_ op: RichOps.TableOp) {
        textView?.structural { paras, _, range in RichOps.table(paras, at: range.lowerBound, op) }
    }

    /// 文字颜色（#rrggbb；nil 为默认颜色）。
    func setColor(_ hex: String?) { textView?.setColor(hex) }

    /// 设置或移除链接（`url` 为空时移除）。
    func setLink(_ url: String?) { textView?.setLink(url) }

    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }

    /// 在选中内容之后插入文字（例如创建问题后插入问题键）。
    func insertAfterSelection(_ text: String) {
        guard let tv = textView else { return }
        let end = tv.selectedRange().upperBound
        tv.setSelectedRange(NSRange(location: end, length: 0))
        tv.insertText(text, replacementRange: NSRange(location: end, length: 0))
    }

    /// 在光标处插入图片。
    func insertImage(src: String, file: String? = nil) { textView?.insertImage(src: src, file: file) }

    /// 在光标处插入行内单元（提及等），替换光标前 `replacing` 个字符。
    func insertInline(_ inline: RichInline, replacing: Int = 0) { textView?.insertInline(inline, replacing: replacing) }

    /// 在光标处插入链接文字（[[ 文档链接）。`replacing` 是光标前要替换掉的字符数。
    func insertLink(text: String, href: String, replacing: Int = 0) { textView?.insertLink(text: text, href: href, replacing: replacing) }
}

/// 富文本编辑器：内容为文档模型，修改后（停顿 `debounce`）回调 `onChange`。
/// 外部内容变化（例如同步）且没有在编辑时更新显示。
struct RichEditorView: NSViewRepresentable {
    var doc: RichDoc
    var service: Service
    var controller: RichEditorController
    var placeholder = ""
    var minHeight: CGFloat = 120
    var baseSize: CGFloat = 14
    var onChange: (RichDoc) -> Void
    /// ⌘+点击链接；返回 true 表示已处理
    var onOpenLink: ((String) -> Void)? = nil
    var onOpenIssue: ((String) -> Void)? = nil
    /// 粘贴、拖入图片（数据、类型、序号）：保存后返回要插入的图片
    var onImage: ((Data, String, Int) async throws -> RichImage)? = nil
    /// 拖入的其他文件：返回要插入的内容（例如附件引用），nil 表示不接受
    var onFile: ((URL) -> RichInline?)? = nil
    /// 输入 [[ 时（光标处的矩形，屏幕坐标）
    var onDocLinkTrigger: ((NSRect) -> Void)? = nil
    /// ⌘↩
    var submit: (() -> Void)? = nil
    /// 光标前正在输入的 @提及关键词（没有时为 nil）
    var onMention: ((String?) -> Void)? = nil
    /// 按键先交给它（例如提及候选列表的上下键、回车）；返回 true 表示已处理
    var onKey: ((NSEvent) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EditorTextView {
        let tv = EditorTextView(usingTextLayoutManager: false)
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.importsGraphics = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.usesFindBar = true
        tv.isVerticallyResizable = false
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 2
        // 容器宽度在 setFrameSize 中跟随视图（视图还没有宽度时不跟随）
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        context.coordinator.textView = tv
        controller.textView = tv
        return tv
    }

    func updateNSView(_ tv: EditorTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        controller.textView = tv
        tv.placeholder = placeholder
        tv.service = service
        tv.baseSize = baseSize
        // 外部内容变化（例如同步）：没在编辑时才替换
        if c.incoming != doc {
            let first = c.incoming == nil
            c.incoming = doc
            if first || (tv.window?.firstResponder !== tv && doc != c.loaded) {
                c.loaded = doc
                tv.load(doc)
            }
        }
        _ = controller.version
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: EditorTextView, context: Context) -> CGSize? {
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = (proposed ?? (tv.frame.width >= RichNSTextView.minLayoutWidth ? tv.frame.width : 600)).rounded()
        // 求最小尺寸时的 0 宽度不排版（长文按 0 宽度排版要几秒）
        if width < RichNSTextView.minLayoutWidth { return CGSize(width: width, height: minHeight) }
        return CGSize(width: width, height: max(minHeight, tv.height(forWidth: width)))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichEditorView!
        weak var textView: EditorTextView?
        /// 最近一次载入或发出的内容
        var loaded: RichDoc?
        /// 最近一次传入的内容
        var incoming: RichDoc?
        private let debounce = Debouncer()
        private var lastHeight: CGFloat = 0

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            heightMaybeChanged()
            tv.highlightIssueKeys()
            debounce.run(after: .milliseconds(400)) { [weak self] in self?.flush() }
            parent.controller.canUndo = tv.undoManager?.canUndo ?? false
            if let trigger = parent.onDocLinkTrigger, tv.justTypedDocLinkTrigger() {
                trigger(tv.caretScreenRect())
            }
            parent.onMention?(tv.mentionQuery())
        }

        func flush() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let doc = RichFlat.build(RichFlat.parse(storage).paras)
            guard doc != loaded else { return }
            loaded = doc
            parent.onChange(doc)
        }

        func heightMaybeChanged() {
            guard let tv = textView else { return }
            let h = tv.height(forWidth: tv.frame.width > 0 ? tv.frame.width : 600)
            if abs(h - lastHeight) > 0.5 {
                lastHeight = h
                parent.controller.version += 1
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            if tv.selectedRange().length > 0 || tv.mentionQuery() == nil { parent.onMention?(nil) }
            tv.cleanTypingAttributes()
            tv.updateState(parent.controller)
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
            (textView as? EditorTextView)?.snap(old: old, new: new) ?? new
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertLineBreak(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true, let submitAction = parent.submit {
                    flush()
                    submitAction()
                    return true
                }
            }
            return false
        }
    }
}

/// 编辑用的 NSTextView：结构操作、粘贴图片、⌘+点击打开链接和问题。
final class EditorTextView: NSTextView {
    var coordinator: RichEditorView.Coordinator?
    var placeholder = ""
    var service: Service = .confluence
    var baseSize: CGFloat = 14
    private var issueHighlight: Task<Void, Never>?

    private var controller: RichEditorController? { coordinator?.parent.controller }

    // MARK: 载入与重新排版

    private func renderer() -> RichRenderer {
        RichRenderer(service: service, editing: true, baseSize: baseSize) { [weak self] in self?.imageLoaded() }
    }

    /// 编辑时文档以可输入的段落结尾。
    private func editable(_ doc: RichDoc) -> RichDoc {
        var d = doc
        switch d.blocks.last {
        case .para?, .heading?: break
        default: d.blocks.append(.para([]))
        }
        return d
    }

    private func rendered(_ doc: RichDoc) -> NSAttributedString {
        var r = renderer()
        let out = NSMutableAttributedString(attributedString: r.render(editable(doc)))
        // 编辑时链接不可点击（⌘+点击打开），只显示链接样式
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value != nil else { return }
            out.removeAttribute(.link, range: range)
            if out.attribute(.nwzHref, at: range.location, effectiveRange: nil) != nil {
                out.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
        }
        return out
    }

    func load(_ doc: RichDoc) {
        let sel = selectedRange()
        textStorage?.setAttributedString(rendered(doc))
        undoManager?.removeAllActions(withTarget: textStorage!)
        setSelectedRange(NSRange(location: min(sel.location, textStorage!.length), length: 0))
        typingAttributes = baseTyping(at: 0)
        cleanTypingAttributes()
        coordinator?.heightMaybeChanged()
        highlightIssueKeys()
        needsDisplay = true
    }

    /// 段落修改后重新排版，光标放到 `selection`。
    func apply(_ paras: [FlatPara], selection: (FlatPos, FlatPos)) {
        guard let storage = textStorage else { return }
        let text = rendered(RichFlat.build(paras.isEmpty ? [.para()] : paras))
        let full = NSRange(location: 0, length: storage.length)
        breakUndoCoalescing()
        guard shouldChangeText(in: full, replacementString: text.string) else { return }
        storage.setAttributedString(text)
        didChangeText()
        breakUndoCoalescing()
        let spans = RichFlat.parse(storage).spans
        func loc(_ p: FlatPos) -> Int {
            guard !spans.isEmpty else { return 0 }
            let s = spans[max(0, min(p.para, spans.count - 1))]
            return min(s.contentStart + p.offset, s.contentEnd)
        }
        let a = loc(selection.0), b = loc(selection.1)
        setSelectedRange(NSRange(location: min(a, b), length: abs(b - a)))
        scrollRangeToVisible(selectedRange())
    }

    /// 对选中的段落执行结构操作。
    func structural(_ op: ([FlatPara], (FlatPos, FlatPos), ClosedRange<Int>) -> RichOps.Result?) {
        guard let storage = textStorage else { return }
        let (paras, spans) = RichFlat.parse(storage)
        guard !paras.isEmpty else {
            apply([.para()], selection: (FlatPos(para: 0, offset: 0), FlatPos(para: 0, offset: 0)))
            return
        }
        let sel = selectedRange()
        let a = position(sel.location, spans), b = position(sel.upperBound, spans)
        let range = a.para...max(a.para, b.para - ((b.offset == 0 && b.para > a.para && sel.length > 0) ? 1 : 0))
        guard let result = op(paras, (a, b), range) else { return }
        apply(result.paras, selection: result.selection)
        controller.map(updateState)
    }

    private func position(_ location: Int, _ spans: [ParaSpan]) -> FlatPos {
        guard let i = spans.lastIndex(where: { $0.range.location <= location }) else { return FlatPos(para: 0, offset: 0) }
        let s = spans[i]
        return FlatPos(para: i, offset: max(0, min(location, s.contentEnd) - s.contentStart))
    }

    private func imageLoaded() {
        guard let lm = layoutManager, let storage = textStorage else { return }
        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        coordinator?.heightMaybeChanged()
        needsDisplay = true
    }

    // MARK: 大小

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager, width >= RichNSTextView.minLayoutWidth else { return 0 }
        defer {
            if frame.width >= RichNSTextView.minLayoutWidth, abs(container.containerSize.width - frame.width) > 0.5 {
                container.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
            }
        }
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height + textContainerInset.height * 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        guard newSize.width >= RichNSTextView.minLayoutWidth, let container = textContainer else { return }
        if abs(container.containerSize.width - newSize.width) > 0.5 {
            container.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        }
        if widthChanged { coordinator?.heightMaybeChanged() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let s = string
        if (s.isEmpty || s == "\n"), !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: NSColor.placeholderTextColor]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height), withAttributes: attrs)
        }
    }

    // MARK: 输入属性与光标

    /// 段落的基础属性（新输入的文字使用）。
    private func baseTyping(at location: Int) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: NSColor.labelColor]
        if let storage = textStorage, storage.length > 0 {
            let at = min(location, storage.length - 1)
            for key in [NSAttributedString.Key.paragraphStyle, .nwzBlock] {
                if let v = storage.attribute(key, at: at, effectiveRange: nil) { attrs[key] = v }
            }
        } else {
            attrs[.nwzBlock] = RichEditor.BlockInfo(kind: .para, path: [])
        }
        return attrs
    }

    /// 输入的文字不应继承行内单元（问题、图片等）、列表标记和链接。
    func cleanTypingAttributes() {
        var t = typingAttributes
        var changed = false
        for key in [NSAttributedString.Key.nwzInline, .nwzPrefix, .attachment, .link, .nwzHeading] where t[key] != nil {
            t[key] = nil
            changed = true
        }
        if t[.nwzHref] != nil {
            // 链接后面输入的文字不再是链接
            t[.nwzHref] = nil
            let marks = Marks(rawValue: t[.nwzMarks] as? Int ?? 0)
            if !marks.contains(.underline) { t[.underlineStyle] = nil }
            t[.foregroundColor] = NSColor.labelColor
            changed = true
        }
        if t[.nwzBlock] == nil {
            t[.nwzBlock] = baseTyping(at: selectedRange().location)[.nwzBlock]
            changed = true
        }
        if changed { typingAttributes = t }
    }

    /// 光标不停在列表项标记中。
    func snap(old: NSRange, new: NSRange) -> NSRange {
        // 不停在最后一个换行之后（那里不属于任何段落）
        if let storage = textStorage, storage.length > 0, storage.string.hasSuffix("\n"), new.upperBound == storage.length {
            let end = storage.length - 1
            return new.length == 0 ? NSRange(location: end, length: 0) : NSRange(location: new.location, length: max(0, end - new.location))
        }
        guard new.length == 0, let storage = textStorage, new.location < storage.length,
              storage.attribute(.nwzPrefix, at: new.location, effectiveRange: nil) != nil else { return new }
        var run = NSRange()
        _ = storage.attribute(.nwzPrefix, at: new.location, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length))
        // 从内容开头向左移：到上一段的末尾
        if old.length == 0 && old.location == run.upperBound && new.location < old.location {
            return NSRange(location: max(0, run.location - 1), length: 0)
        }
        return NSRange(location: run.upperBound, length: 0)
    }

    func updateState(_ c: RichEditorController) {
        guard let storage = textStorage else { return }
        let (paras, spans) = RichFlat.parse(storage)
        let sel = selectedRange()
        c.selectedText = (string as NSString).substring(with: sel)
        c.canUndo = undoManager?.canUndo ?? false
        c.canRedo = undoManager?.canRedo ?? false
        c.marks = Marks(rawValue: typingAttributes[.nwzMarks] as? Int ?? 0)
        if sel.length > 0, sel.location < storage.length {
            c.marks = Marks(rawValue: storage.attribute(.nwzMarks, at: sel.location, effectiveRange: nil) as? Int ?? 0)
        }
        c.link = sel.location < storage.length ? storage.attribute(.nwzHref, at: sel.location, effectiveRange: nil) as? String : nil
        guard !paras.isEmpty else {
            c.heading = nil; c.list = nil; c.quote = false; c.code = false; c.table = false
            return
        }
        let p = paras[position(sel.location, spans).para]
        if case .heading(let l) = p.kind { c.heading = l } else { c.heading = nil }
        if case .code = p.kind { c.code = true } else { c.code = false }
        c.quote = p.path.contains(.quote)
        c.table = p.cellDepth != nil
        if let d = p.itemDepth, case .listItem(let ordered, let task) = p.path[d] {
            c.list = task != nil ? .task : ordered ? .ordered : .bullet
        } else {
            c.list = nil
        }
    }

    // MARK: 行内格式

    func toggleMark(_ mark: Marks) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        if sel.length == 0 {
            var t = typingAttributes
            var m = Marks(rawValue: t[.nwzMarks] as? Int ?? 0)
            if m.contains(mark) { m.remove(mark) } else { m.insert(mark) }
            Self.applyMarks(&t, m, baseSize: baseSize)
            typingAttributes = t
            controller?.marks = m
            return
        }
        // 全部已有该格式时去掉，否则加上
        var all = true
        storage.enumerateAttribute(.nwzMarks, in: sel) { v, _, stop in
            if !Marks(rawValue: v as? Int ?? 0).contains(mark) { all = false; stop.pointee = true }
        }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: sel) { attrs, r, _ in
            if attrs[.nwzInline] != nil || attrs[.nwzPrefix] != nil { return }
            var a = attrs
            var m = Marks(rawValue: a[.nwzMarks] as? Int ?? 0)
            if all { m.remove(mark) } else { m.insert(mark) }
            Self.applyMarks(&a, m, baseSize: (attrs[.font] as? NSFont)?.pointSize ?? baseSize)
            storage.setAttributes(a, range: r)
        }
        storage.endEditing()
        didChangeText()
        controller.map(updateState)
    }

    /// 按格式设置字体和装饰。
    static func applyMarks(_ a: inout [NSAttributedString.Key: Any], _ m: Marks, baseSize: CGFloat) {
        let current = a[.font] as? NSFont ?? .systemFont(ofSize: baseSize)
        let wasCode = current.fontDescriptor.symbolicTraits.contains(.monoSpace)
        var size = current.pointSize
        if wasCode && !m.contains(.code) { size += 1 }
        if !wasCode && m.contains(.code) { size -= 1 }
        // 标题本身是粗体（不是格式）：保持
        let oldMarks = Marks(rawValue: a[.nwzMarks] as? Int ?? 0)
        let headingBold = !wasCode && current.fontDescriptor.symbolicTraits.contains(.bold) && !oldMarks.contains(.bold)
        var f: NSFont = m.contains(.code)
            ? .monospacedSystemFont(ofSize: size, weight: m.contains(.bold) ? .semibold : .regular)
            : .systemFont(ofSize: size, weight: m.contains(.bold) || headingBold ? .bold : .regular)
        if m.contains(.italic) {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            f = NSFont(descriptor: d, size: f.pointSize) ?? f
            a[.obliqueness] = f.fontDescriptor.symbolicTraits.contains(.italic) ? nil : 0.18
        } else {
            a[.obliqueness] = nil
        }
        a[.font] = f
        a[.strikethroughStyle] = m.contains(.strike) ? NSUnderlineStyle.single.rawValue : nil
        if a[.nwzHref] == nil { a[.underlineStyle] = m.contains(.underline) ? NSUnderlineStyle.single.rawValue : nil }
        a[.backgroundColor] = m.contains(.code) ? NSColor.quaternaryLabelColor.withAlphaComponent(0.15) : m.contains(.mark) ? NSColor.systemYellow.withAlphaComponent(0.35) : nil
        a[.nwzMarks] = m.rawValue == 0 ? nil : m.rawValue
    }

    func setColor(_ hex: String?) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let color = hex.flatMap { renderer().color(hex: $0) } ?? .labelColor
        if sel.length == 0 {
            typingAttributes[.nwzColor] = hex
            typingAttributes[.foregroundColor] = color
            return
        }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        storage.beginEditing()
        if let hex { storage.addAttribute(.nwzColor, value: hex, range: sel) } else { storage.removeAttribute(.nwzColor, range: sel) }
        storage.addAttribute(.foregroundColor, value: color, range: sel)
        storage.endEditing()
        didChangeText()
    }

    func setLink(_ url: String?) {
        guard let storage = textStorage else { return }
        var sel = selectedRange()
        // 没有选中文字时作用于光标所在的链接
        if sel.length == 0, sel.location < storage.length, storage.attribute(.nwzHref, at: sel.location, effectiveRange: nil) != nil {
            var r = NSRange()
            _ = storage.attribute(.nwzHref, at: sel.location, longestEffectiveRange: &r, in: NSRange(location: 0, length: storage.length))
            sel = r
        }
        let href = url?.trimmingCharacters(in: .whitespaces) ?? ""
        if sel.length == 0 {
            guard !href.isEmpty else { return }
            insertLink(text: href, href: href, replacing: 0)
            return
        }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        storage.beginEditing()
        if href.isEmpty {
            storage.removeAttribute(.nwzHref, range: sel)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: sel)
            storage.removeAttribute(.underlineStyle, range: sel)
        } else {
            storage.addAttributes([.nwzHref: href, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: sel)
        }
        storage.endEditing()
        didChangeText()
    }

    func insertLink(text: String, href: String, replacing: Int) {
        let sel = selectedRange()
        let range = NSRange(location: max(0, sel.location - replacing), length: sel.length + min(replacing, sel.location))
        var attrs = typingAttributes
        attrs[.nwzHref] = href
        attrs[.foregroundColor] = NSColor.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        let s = NSMutableAttributedString(string: text, attributes: attrs)
        s.append(NSAttributedString(string: " ", attributes: baseTyping(at: range.location)))
        insertText(s, replacementRange: range)
    }

    func insertInline(_ inline: RichInline, replacing: Int) {
        let sel = selectedRange()
        let range = NSRange(location: max(0, sel.location - replacing), length: sel.length + min(replacing, sel.location))
        let r = renderer()
        let font = (typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: baseSize)
        let s = NSMutableAttributedString(attributedString: r.inlines([inline], font: font, color: .labelColor))
        let base = baseTyping(at: range.location)
        s.addAttributes(base.filter { $0.key == .paragraphStyle || $0.key == .nwzBlock }, range: NSRange(location: 0, length: s.length))
        s.removeAttribute(.link, range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: " ", attributes: base))
        insertText(s, replacementRange: range)
    }

    private static let mentionPattern = try! NSRegularExpression(pattern: "(?:^|[\\s\u{00a0}(（])@([^\\s\u{00a0}@]{0,20})$")

    /// 光标前正在输入的 @提及关键词。
    func mentionQuery() -> String? {
        let sel = selectedRange()
        guard sel.length == 0, let storage = textStorage else { return nil }
        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: sel.location, length: 0))
        let before = NSRange(location: para.location, length: sel.location - para.location)
        guard let m = Self.mentionPattern.firstMatch(in: storage.string, range: before) else { return nil }
        // 已是提及（行内单元）时不算
        if storage.attribute(.nwzInline, at: max(0, sel.location - 1), effectiveRange: nil) != nil { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    func insertImage(src: String, file: String? = nil) {
        let inline = RichInline.image(RichImage(src: src, file: file))
        let a = NSMutableAttributedString(attachment: RemoteImageAttachment(image: RichImage(src: src, file: file), service: service) { [weak self] in self?.imageLoaded() })
        var attrs = baseTyping(at: selectedRange().location)
        attrs[.nwzInline] = RichEditor.InlineBox(inline)
        a.addAttributes(attrs, range: NSRange(location: 0, length: a.length))
        insertText(a, replacementRange: selectedRange())
    }

    #if DEBUG
    /// 调试通道：执行工具栏操作。
    func debugOp(_ name: String) {
        guard let c = controller else { return }
        switch name {
        case "bold": c.toggleMark(.bold)
        case "h1": c.toggleHeading(1)
        case "h2": c.toggleHeading(2)
        case "bullet": c.toggleList(.bullet)
        case "ordered": c.toggleList(.ordered)
        case "task": c.toggleList(.task)
        case "quote": c.toggleQuote()
        case "code": c.toggleCode()
        case "table": c.insertTable()
        case "rule": c.insertRule()
        case "addRow": c.tableOp(.addRow)
        case "addCol": c.tableOp(.addCol)
        case "selectAll": selectAll(nil)
        case "undo": c.undo()
        default: break
        }
    }
    #endif

    // MARK: 按键

    override func keyDown(with event: NSEvent) {
        if coordinator?.parent.onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage else { return super.insertNewline(sender) }
        let (paras, spans) = RichFlat.parse(storage)
        let sel = selectedRange()
        guard !paras.isEmpty, sel.length == 0 else { return super.insertNewline(sender) }
        let pos = position(sel.location, spans)
        let p = paras[pos.para]
        let span = spans[pos.para]
        switch p.kind {
        case .code:
            // 代码块中换行；最后一行为空时再回车退出代码块
            if sel.location == span.contentEnd, p.code.hasSuffix("\n") {
                let r = RichOps.exitCode(paras, at: pos.para)
                apply(r.paras, selection: r.selection)
            } else {
                insertText("\u{2028}", replacementRange: sel)
            }
            return
        case .para:
            return super.insertNewline(sender)
        default:
            break
        }
        let left = RichFlat.inlines(storage, NSRange(location: span.contentStart, length: sel.location - span.contentStart))
        let right = RichFlat.inlines(storage, NSRange(location: sel.location, length: span.contentEnd - sel.location))
        if let r = RichOps.newline(paras, at: pos, left: left, right: right) {
            apply(r.paras, selection: r.selection)
        } else {
            super.insertNewline(sender)
        }
    }

    override func insertLineBreak(_ sender: Any?) {
        // ⇧↩：段落内换行
        insertText("\u{2028}", replacementRange: selectedRange())
    }

    override func deleteBackward(_ sender: Any?) {
        guard let storage = textStorage else { return super.deleteBackward(sender) }
        let sel = selectedRange()
        let (paras, spans) = RichFlat.parse(storage)
        guard sel.length == 0, !paras.isEmpty else { return super.deleteBackward(sender) }
        let pos = position(sel.location, spans)
        guard pos.offset == 0, sel.location == spans[pos.para].contentStart else { return super.deleteBackward(sender) }
        var ps = paras
        let p = ps[pos.para]
        switch p.kind {
        case .itemFirst:
            let r = RichOps.lift(ps, range: pos.para...pos.para, caret: pos)
            // 最外层的列表项退格成为普通段落；嵌套的成为上一级的一项
            apply(r.paras, selection: r.selection)
            return
        case .heading, .panelTitle:
            ps[pos.para].kind = .para
            apply(ps, selection: (pos, pos))
            return
        case .code:
            let r = RichOps.toggleCode(ps, range: pos.para...pos.para)
            apply(r.paras, selection: (pos, pos))
            return
        default:
            break
        }
        if let q = p.path.last, q == .quote {
            ps[pos.para].path.removeLast()
            apply(ps, selection: (pos, pos))
            return
        }
        guard pos.para > 0 else { return super.deleteBackward(sender) }
        let prev = ps[pos.para - 1]
        if case .marker = prev.kind {
            // 布局容器的起止标记不可见，不能删：光标移到它前面那一段的末尾
            if pos.para >= 2 { setSelectedRange(NSRange(location: spans[pos.para - 2].contentEnd, length: 0)) }
            return
        }
        if prev.isAtomic {
            // 前面是分隔线等：删掉它
            ps.remove(at: pos.para - 1)
            let c = FlatPos(para: pos.para - 1, offset: 0)
            apply(ps, selection: (c, c))
            return
        }
        if prev.cellDepth != p.cellDepth || (prev.cellDepth != nil && prev.path[prev.cellDepth!] != p.path[p.cellDepth!]) {
            // 不跨单元格合并：光标移到上一格末尾
            setSelectedRange(NSRange(location: spans[pos.para - 1].contentEnd, length: 0))
            return
        }
        if case .code = prev.kind {
            setSelectedRange(NSRange(location: spans[pos.para - 1].contentEnd, length: 0))
            return
        }
        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) {
        guard let storage = textStorage else { return super.insertTab(sender) }
        let (paras, spans) = RichFlat.parse(storage)
        guard !paras.isEmpty else { return super.insertTab(sender) }
        let pos = position(selectedRange().location, spans)
        let p = paras[pos.para]
        if p.cellDepth != nil {
            moveCell(forward: true, paras, spans, pos.para)
            return
        }
        if p.itemDepth != nil {
            structural { paras, sel, range in RichOps.sink(paras, range: range, caret: sel) }
            return
        }
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let (paras, spans) = RichFlat.parse(storage)
        guard !paras.isEmpty else { return }
        let pos = position(selectedRange().location, spans)
        if paras[pos.para].cellDepth != nil {
            moveCell(forward: false, paras, spans, pos.para)
        } else if paras[pos.para].itemDepth != nil {
            structural { paras, sel, range in RichOps.lift(paras, range: range, caret: sel.0) }
        }
    }

    private func moveCell(forward: Bool, _ paras: [FlatPara], _ spans: [ParaSpan], _ index: Int) {
        guard let d = paras[index].cellDepth else { return }
        let cell = paras[index].path[d]
        let indices = forward ? Array((index + 1)..<paras.count) : Array((0..<index).reversed())
        if let next = indices.first(where: { paras[$0].cellDepth == d && paras[$0].path[d] != cell }) {
            // 往回时到该单元格的第一段
            var target = next
            if !forward { while target > 0, paras[target - 1].cellDepth == d, paras[target - 1].path[d] == paras[next].path[d] { target -= 1 } }
            setSelectedRange(NSRange(location: spans[target].contentStart, length: forward ? 0 : 0))
        } else if forward {
            // 最后一格：增加一行
            structural { paras, _, range in RichOps.table(paras, at: range.lowerBound, .addRow) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == .command {
            switch key {
            case "b": toggleMark(.bold); return true
            case "i": toggleMark(.italic); return true
            case "u": toggleMark(.underline); return true
            case "e": toggleMark(.code); return true
            default: break
            }
        }
        if mods == [.command, .shift], key == "x" {
            toggleMark(.strike)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        guard let storage = textStorage, let lm = layoutManager, let container = textContainer else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = lm.characterIndexForGlyph(at: glyph)
        let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let onGlyph = glyphRect.contains(inContainer)
        if index < storage.length, onGlyph {
            // 勾选框
            if storage.attribute(.attachment, at: index, effectiveRange: nil) is TaskAttachment {
                let (paras, spans) = RichFlat.parse(storage)
                let pos = position(index, spans)
                if let ps = RichOps.toggleTask(paras, at: pos.para) {
                    apply(ps, selection: (FlatPos(para: pos.para, offset: paras[pos.para].contentLength), FlatPos(para: pos.para, offset: paras[pos.para].contentLength)))
                }
                return
            }
            if event.modifierFlags.contains(.command) {
                if let href = storage.attribute(.nwzHref, at: index, effectiveRange: nil) as? String {
                    coordinator?.parent.onOpenLink?(href)
                    return
                }
                if let key = issueKey(at: index) {
                    coordinator?.parent.onOpenIssue?(key)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: 问题键

    private static let issuePattern = try! NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9_]{1,15}-\\d{1,7}\\b")

    private func issueKey(at index: Int) -> String? {
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: index, length: 0))
        for m in Self.issuePattern.matches(in: string, range: para) where NSLocationInRange(index, m.range) {
            return ns.substring(with: m.range)
        }
        return nil
    }

    /// 文字中的问题键显示为链接样式（⌘+点击打开），不改变内容。
    func highlightIssueKeys() {
        issueHighlight?.cancel()
        issueHighlight = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, let lm = self.layoutManager, let storage = self.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            guard AppModel.shared.isReady(.jira) else { return }
            for m in Self.issuePattern.matches(in: storage.string, range: full) {
                if storage.attribute(.nwzInline, at: m.range.location, effectiveRange: nil) != nil || storage.attribute(.nwzHref, at: m.range.location, effectiveRange: nil) != nil { continue }
                if let info = storage.attribute(.nwzBlock, at: m.range.location, effectiveRange: nil) as? RichEditor.BlockInfo, case .code = info.kind { continue }
                lm.addTemporaryAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.linkColor.withAlphaComponent(0.35)], forCharacterRange: m.range)
            }
        }
    }

    // MARK: [[ 文档链接

    func justTypedDocLinkTrigger() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, sel.location >= 2 else { return false }
        return (string as NSString).substring(with: NSRange(location: sel.location - 2, length: 2)) == "[["
    }

    func caretScreenRect() -> NSRect {
        let r = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        return r
    }

    // MARK: 粘贴与拖入

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string, .png, .tiff, .fileURL]
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pasteImages(from: pb) { return }
        pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    /// 剪贴板或拖入的图片：保存后插入；其他文件交给 `onFile`（插入附件引用）。
    private func pasteImages(from pb: NSPasteboard) -> Bool {
        guard let onImage = coordinator?.parent.onImage else { return false }
        var images: [(Data, String)] = []
        var handledFiles = false
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"].contains(ext), let data = try? Data(contentsOf: url) else {
                    if let inline = coordinator?.parent.onFile?(url) {
                        insertInline(inline, replacing: 0)
                        insertText(" ", replacementRange: selectedRange())
                        handledFiles = true
                    }
                    continue
                }
                images.append((data, ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/\(ext)"))
            }
        } else if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            images.append((png, "image/png"))
        }
        guard !images.isEmpty else { return handledFiles }
        Task { @MainActor in
            for (i, (data, mime)) in images.enumerated() {
                do {
                    let image = try await onImage(data, mime, i)
                    self.insertImage(src: image.src, file: image.file)
                } catch {
                    toast("图片保存失败：\(errorMessage(error))", error: true)
                }
            }
        }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingSource as? NSTextView !== self, pasteImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
}
