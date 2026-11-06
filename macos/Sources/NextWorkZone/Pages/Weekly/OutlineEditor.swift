import AppKit
import SwiftUI

struct EditorItem: Identifiable, Hashable {
    var id: Int
    var level: Int
    var text: String

    private nonisolated(unsafe) static var nextId = 1
    static func newId() -> Int {
        nextId += 1
        return nextId
    }

    static func withIds(_ items: [OutlineItem]) -> [EditorItem] { items.map { EditorItem(id: newId(), level: $0.level, text: $0.text) } }
    static func withoutIds(_ items: [EditorItem]) -> [OutlineItem] {
        items.map { OutlineItem(level: $0.level, text: $0.text) }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// 大纲式列表编辑器：整栏是一个文本视图，每段是一项，可以跨项拖选、复制。
/// 回车新增一项（在光标处拆分），Tab / Shift+Tab 调整所选各项的层级，行首退格降级或与上一项合并，
/// 粘贴多行文本时按行拆分（行首空格或“-”表示层级），复制多项时按层级缩进。
struct OutlineEditor: NSViewRepresentable {
    @Binding var items: [EditorItem]
    var placeholder: String

    static let maxLevel = 4
    /// 每一级的缩进
    static let indent: CGFloat = 22
    /// 圆点加上与文字的间距
    static let bulletWidth: CGFloat = 14

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.parent = self
        return c
    }

    func makeNSView(context: Context) -> OutlineTextView {
        let view = OutlineTextView(usingTextLayoutManager: false)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.usesRuler = false
        // “--100%”不能被换成破折号，引号也保持原样
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.typingAttributes = Self.attributes(level: 0)
        view.delegate = context.coordinator
        context.coordinator.view = view
        view.placeholder = placeholder
        context.coordinator.load(items)
        return view
    }

    func updateNSView(_ view: OutlineTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if view.placeholder != placeholder {
            view.placeholder = placeholder
            view.needsDisplay = true
        }
        // 外部改了内容（加载、插入草稿）才重建文字；自己编辑产生的变化已经一致
        if !view.hasMarkedText(), Coordinator.lines(items) != view.lines() { c.load(items) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: OutlineTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let frameWidth = view.frame.width
        let width = (proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? (frameWidth >= 50 ? frameWidth : 600)).rounded()
        guard width >= 50 else { return CGSize(width: width, height: view.frame.height) }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).height
        if view.string.isEmpty { height = max(height, Self.font(level: 0).boundingRectForFont.height) }
        if frameWidth >= 50 { container.containerSize = NSSize(width: frameWidth, height: CGFloat.greatestFiniteMagnitude) }
        return CGSize(width: width, height: ceil(height + view.textContainerInset.height * 2))
    }

    // MARK: 样式

    static let levelKey = NSAttributedString.Key("nwzOutlineLevel")

    static func font(level: Int) -> NSFont { .systemFont(ofSize: 14, weight: level == 0 ? .semibold : .regular) }

    static func attributes(level: Int) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = CGFloat(level) * indent + bulletWidth
        style.headIndent = style.firstLineHeadIndent
        style.paragraphSpacing = 3
        style.lineSpacing = 1
        return [.font: font(level: level), .foregroundColor: NSColor.textColor, .paragraphStyle: style, levelKey: level]
    }

