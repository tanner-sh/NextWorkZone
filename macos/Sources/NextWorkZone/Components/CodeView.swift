import AppKit
import SwiftUI

/// 代码查看：等宽字体、语法高亮、行号，可以连续选中复制（不含行号）。
struct CodeView: NSViewRepresentable {
    var code: String
    var path: String

    /// 超过这个大小的文件不做语法高亮，避免卡顿。
    static let highlightLimit = 300 * 1024

    static func language(of path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" { return "bash" }
        let ext = (name as NSString).pathExtension
        let map = ["kt": "kotlin", "py": "python", "rb": "ruby", "rs": "rust", "sh": "bash", "zsh": "bash", "yml": "yaml", "ps1": "powershell", "md": "markdown"]
        return map[ext] ?? ext
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 8, height: 8)
        // 不自动折行，横向滚动
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let ruler = LineNumberRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, context.coordinator.shown != code.hashValue ^ path.hashValue else { return }
        context.coordinator.shown = code.hashValue ^ path.hashValue
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if code.utf8.count <= Self.highlightLimit { CodeHighlight.apply(text, lang: Self.language(of: path), font: font) }
        tv.textStorage?.setAttributedString(text)
        scroll.verticalRulerView?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown = 0
    }
}

/// 行号栏（TextKit 1）。
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        let string = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // 可见范围之前有多少行
        var line = 1
        string.enumerateSubstrings(in: NSRange(location: 0, length: chars.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        var index = chars.location
        let inset = tv.textContainerInset.height
        while index < NSMaxRange(chars) {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil)
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let y = lineRect.minY + inset - visible.minY
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (lineRect.height - size.height) / 2), withAttributes: attrs)
            line += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}
