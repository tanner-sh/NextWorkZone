import AppKit

extension NSAttributedString.Key {
    /// 标题的序号（目录跳转）
    static let nwzHeading = NSAttributedString.Key("nwzHeading")
    /// 编辑时段落所属的块（见 RichEditor）
    static let nwzBlock = NSAttributedString.Key("nwzBlock")
    /// 编辑时行内的特殊内容（问题、提及、占位块等），整体作为一个字符
    static let nwzInline = NSAttributedString.Key("nwzInline")
    /// 文字格式（RichInline 的 marks），编辑后转回文档模型时使用
    static let nwzMarks = NSAttributedString.Key("nwzMarks")
    /// 原始的链接地址（`.link` 中的可能已补全）
    static let nwzHref = NSAttributedString.Key("nwzHref")
    /// 文字颜色（#rrggbb）
    static let nwzColor = NSAttributedString.Key("nwzColor")
    /// 编辑时列表项开头的标记（制表符、项目符号或勾选框），不属于内容
    static let nwzPrefix = NSAttributedString.Key("nwzPrefix")
}

/// 文档模型 → NSAttributedString（TextKit 1 的 NSTextView 显示和编辑）。
@MainActor
struct RichRenderer {
    var service: Service
    /// Jira 问题的概要和状态（Jira 宏、问题链接显示实时信息）
    var issues: [String: IssueSummary] = [:]
    /// 编辑模式：保留编辑所需的块信息，占位块显示为不可拆分的整体
    var editing = false
    var baseSize: CGFloat = 14
    /// 图片加载完成后通知文字视图重新排版
    var onImageLoaded: (() -> Void)?
    /// 标题序号计数
    private var headingIndex = 0

    init(service: Service, issues: [String: IssueSummary] = [:], editing: Bool = false, baseSize: CGFloat = 14, onImageLoaded: (() -> Void)? = nil) {
        self.service = service
        self.issues = issues
        self.editing = editing
        self.baseSize = baseSize
        self.onImageLoaded = onImageLoaded
    }

    var baseUrl: String { AppModel.shared.baseUrl(service) }

    // MARK: 样式

    var bodyFont: NSFont { .systemFont(ofSize: baseSize) }
    var codeFont: NSFont { .monospacedSystemFont(ofSize: baseSize - 1.5, weight: .regular) }

    func headingFont(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [baseSize * 1.6, baseSize * 1.38, baseSize * 1.2, baseSize * 1.08, baseSize, baseSize]
        return .systemFont(ofSize: sizes[max(0, min(level - 1, 5))], weight: level <= 2 ? .bold : .semibold)
    }

    /// 段落样式的上下文：缩进、所在的块（引用、代码、表格单元格）。
    struct Frame {
        var indent: CGFloat = 0
        var blocks: [NSTextBlock] = []
        var color: NSColor = .labelColor
        var font: NSFont?
        var list: [NSTextList] = []
        /// 编辑模式下段落所属的块的描述
        var path: [RichEditor.Level] = []
    }

