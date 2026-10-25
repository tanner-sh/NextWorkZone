import Foundation

/// 编辑模式保留占位编号；发布模式把本地图片转换为待上传的附件引用。
public enum XHTML {
    public struct Storage: Codable, Hashable, Sendable {
        public var storage: String
        public var assets: [String]
        public init(storage: String, assets: [String]) { self.storage = storage; self.assets = assets }
    }

    public static func write(_ doc: RichDoc) -> String {
        var writer = Writer(publish: false)
        return writer.blocks(doc.blocks)
    }

    public static func markdownToStorage(_ markdown: String) -> Storage {
        var writer = Writer(publish: true)
        let storage = writer.blocks(Markdown.parse(markdown).blocks)
        return Storage(storage: storage, assets: writer.assets)
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private struct Writer {
        var publish: Bool
        var assets: [String] = []

        mutating func blocks(_ list: [RichBlock]) -> String { list.map { block($0) }.joined() }

        mutating func block(_ b: RichBlock) -> String {
            switch b {
            case .para(let inl): return "<p>\(inlines(inl))</p>"
            case .heading(let level, let inl, _):
                let level = min(6, max(1, level))
                return "<h\(level)>\(inlines(inl))</h\(level)>"
            case .list(let ordered, _, let items):
                let tag = ordered ? "ol" : "ul"
                let body = items.map { item in
                    var body = item.task.map { $0.done ? "☑ " : "☐ " } ?? ""
                    if case .para(let inl) = item.blocks.first {
                        body += inlines(inl) + blocks(Array(item.blocks.dropFirst()))
                    } else { body += blocks(item.blocks) }
                    return "<li>\(body)</li>"
                }.joined()
                return "<\(tag)>\(body)</\(tag)>"
            case .quote(let bs): return "<blockquote>\(blocks(bs))</blockquote>"
            case .code(let lang, let text):
                let param = lang.isEmpty ? "" : "<ac:parameter ac:name=\"language\">\(escape(lang))</ac:parameter>"
                return "<ac:structured-macro ac:name=\"code\">\(param)<ac:plain-text-body><![CDATA[\(text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>"))]]></ac:plain-text-body></ac:structured-macro>"
            case .table(let rows):
                return "<table><tbody>" + rows.map { row in
                    "<tr>" + row.cells.map { cell in
                        let tag = cell.head ? "th" : "td"
                        let attrs = (cell.colspan > 1 ? " colspan=\"\(cell.colspan)\"" : "") + (cell.rowspan > 1 ? " rowspan=\"\(cell.rowspan)\"" : "")
                        return "<\(tag)\(attrs)>\(blocks(cell.blocks))</\(tag)>"
                    }.joined() + "</tr>"
                }.joined() + "</tbody></table>"
            case .rule: return "<hr />"
            case .panel(let kind, let title, let bs):
                let name = ["info", "note", "warning", "tip", "panel", "expand"].contains(kind) ? kind : "panel"
                let param = title.isEmpty ? "" : "<ac:parameter ac:name=\"title\">\(escape(title))</ac:parameter>"
                return "<ac:structured-macro ac:name=\"\(name)\">\(param)<ac:rich-text-body>\(blocks(bs))</ac:rich-text-body></ac:structured-macro>"
            case .opaque(let o): return marker(o.n, label: o.label)
            case .marker(let n): return marker(n)
            }
        }

        func marker(_ n: Int, label: String = "") -> String {
            publish ? (label.isEmpty ? "" : "<p>\(escape(label))</p>") : "<!--nwz:\(n)-->"
        }

        mutating func inlines(_ list: [RichInline]) -> String {
            list.map { item in
                switch item {
                case .text(let s, let marks, let link, let color):
                    var text = escape(s)
                    for (mark, tag) in [(Marks.code, "code"), (.sub, "sub"), (.sup, "sup"), (.strike, "s"), (.underline, "u"), (.italic, "em"), (.bold, "strong"), (.mark, "span")] where marks.contains(mark) {
                        text = mark == .mark ? "<span style=\"background-color: rgb(255,255,0);\">\(text)</span>" : "<\(tag)>\(text)</\(tag)>"
                    }
                    if let color { text = "<span style=\"color: \(escape(color));\">\(text)</span>" }
                    if let link, !link.hasPrefix("ws://") { return "<a href=\"\(escape(link))\">\(text)</a>" }
                    return text
                case .br: return "<br />"
                case .image(let image):
                    if image.src.hasPrefix("ws://asset/") {
                        let id = String(image.src.dropFirst(11))
                        if !assets.contains(id) { assets.append(id) }
                        return "<ac:image><ri:attachment ri:filename=\"ws-asset:\(escape(id))\" /></ac:image>"
                    }
                    if image.src.hasPrefix("attachment:") {
                        return "<ac:image><ri:attachment ri:filename=\"\(escape(String(image.src.dropFirst(11))))\" /></ac:image>"
                    }
                    return "<ac:image><ri:url ri:value=\"\(escape(image.src))\" /></ac:image>"
                case .issue(let key): return "<ac:structured-macro ac:name=\"jira\"><ac:parameter ac:name=\"key\">\(escape(key))</ac:parameter></ac:structured-macro>"
                case .status(let text, let color):
                    let colour = ["green": "Green", "red": "Red", "yellow": "Yellow", "blue": "Blue"][color] ?? "Grey"
                    return "<ac:structured-macro ac:name=\"status\"><ac:parameter ac:name=\"colour\">\(colour)</ac:parameter><ac:parameter ac:name=\"title\">\(escape(text))</ac:parameter></ac:structured-macro>"
                case .mention(let name, _): return escape("@" + name)
                case .attachment(let file): return escape(file)
                case .opaque(let o): return marker(o.n, label: o.label)
                case .marker(let n): return marker(n)
                }
            }.joined()
        }
    }
}