    static func attributed(_ lines: [(level: Int, text: String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            out.append(NSAttributedString(string: line.text + (i < lines.count - 1 ? "\n" : ""), attributes: attributes(level: line.level)))
        }
        return out
    }

    /// 把多行文本解析为大纲：每 2 个空格或 1 个 Tab 为一级缩进，行首的“-”“*”“•”会被去掉。
    static func parseLines(_ text: String) -> [OutlineItem] {
        text.components(separatedBy: .newlines).compactMap { line in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let width = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let content = line.trimmingCharacters(in: .whitespaces).replacing(/^[-*•]\s*/, with: "")
            return content.isEmpty ? nil : OutlineItem(level: width / 2, text: content)
        }
    }

    struct Line: Equatable {
        var level: Int
        var text: String
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OutlineEditor!
        weak var view: OutlineTextView?

        static func lines(_ items: [EditorItem]) -> [Line] {
            // 空的编辑器也是一个空段落
            items.isEmpty ? [Line(level: 0, text: "")] : items.map { Line(level: $0.level, text: $0.text) }
        }

        /// 用给定的条目重建文字（不记入撤销）。
        func load(_ items: [EditorItem]) {
            guard let view, let storage = view.textStorage else { return }
            let selection = view.selectedRange()
            let lines = Self.lines(items)
            storage.setAttributedString(OutlineEditor.attributed(lines.map { ($0.level, $0.text) }))
            view.trailingLevel = lines.last.flatMap { $0.text.isEmpty ? $0.level : nil }
            view.undoManager?.removeAllActions(withTarget: storage)
            let length = storage.length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            view.updateTypingAttributes()
            view.needsDisplay = true
        }

        /// 文字变化后统一每段的样式，并写回条目。
        func publish() {
            guard let view else { return }
            if !view.hasMarkedText() { view.normalize() }
            let lines = view.lines()
            let old = parent.items
            // 只有一个空段落时就是没有内容
            let next: [EditorItem] = lines == [Line(level: 0, text: "")] ? [] : lines.enumerated().map { i, line in
                EditorItem(id: i < old.count ? old[i].id : EditorItem.newId(), level: line.level, text: line.text)
            }
            if next.map({ Line(level: $0.level, text: $0.text) }) != old.map({ Line(level: $0.level, text: $0.text) }) { parent.items = next }
            view.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) { publish() }

        func textViewDidChangeSelection(_ notification: Notification) { view?.updateTypingAttributes() }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let view = textView as? OutlineTextView, replacementString != nil, !view.hasMarkedText() else { return true }
            // 新输入的文字用所在项的层级；之后最后一个空段落的层级重新按上一段推断
            view.typingAttributes = OutlineEditor.attributes(level: view.paragraphLevel(view.paragraphIndex(at: range.location)))
            view.trailingLevel = nil
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let view = textView as? OutlineTextView, !view.hasMarkedText() else { return false }
            let sel = view.selectedRange()
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                view.shiftLevels(by: 1)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                view.shiftLevels(by: -1)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                // 行首退格：有缩进时先降级，否则照常与上一项合并
                guard sel.length == 0 else { return false }
                let index = view.paragraphIndex(at: sel.location)
                guard view.paragraphRanges()[index].location == sel.location, view.paragraphLevel(index) > 0 else { return false }
                view.shiftLevels(by: -1)
                return true
            default:
                return false
            }
        }
    }
}

/// 周报大纲的文本视图：画圆点和占位文字，Tab 调整层级，粘贴和复制按大纲处理。
final class OutlineTextView: NSTextView {
    var placeholder = ""

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width >= 50, let container = textContainer else { return }
        let width = newSize.width - textContainerInset.width * 2
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: 段落

    /// 每段的范围（不含换行符），最后一个空段落长度为 0。
    func paragraphRanges() -> [NSRange] {
        let s = string as NSString
        var out: [NSRange] = []
        var start = 0
        while true {
            let r = s.range(of: "\n", range: NSRange(location: start, length: s.length - start))
            if r.location == NSNotFound {
                out.append(NSRange(location: start, length: s.length - start))
                return out
            }
            out.append(NSRange(location: start, length: r.location - start))
            start = r.location + 1
        }
    }

    func paragraphIndex(at location: Int) -> Int {
        let ranges = paragraphRanges()
        return ranges.lastIndex { $0.location <= location } ?? 0
    }

    /// 最后一个空段落没有文字记录层级：调整过层级时记在这里，否则与上一段相同。
    var trailingLevel: Int?