    func paragraphStyle(_ frame: Frame, spacingBefore: CGFloat = 0, after: CGFloat? = nil, firstIndent: CGFloat? = nil) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = after ?? baseSize * 0.55
        p.paragraphSpacingBefore = spacingBefore
        p.headIndent = frame.indent
        p.firstLineHeadIndent = firstIndent ?? frame.indent
        p.textBlocks = frame.blocks
        p.textLists = frame.list
        p.tabStops = [NSTextTab(textAlignment: .left, location: frame.indent)]
        p.defaultTabInterval = 28
        return p
    }

    // MARK: 渲染

    mutating func render(_ doc: RichDoc) -> NSAttributedString {
        let out = NSMutableAttributedString()
        headingIndex = 0
        renderBlocks(doc.blocks, Frame(), out)
        // 去掉最后的换行
        if out.string.hasSuffix("\n") && !editing {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private mutating func renderBlocks(_ blocks: [RichBlock], _ frame: Frame, _ out: NSMutableAttributedString) {
        for b in blocks { renderBlock(b, frame, out) }
    }

    /// 追加一个段落：内容 + 换行，整段使用同一个段落样式。
    private func paragraph(_ content: NSAttributedString, _ style: NSParagraphStyle, _ out: NSMutableAttributedString, block: RichEditor.BlockInfo? = nil) {
        let start = out.length
        out.append(content)
        out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        let range = NSRange(location: start, length: out.length - start)
        out.addAttribute(.paragraphStyle, value: style, range: range)
        if let block { out.addAttribute(.nwzBlock, value: block, range: range) }
    }

    private mutating func renderBlock(_ b: RichBlock, _ frame: Frame, _ out: NSMutableAttributedString) {
        switch b {
        case .para(let inl):
            let content = inlines(inl, font: frame.font ?? bodyFont, color: frame.color)
            paragraph(content, paragraphStyle(frame), out, block: editing ? .init(kind: .para, path: frame.path) : nil)
        case .heading(let level, let inl, _):
            let content = NSMutableAttributedString(attributedString: inlines(inl, font: headingFont(level), color: frame.color))
            content.addAttribute(.nwzHeading, value: headingIndex, range: NSRange(location: 0, length: content.length))
            headingIndex += 1
            paragraph(content, paragraphStyle(frame, spacingBefore: baseSize * (level <= 2 ? 0.9 : 0.6), after: baseSize * 0.4), out, block: editing ? .init(kind: .heading(level), path: frame.path) : nil)
        case .list(let ordered, let start, let items):
            renderList(ordered: ordered, start: start, items: items, frame, out)
        case .quote(let blocks):
            let block = Self.fullWidthBlock()
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(.separatorColor, for: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
            block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
            var f = frame
            f.blocks.append(block)
            f.color = .secondaryLabelColor
            f.path.append(.quote)
            renderBlocks(blocks.isEmpty ? [.para([])] : blocks, f, out)
        case .code(let lang, let text):
            let block = Self.fullWidthBlock()
            block.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            block.setWidth(10, type: .absoluteValueType, for: .padding)
            block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
            block.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
            var f = frame
            f.blocks.append(block)
            let style = paragraphStyle(f, after: 0)
            style.lineSpacing = 1
            let attrs: [NSAttributedString.Key: Any] = [.font: codeFont, .foregroundColor: NSColor.labelColor]
            let info = editing ? RichEditor.BlockInfo(kind: .code(lang), path: frame.path) : nil
            let content = NSMutableAttributedString(string: text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attrs)
            if !editing { CodeHighlight.apply(content, lang: lang, font: codeFont) }
            paragraph(content, style, out, block: info)
        case .table(let rows):
            renderTable(rows, frame, out)
        case .rule:
            let rule = NSAttributedString(attachment: RuleAttachment())
            paragraph(rule, paragraphStyle(frame), out, block: editing ? .init(kind: .rule, path: frame.path) : nil)
        case .panel(let kind, let title, let blocks):
            let tint: NSColor = switch kind {
            case "info": .systemBlue
            case "note": .systemOrange
            case "warning": .systemRed
            case "tip": .systemGreen
            default: .systemGray
            }
            let block = Self.fullWidthBlock()
            block.backgroundColor = tint.withAlphaComponent(0.07)
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(tint.withAlphaComponent(0.6), for: .minX)
            block.setWidth(10, type: .absoluteValueType, for: .padding)
            block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
            var f = frame
            f.blocks.append(block)
            f.path.append(.panel(kind, title))
            if !title.isEmpty {
                let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: baseSize, weight: .semibold), .foregroundColor: NSColor.labelColor])
                paragraph(t, paragraphStyle(f, after: 4), out, block: editing ? .init(kind: .panelTitle, path: f.path) : nil)
            }
            renderBlocks(blocks.isEmpty ? [.para([])] : blocks, f, out)
        case .opaque(let o):
            let content = opaqueContent(o, font: bodyFont)
            paragraph(content, paragraphStyle(frame), out, block: editing ? .init(kind: .opaque(o), path: frame.path) : nil)
        case .marker(let n):
            guard editing else { return }
            let content = NSAttributedString(attachment: MarkerAttachment(n: n))
            paragraph(content, paragraphStyle(frame, after: 0), out, block: .init(kind: .marker(n), path: frame.path))
        }
    }

    /// 占满可用宽度的块（不设宽度时，编辑中排版可能按很窄的宽度计算）。
    private static func fullWidthBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        return block
    }

    private static let bullets = ["•", "◦", "▪"]

    private mutating func renderList(ordered: Bool, start: Int, items: [RichItem], _ frame: Frame, _ out: NSMutableAttributedString) {
        let depth = frame.list.count
        let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
        let step: CGFloat = 24
        for (i, item) in items.enumerated() {
            var f = frame
            f.indent = frame.indent + step
            f.list = frame.list + [list]
            f.path.append(.listItem(ordered: ordered, task: item.task))
            let marker: NSAttributedString
            if let task = item.task {
                marker = NSAttributedString(attachment: TaskAttachment(task: task, font: frame.font ?? bodyFont))
            } else {
                let text = ordered ? "\((start == 0 ? 1 : start) + i)." : Self.bullets[depth % Self.bullets.count]
                marker = NSAttributedString(string: text, attributes: [.font: frame.font ?? bodyFont, .foregroundColor: NSColor.secondaryLabelColor])
            }
            var blocks = item.blocks
            // 第一个段落跟在标记后面
            let first: [RichInline]
            if case .para(let inl) = blocks.first {
                first = inl
                blocks.removeFirst()
            } else {
                first = []
            }
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(string: "\t", attributes: [.font: frame.font ?? bodyFont]))
            line.append(marker)
            line.append(NSAttributedString(string: "\t", attributes: [.font: frame.font ?? bodyFont]))
            if editing { line.addAttribute(.nwzPrefix, value: true, range: NSRange(location: 0, length: line.length)) }
            line.append(inlines(first, font: frame.font ?? bodyFont, color: item.task?.done == true ? .secondaryLabelColor : frame.color))
            let style = paragraphStyle(f, after: 3, firstIndent: frame.indent)
            style.tabStops = [NSTextTab(textAlignment: .right, location: frame.indent + step - 7), NSTextTab(textAlignment: .left, location: frame.indent + step)]
            paragraph(line, style, out, block: editing ? .init(kind: .itemFirst, path: f.path) : nil)
            renderBlocks(blocks, f, out)
        }
        // 列表结束后补一点间距
        if let last = out.attribute(.paragraphStyle, at: max(out.length - 1, 0), effectiveRange: nil) as? NSParagraphStyle, frame.list.isEmpty, out.length > 0 {
            let p = last.mutableCopy() as! NSMutableParagraphStyle
            p.paragraphSpacing = baseSize * 0.55
            var range = NSRange()
            _ = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: &range)
            out.addAttribute(.paragraphStyle, value: p, range: range)
        }
    }

    private mutating func renderTable(_ rows: [RichRow], _ frame: Frame, _ out: NSMutableAttributedString) {
        // 按合并单元格算出每个单元格的列位置
        var occupied: [[Bool]] = []
        var positions: [[(col: Int, cell: RichCell)]] = []
        var columns = 0
        for (r, row) in rows.enumerated() {
            while occupied.count <= r { occupied.append([]) }
            var col = 0
            var list: [(Int, RichCell)] = []
            for cell in row.cells {
                while col < occupied[r].count && occupied[r][col] { col += 1 }
                list.append((col, cell))
                for dr in 0..<max(cell.rowspan, 1) {
                    while occupied.count <= r + dr { occupied.append([]) }
                    for dc in 0..<max(cell.colspan, 1) {
                        let c = col + dc
                        while occupied[r + dr].count <= c { occupied[r + dr].append(false) }
                        occupied[r + dr][c] = true
                    }
                }
                col += max(cell.colspan, 1)
                columns = max(columns, col)
            }
            positions.append(list)
        }
        guard columns > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setValue(100, type: .percentageValueType, for: .width)
        table.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
        for (r, list) in positions.enumerated() {
            for (col, cell) in list {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: max(cell.rowspan, 1), startingColumn: col, columnSpan: max(cell.colspan, 1))
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if cell.head { block.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.1) }
                var f = frame
                f.blocks = frame.blocks + [block]
                f.indent = 0
                f.list = []
                f.font = cell.head ? .systemFont(ofSize: baseSize - 0.5, weight: .semibold) : .systemFont(ofSize: baseSize - 0.5)
                f.path.append(.cell(row: r, col: col, head: cell.head, colspan: cell.colspan, rowspan: cell.rowspan))
                let blocks = cell.blocks.isEmpty ? [RichBlock.para([])] : cell.blocks
                let start = out.length
                renderBlocks(blocks, f, out)
                // 单元格中段落的间距小一些，最后一段不留间距
                out.enumerateAttribute(.paragraphStyle, in: NSRange(location: start, length: out.length - start)) { value, range, _ in
                    guard let p = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                    p.paragraphSpacing = range.upperBound == out.length ? 0 : 3
                    out.addAttribute(.paragraphStyle, value: p, range: range)
                }
            }
        }
    }

    // MARK: 行内

    func color(hex: String?) -> NSColor? {
        guard var h = hex?.lowercased(), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// 相对地址补全为系统下的完整地址。
    func absolute(_ url: String) -> String {
        url.hasPrefix("/") && !url.hasPrefix("//") ? baseUrl + url : url
    }

    func inlines(_ list: [RichInline], font: NSFont, color baseColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for i in list {
            switch i {
            case .text(let s, let m, let link, let c):
                var f = font
                var traits: NSFontDescriptor.SymbolicTraits = []
                if m.contains(.bold) { traits.insert(.bold) }
                if m.contains(.italic) { traits.insert(.italic) }
                if m.contains(.code) { f = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: m.contains(.bold) ? .semibold : .regular) }
                if !traits.isEmpty {
                    let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(traits))
                    f = NSFont(descriptor: d, size: f.pointSize) ?? f
                    // 中文字体没有斜体：用倾斜代替
                }
                if m.contains(.sup) || m.contains(.sub) { f = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * 0.75) ?? f }
                var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: self.color(hex: c) ?? baseColor]
                if m.contains(.italic) && !(f.fontDescriptor.symbolicTraits.contains(.italic)) { attrs[.obliqueness] = 0.18 }
                if m.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if m.contains(.strike) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if m.contains(.sup) { attrs[.baselineOffset] = font.pointSize * 0.35 }
                if m.contains(.sub) { attrs[.baselineOffset] = -font.pointSize * 0.2 }
                if m.contains(.code) { attrs[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.15) }
                if m.contains(.mark) { attrs[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35) }
                if let link {
                    attrs[.link] = absolute(link)
                    attrs[.nwzHref] = link
                }
                if m.rawValue != 0 { attrs[.nwzMarks] = m.rawValue }
                if let c { attrs[.nwzColor] = c }
                out.append(NSAttributedString(string: s, attributes: attrs))
            case .br:
                out.append(NSAttributedString(string: "\u{2028}", attributes: [.font: font]))
            case .image(let img):
                let attachment = RemoteImageAttachment(image: img, service: service, onLoaded: onImageLoaded)
                let a = NSMutableAttributedString(attachment: attachment)
                if !editing { a.addAttribute(.link, value: "nwz-image:" + absolute(img.full ?? img.src), range: NSRange(location: 0, length: a.length)) }
                if editing { a.addAttribute(.nwzInline, value: RichEditor.InlineBox(i), range: NSRange(location: 0, length: a.length)) }
                out.append(a)
            case .issue(let key):
                out.append(issue(key, font: font))
            case .status(let text, let c):
                let tint: NSColor = switch c {
                case "green": .systemGreen
                case "red": .systemRed
                case "yellow": .systemOrange
                case "blue": .systemBlue
                default: .systemGray
                }
                let a = NSMutableAttributedString(string: " \(text.uppercased()) ", attributes: [.font: NSFont.systemFont(ofSize: font.pointSize * 0.78, weight: .bold), .foregroundColor: tint, .backgroundColor: tint.withAlphaComponent(0.12)])
                if editing { a.addAttribute(.nwzInline, value: RichEditor.InlineBox(i), range: NSRange(location: 0, length: a.length)) }
                out.append(a)
            case .mention(let name, let user):
                let a = NSMutableAttributedString(string: "@\(name)", attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor])
                if !user.isEmpty && !editing { a.addAttribute(.link, value: "nwz-mention:\(user)", range: NSRange(location: 0, length: a.length)) }
                if editing { a.addAttribute(.nwzInline, value: RichEditor.InlineBox(i), range: NSRange(location: 0, length: a.length)) }
                out.append(a)
            case .attachment(let file):
                let a = NSMutableAttributedString(string: "📎 \(file)", attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor])
                if editing { a.addAttribute(.nwzInline, value: RichEditor.InlineBox(i), range: NSRange(location: 0, length: a.length)) }
                out.append(a)
            case .opaque(let o):
                let a = NSMutableAttributedString(attributedString: opaqueContent(o, font: font))
                if editing { a.addAttribute(.nwzInline, value: RichEditor.InlineBox(i), range: NSRange(location: 0, length: a.length)) }
                out.append(a)
            case .marker(let n):
                guard editing else { continue }
                let a = NSMutableAttributedString(attachment: MarkerAttachment(n: n))
                a.addAttribute(.nwzInline, value: RichEditor.InlineBox(i), range: NSRange(location: 0, length: a.length))
                out.append(a)
            }
        }
        return out
    }

    /// 不可编辑的内容：图片显示图片本身，其他显示为带说明文字的灰色块。
    private func opaqueContent(_ o: RichOpaque, font: NSFont) -> NSAttributedString {
        if let src = o.image, !src.hasPrefix("attachment:") {
            return NSAttributedString(attachment: RemoteImageAttachment(image: RichImage(src: src), service: service, onLoaded: onImageLoaded))
        }
        return NSAttributedString(attachment: OpaqueAttachment(opaque: o, service: service, font: font, issue: o.issue.flatMap { issues[$0] }))
    }

    /// Jira 问题：问题键加上实时的概要和状态。
    private func issue(_ key: String, font: NSFont) -> NSAttributedString {
        let a = NSMutableAttributedString()
        let link = "nwz-issue:\(key)"
        a.append(NSAttributedString(string: key, attributes: [.font: font, .foregroundColor: NSColor.linkColor, .link: link]))
        if let info = issues[key] {
            a.append(NSAttributedString(string: " \(info.summary) ", attributes: [.font: font, .foregroundColor: NSColor.labelColor, .link: link]))
            let tint = StatusPillColor.ns(info.status.category)
            a.append(NSAttributedString(string: " \(info.status.name) ", attributes: [.font: NSFont.systemFont(ofSize: font.pointSize * 0.78, weight: .semibold), .foregroundColor: tint, .backgroundColor: tint.withAlphaComponent(0.12)]))
        }
        if editing { a.addAttribute(.nwzInline, value: RichEditor.InlineBox(.issue(key)), range: NSRange(location: 0, length: a.length)) }
        return a
    }
}

