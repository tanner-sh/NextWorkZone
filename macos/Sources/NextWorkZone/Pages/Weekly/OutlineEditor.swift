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

/// 大纲式列表编辑器：回车新增一项（在光标处拆分），Tab / Shift+Tab 调整层级，行首退格降级或与上一项合并，
/// 粘贴多行文本时按行拆分（行首空格或“-”表示层级）。
struct OutlineEditor: View {
    @Binding var items: [EditorItem]
    var placeholder: String
    @State private var focus: (id: Int, caret: Int?)?

    static let maxLevel = 4

    var body: some View {
        if items.isEmpty {
            Button(placeholder) { insertAfter(-1, level: 0) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(item.level == 0 ? Color.primary : Color.secondary)
                            .frame(width: item.level == 0 ? 6 : 5, height: item.level == 0 ? 6 : 5)
                        OutlineField(
                            text: Binding(get: { items.indices.contains(index) ? items[index].text : "" }, set: { if items.indices.contains(index) { items[index].text = $0 } }),
                            placeholder: index == 0 ? placeholder : "",
                            bold: item.level == 0,
                            focusCaret: focus?.id == item.id ? (focus?.caret ?? -1) : nil,
                            onFocused: { focus = nil },
                            onCommand: { command, caret in handle(command, index: index, caret: caret) },
                            onPaste: { text in paste(text, index: index) }
                        )
                    }
                    .padding(.leading, CGFloat(item.level) * 22)
                }
            }
        }
    }

    private func insertAfter(_ index: Int, level: Int, text: String = "") {
        let item = EditorItem(id: EditorItem.newId(), level: level, text: text)
        items.insert(item, at: index + 1)
        focus = (item.id, 0)
    }

    enum Command { case enter, tab, backtab, backspaceAtStart, up, down }

    private func handle(_ command: Command, index: Int, caret: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        let item = items[index]
        switch command {
        case .enter:
            // 在光标处拆分当前项
            let ns = item.text as NSString
            let cut = min(caret, ns.length)
            items[index].text = ns.substring(to: cut)
            let next = EditorItem(id: EditorItem.newId(), level: item.level, text: ns.substring(from: cut))
            items.insert(next, at: index + 1)
            focus = (next.id, 0)
        case .tab:
            let max = index == 0 ? 0 : min(items[index - 1].level + 1, Self.maxLevel)
            if item.level < max { items[index].level += 1 }
            focus = (item.id, caret)
        case .backtab:
            if item.level > 0 { items[index].level -= 1 }
            focus = (item.id, caret)
        case .backspaceAtStart:
            if item.level > 0 {
                items[index].level -= 1
                focus = (item.id, 0)
            } else if index > 0 {
                // 与上一项合并
                let prev = items[index - 1]
                items[index - 1].text = prev.text + item.text
                items.remove(at: index)
                focus = (prev.id, (prev.text as NSString).length)
            } else {
                return false
            }
        case .up:
            guard index > 0 else { return false }
            focus = (items[index - 1].id, nil)
        case .down:
            guard index < items.count - 1 else { return false }
            focus = (items[index + 1].id, nil)
        }
        return true
    }

    /// 粘贴多行文本：按行拆分。返回 false 时按普通文字粘贴。
    private func paste(_ text: String, index: Int) -> Bool {
        guard text.contains("\n"), items.indices.contains(index) else { return false }
        let base = items[index].level
        let pasted = Self.parseLines(text).map { EditorItem(id: EditorItem.newId(), level: min(base + $0.level, Self.maxLevel), text: $0.text) }
        guard let last = pasted.last else { return false }
        if items[index].text.trimmingCharacters(in: .whitespaces).isEmpty {
            items.replaceSubrange(index...index, with: pasted)
        } else {
            items.insert(contentsOf: pasted, at: index + 1)
        }
        focus = (last.id, nil)
        return true
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
}

/// 大纲中的一项：拦截回车、Tab、行首退格、上下键，可以知道光标位置。
private struct OutlineField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var bold: Bool
    /// 需要获得焦点时的光标位置（-1 为末尾）
    var focusCaret: Int?
    var onFocused: () -> Void
    var onCommand: (OutlineEditor.Command, Int) -> Bool
    var onPaste: (String) -> Bool

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        // 创建视图时设置初始文字就会触发代理回调，此时 updateNSView 还没来得及设置 parent
        c.parent = self
        return c
    }

    func makeNSView(context: Context) -> PasteField {
        let field = PasteField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: PasteField, context: Context) {
        context.coordinator.parent = self
        field.onPaste = onPaste
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14, weight: bold ? .semibold : .regular)
        if let caret = focusCaret {
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() {
                    let length = (field.stringValue as NSString).length
                    let pos = caret < 0 ? length : min(caret, length)
                    editor.selectedRange = NSRange(location: pos, length: 0)
                }
                onFocused()
            }
        }
    }

    final class PasteField: NSTextField {
        var onPaste: ((String) -> Bool)?
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OutlineField!

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            let sel = textView.selectedRange()
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                return parent.onCommand(.enter, sel.location)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onCommand(.tab, sel.location)
            case #selector(NSResponder.insertBacktab(_:)):
                return parent.onCommand(.backtab, sel.location)
            case #selector(NSResponder.deleteBackward(_:)):
                guard sel.location == 0 && sel.length == 0 else { return false }
                return parent.onCommand(.backspaceAtStart, 0)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCommand(.up, sel.location)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCommand(.down, sel.location)
            case #selector(NSText.paste(_:)):
                return false
            default:
                return false
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool { true }
    }
}

extension OutlineField.PasteField {
    /// 粘贴多行文本时交给大纲按行拆分。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v",
           currentEditor() != nil, let text = NSPasteboard.general.string(forType: .string), onPaste?(text) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
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