    /// 段落的层级：记在段落文字上；最后一个空段落见 `trailingLevel`。
    func paragraphLevel(_ index: Int, ranges: [NSRange]? = nil) -> Int {
        let ranges = ranges ?? paragraphRanges()
        guard ranges.indices.contains(index), let storage = textStorage else { return 0 }
        let r = ranges[index]
        let level: Int?
        if r.length > 0 || r.location < storage.length {
            level = storage.attribute(OutlineEditor.levelKey, at: r.location, effectiveRange: nil) as? Int
        } else {
            level = trailingLevel ?? (index > 0 ? paragraphLevel(index - 1, ranges: ranges) : 0)
        }
        return min(max(level ?? 0, 0), OutlineEditor.maxLevel)
    }

    func lines() -> [OutlineEditor.Line] {
        let s = string as NSString
        let ranges = paragraphRanges()
        return ranges.indices.map { OutlineEditor.Line(level: paragraphLevel($0, ranges: ranges), text: s.substring(with: ranges[$0])) }
    }

    /// 段落范围连同后面的换行符。
    private func fullRange(_ r: NSRange) -> NSRange {
        NSRange(location: r.location, length: min(r.length + 1, (string as NSString).length - r.location))
    }

    /// 每段的样式按段首的层级统一（合并、粘贴后同一段里可能混着不同样式）。
    func normalize() {
        guard let storage = textStorage else { return }
        let ranges = paragraphRanges()
        var changed = false
        for (i, r) in ranges.enumerated() {
            let full = fullRange(r)
            guard full.length > 0 else { continue }
            let level = paragraphLevel(i, ranges: ranges)
            var effective = NSRange()
            let current = storage.attribute(OutlineEditor.levelKey, at: full.location, longestEffectiveRange: &effective, in: full) as? Int
            var fontRange = NSRange()
            let font = storage.attribute(.font, at: full.location, longestEffectiveRange: &fontRange, in: full) as? NSFont
            if current == level, effective == full, fontRange == full, font == OutlineEditor.font(level: level) { continue }
            if !changed { storage.beginEditing() }
            changed = true
            storage.setAttributes(OutlineEditor.attributes(level: level), range: full)
        }
        if changed { storage.endEditing() }
        updateTypingAttributes()
    }

    /// 输入样式按光标所在项的层级（NSTextView 默认取前一个字符的样式，在项首时会取到上一项的）。
    func updateTypingAttributes() {
        guard !hasMarkedText() else { return }
        typingAttributes = OutlineEditor.attributes(level: paragraphLevel(paragraphIndex(at: selectedRange().location)))
    }

    /// 所选各项升级或降级（记入撤销）。第一项不能缩进，每项最多比上一项深一级。
    func shiftLevels(by delta: Int) {
        guard let storage = textStorage else { return }
        let ranges = paragraphRanges()
        let sel = selectedRange()
        let first = paragraphIndex(at: sel.location)
        let last = sel.length > 0 ? paragraphIndex(at: sel.location + sel.length - 1) : first
        var levels = ranges.indices.map { paragraphLevel($0, ranges: ranges) }
        for i in first...last {
            let maxLevel = i == 0 ? 0 : min(levels[i - 1] + 1, OutlineEditor.maxLevel)
            levels[i] = min(max(levels[i] + delta, 0), maxLevel)
        }
        let span = NSUnionRange(fullRange(ranges[first]), fullRange(ranges[last]))
        if span.length > 0 {
            guard shouldChangeText(in: span, replacementString: nil) else { return }
            storage.beginEditing()
            for i in first...last where fullRange(ranges[i]).length > 0 {
                storage.setAttributes(OutlineEditor.attributes(level: levels[i]), range: fullRange(ranges[i]))
            }
            storage.endEditing()
        }
        if ranges[last].length == 0 && ranges[last].location == storage.length { trailingLevel = levels[last] }
        setSelectedRange(sel)
        updateTypingAttributes()
        if span.length > 0 { didChangeText() } else { (delegate as? OutlineEditor.Coordinator)?.publish() }
        needsDisplay = true
    }