enum StatusPillColor {
    static func ns(_ category: String) -> NSColor {
        switch category {
        case "done": .systemGreen
        case "indeterminate": .systemBlue
        default: .systemGray
        }
    }
}

// MARK: - 附件（图片、勾选框、占位块、分隔线）

/// 需要认证的图片：先占位，取回后按可用宽度缩放显示。
final class RemoteImageAttachment: NSTextAttachment {
    let info: RichImage
    let service: Service
    private var loaded = false
    /// 排版时的最大宽度
    var maxWidth: CGFloat = 600

    @MainActor
    init(image: RichImage, service: Service, onLoaded: (() -> Void)?) {
        self.info = image
        self.service = service
        super.init(data: nil, ofType: nil)
        // 占位：小方块
        let placeholder = NSImage(size: NSSize(width: 16, height: 16))
        self.image = placeholder
        bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        Task { @MainActor in
            await self.load()
            onLoaded?()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    private func load() async {
        let src = info.src
        var image: NSImage?
        if let id = src.hasPrefix("ws://asset/") ? String(src.dropFirst(11)) : nil {
            image = await ImageCache.shared.load("ws/\(id)")
        } else if src.hasPrefix("attachment:") {
            image = nil
        } else if src.hasPrefix("file://"), let url = URL(string: src) {
            // 粘贴后尚未上传的图片
            image = NSImage(contentsOf: url)
        } else if let path = ImageCache.path(service: service, src: src) {
            image = await ImageCache.shared.load(path)
        } else if let url = URL(string: src), url.scheme?.hasPrefix("http") == true {
            if let (data, _) = try? await URLSession.shared.data(from: url) { image = NSImage(data: data) }
        }
        guard let image else {
            // 加载失败（通常是尚未网页登录）：用文字占位
            self.image = Self.textImage("[图片]")
            bounds = CGRect(origin: .zero, size: self.image!.size)
            return
        }
        loaded = true
        self.image = image
        var size = image.size
        if let w = info.width, w > 0 { size = CGSize(width: CGFloat(w), height: size.height * CGFloat(w) / max(size.width, 1)) }
        if let h = info.height, h > 0, info.width == nil { size = CGSize(width: size.width * CGFloat(h) / max(size.height, 1), height: CGFloat(h)) }
        // 表情等小图标与文字同高
        if src.contains("/emoticons/") { size = CGSize(width: 16, height: 16) }
        bounds = CGRect(origin: .zero, size: size)
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> NSRect {
        var b = bounds
        let available = max((textContainer?.size.width ?? maxWidth) - 40, 40)
        if b.width > available {
            b.size = CGSize(width: available, height: b.height * available / b.width)
        }
        if b.height <= 20 { b.origin.y = -3 }
        return b
    }

    static func textImage(_ text: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (text as NSString).size(withAttributes: attrs)
        return NSImage(size: size, flipped: false) { _ in
            (text as NSString).draw(at: .zero, withAttributes: attrs)
            return true
        }
    }
}

/// 任务列表的勾选框。
final class TaskAttachment: NSTextAttachment {
    var task: RichTask

    init(task: RichTask, font: NSFont) {
        self.task = task
        super.init(data: nil, ofType: nil)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular).applying(.init(paletteColors: [task.done ? .controlAccentColor : .secondaryLabelColor]))
        image = NSImage(systemSymbolName: task.done ? "checkmark.square.fill" : "square", accessibilityDescription: task.done ? "已完成" : "未完成")?.withSymbolConfiguration(config)
        let s = image?.size ?? CGSize(width: 14, height: 14)
        bounds = CGRect(x: 0, y: -2, width: s.width, height: s.height)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 不可编辑的内容（Wiki 宏等）：显示为带说明文字的灰色块。
final class OpaqueAttachment: NSTextAttachment {
    let opaque: RichOpaque

    @MainActor
    init(opaque: RichOpaque, service: Service, font: NSFont, issue: IssueSummary? = nil) {
        self.opaque = opaque
        super.init(data: nil, ofType: nil)
        var text = opaque.label.isEmpty ? "[宏]" : opaque.label
        if let issue { text = "\(issue.key) \(issue.summary) · \(issue.status.name)" }
        let lines = text.components(separatedBy: "\n").prefix(14)
        let block = opaque.block == true
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: font.pointSize - (block ? 1.5 : 1)), .foregroundColor: NSColor.secondaryLabelColor]
        let body = lines.joined(separator: "\n") as NSString
        let size = body.boundingRect(with: CGSize(width: block ? 560 : 400, height: 1000), options: [.usesLineFragmentOrigin], attributes: attrs).size
        let pad: CGFloat = 4
        let w = ceil(size.width) + pad * 3
        let h = ceil(size.height) + pad * 2
        image = NSImage(size: CGSize(width: w, height: h), flipped: true) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            body.draw(with: CGRect(x: pad * 1.5, y: pad, width: w - pad * 3, height: h - pad * 2), options: [.usesLineFragmentOrigin], attributes: attrs)
            return true
        }
        bounds = CGRect(x: 0, y: block ? 0 : -pad - 1, width: w, height: h)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Wiki 编辑时布局容器的起止：不显示。
final class MarkerAttachment: NSTextAttachment {
    let n: Int

    init(n: Int) {
        self.n = n
        super.init(data: nil, ofType: nil)
        image = NSImage(size: CGSize(width: 1, height: 1))
        bounds = .zero
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 分隔线：占满一行的细线。
final class RuleAttachment: NSTextAttachment {
    init() {
        super.init(data: nil, ofType: nil)
        image = NSImage(size: CGSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> NSRect {
        let width = max(lineFrag.width - position.x - 10, 10)
        image = NSImage(size: CGSize(width: width, height: 9), flipped: false) { rect in
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 4, width: rect.width, height: 1).fill()
            return true
        }
        return CGRect(x: 0, y: 0, width: width, height: 9)
    }
}