    // MARK: 粘贴、复制

    override func paste(_ sender: Any?) {
        pasteOutline()
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pasteOutline()
    }

    override func pasteAsRichText(_ sender: Any?) {
        pasteOutline()
    }

    /// 粘贴纯文字；多行时按行拆分为多项，放在当前项之后（当前项是空的就替换它）。
    private func pasteOutline() {
        guard var text = NSPasteboard.general.string(forType: .string), let storage = textStorage else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parsed = OutlineEditor.parseLines(text)
        guard text.contains("\n"), !parsed.isEmpty else {
            let single = text.replacingOccurrences(of: "\n", with: "")
            guard !single.isEmpty else { return }
            insertText(single, replacementRange: selectedRange())
            return
        }
        let ranges = paragraphRanges()
        let index = paragraphIndex(at: selectedRange().location)
        let base = paragraphLevel(index, ranges: ranges)
        let current = ranges[index]
        let blank = (string as NSString).substring(with: current).trimmingCharacters(in: .whitespaces).isEmpty
        let lines = parsed.map { (level: min(base + $0.level, OutlineEditor.maxLevel), text: $0.text) }
        let inserted = NSMutableAttributedString()
        if !blank { inserted.append(NSAttributedString(string: "\n", attributes: OutlineEditor.attributes(level: base))) }
        inserted.append(OutlineEditor.attributed(lines))
        let target = blank ? current : NSRange(location: NSMaxRange(current), length: 0)
        guard shouldChangeText(in: target, replacementString: inserted.string) else { return }
        storage.replaceCharacters(in: target, with: inserted)
        trailingLevel = nil
        setSelectedRange(NSRange(location: target.location + inserted.length, length: 0))
        didChangeText()
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// 复制：只在一项之内时是原文；跨项时每项一行，按层级用两个空格缩进（粘贴回来能还原层级）。
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        let sel = selectedRange()
        guard sel.length > 0 else { return false }
        let s = string as NSString
        let ranges = paragraphRanges()
        let first = paragraphIndex(at: sel.location), last = paragraphIndex(at: sel.location + sel.length - 1)
        if first == last { return pboard.setString(s.substring(with: sel), forType: .string) }
        var out: [String] = []
        for i in first...last {
            let part = NSIntersectionRange(ranges[i], sel)
            let text = ranges[i].length == 0 || part.length == 0 ? "" : s.substring(with: part)
            if i == last && text.isEmpty { continue }
            out.append(String(repeating: "  ", count: paragraphLevel(i, ranges: ranges)) + text)
        }
        return pboard.setString(out.joined(separator: "\n"), forType: .string)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout = layoutManager else { return }
        let origin = textContainerOrigin
        if string.isEmpty {
            if !placeholder.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: OutlineEditor.font(level: 0).withWeight(.regular), .foregroundColor: NSColor.placeholderTextColor]
                (placeholder as NSString).draw(at: NSPoint(x: origin.x + OutlineEditor.bulletWidth, y: origin.y), withAttributes: attrs)
            }
            return
        }
        let ranges = paragraphRanges()
        for (i, r) in ranges.enumerated() {
            let level = paragraphLevel(i, ranges: ranges)
            let font = OutlineEditor.font(level: level)
            var line: NSRect
            var baseline: CGFloat
            if r.location < (string as NSString).length {
                let glyph = layout.glyphIndexForCharacter(at: r.location)
                line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                baseline = layout.location(forGlyphAt: glyph).y
            } else {
                // 最后一个空段落画在额外的行上
                line = layout.extraLineFragmentRect
                guard line.height > 0 else { continue }
                baseline = ceil(font.ascender)
            }
            let size: CGFloat = level == 0 ? 6 : 5
            let cx = origin.x + CGFloat(level) * OutlineEditor.indent + 3
            let cy = origin.y + line.minY + baseline - font.capHeight / 2
            let dot = NSRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
            guard dot.intersects(dirtyRect) else { continue }
            (level == 0 ? NSColor.labelColor : NSColor.secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont { .systemFont(ofSize: pointSize, weight: weight) }
}

// MARK: - 草稿合并、对比

enum WeeklyText {
    /// 条目末尾的进度：--100%、------90%、– 100%、--转开发解决（与后端的规则一致）。
    nonisolated(unsafe) static let progress = try! Regex(#"^(.*?\S)\s*(?:-{2,}|–|—)\s*([^\s\-–—][^\-–—]{0,11})\s*$"#)

    /// 不含进度的内容，去掉空白和标点，用于判断是否同一条。
    static func baseText(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        let body = (try? progress.wholeMatch(in: t)).flatMap { $0.output[1].substring.map(String.init) } ?? t
        return String(body.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) })
    }

    enum Presence { case none, same, changed }

    /// 条目在周报中的情况：没有、已有且相同、已有但进度不同。
    static func presence(_ content: [EditorItem], _ text: String) -> Presence {
        let t = text.trimmingCharacters(in: .whitespaces)
        let base = baseText(text)
        guard let found = content.first(where: { $0.text.trimmingCharacters(in: .whitespaces) == t }) ?? content.first(where: { !base.isEmpty && baseText($0.text) == base }) else { return .none }
        return found.text.trimmingCharacters(in: .whitespaces) == t ? .same : .changed
    }

    /// 把 `texts` 并入 `content`：已有的同一条改为新的文字；新条目放到第 0 层名为 `group` 的分组末尾，没有这个分组时在最后新建。
    static func merge(_ content: [EditorItem], group: String?, texts: [String]) -> (next: [EditorItem], added: Int, updated: Int) {
        var next = content.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        var updated = 0
        var fresh: [String] = []
        for text in texts {
            let t = text.trimmingCharacters(in: .whitespaces)
            let base = baseText(text)
            if let i = next.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespaces) == t || (!base.isEmpty && baseText($0.text) == base) }) {
                if next[i].text.trimmingCharacters(in: .whitespaces) != t {
                    next[i].text = text
                    updated += 1
                }
            } else if !fresh.contains(text) {
                fresh.append(text)
            }
        }
        guard !fresh.isEmpty else { return (next, 0, updated) }
        let lines = fresh.map { EditorItem(id: EditorItem.newId(), level: 1, text: $0) }
        if let group, let head = next.firstIndex(where: { $0.level == 0 && $0.text.trimmingCharacters(in: .whitespaces) == group.trimmingCharacters(in: .whitespaces) }) {
            var end = head + 1
            while end < next.count, next[end].level > 0 { end += 1 }
            next.insert(contentsOf: lines, at: end)
        } else {
            if let group { next.append(EditorItem(id: EditorItem.newId(), level: 0, text: group)) }
            next += lines
        }
        return (next, fresh.count, updated)
    }

    struct DiffLine: Hashable {
        enum Kind { case same, add, del }
        var kind: Kind
        var level: Int
        var text: String
    }

    private static func key(_ i: OutlineItem) -> String { "\(i.level)\u{0}\(i.text.trimmingCharacters(in: .whitespaces))" }

    static func same(_ a: [OutlineItem], _ b: [OutlineItem]) -> Bool { a.map(key) == b.map(key) }

    /// 基于最长公共子序列的逐项对比，用于保存前展示改动。
    static func diff(_ before: [OutlineItem], _ after: [OutlineItem]) -> [DiffLine] {
        let a = before.map(key), b = after.map(key)
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && j < b.count && a[i] == b[j] {
                out.append(DiffLine(kind: .same, level: before[i].level, text: before[i].text))
                i += 1
                j += 1
            } else if j < b.count && (i >= a.count || lcs[i][j + 1] >= lcs[i + 1][j]) {
                out.append(DiffLine(kind: .add, level: after[j].level, text: after[j].text))
                j += 1
            } else {
                out.append(DiffLine(kind: .del, level: before[i].level, text: before[i].text))
                i += 1
            }
        }
        return out
    }
}

