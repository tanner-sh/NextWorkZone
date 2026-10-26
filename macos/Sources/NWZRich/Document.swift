import Foundation

/// 富文本的公共文档模型，编辑器和格式转换共用同一组类型。
public struct RichDoc: Codable, Hashable, Sendable {
    public init(blocks: [RichBlock]) { self.blocks = blocks }
    public var blocks: [RichBlock]

    public static let empty = RichDoc(blocks: [])

    public var isEmpty: Bool { blocks.isEmpty }

    /// 文档中出现的 Jira 问题键（Jira 宏、问题链接），按出现顺序去重。
    public func issueKeys(jiraBase: String) -> [String] {
        var keys: [String] = []
        func add(_ k: String) { if k.wholeMatch(of: /[A-Z][A-Z0-9_]+-\d+/) != nil, !keys.contains(k) { keys.append(k) } }
        func inl(_ list: [RichInline]) {
            for i in list {
                switch i {
                case .issue(let k): add(k)
                case .opaque(let o): if let k = o.issue { add(k) }
                case .text(_, _, let link?, _):
                    if !jiraBase.isEmpty, link.hasPrefix(jiraBase + "/browse/") { add(String(link.dropFirst(jiraBase.count + 8)).components(separatedBy: CharacterSet(charactersIn: "?#"))[0]) }
                default: break
                }
            }
        }
        walk { b in
            switch b {
            case .para(let l), .heading(_, let l, _): inl(l)
            default: break
            }
        }
        return keys
    }

    /// 依次访问所有块（含嵌套的）。
    public func walk(_ visit: (RichBlock) -> Void) {
        func go(_ list: [RichBlock]) {
            for b in list {
                visit(b)
                switch b {
                case .list(_, _, let items): items.forEach { go($0.blocks) }
                case .quote(let bs), .panel(_, _, let bs): go(bs)
                case .table(let rows): rows.forEach { $0.cells.forEach { go($0.blocks) } }
                default: break
                }
            }
        }
        go(blocks)
    }

    /// 按顶层标题切成几段，每段从一个顶层标题开始（第一段可以没有标题）。很长的页面分段显示：
    /// 整页放在一个文本视图里时，几十万点高的视图排版要将近一秒，绘制时还会出现空白或黑块。
    /// `headingStart` 是这一段之前的标题数，与 `headings` 中的 `index` 对应（含嵌套在面板、表格等里面的标题）。
    public func sections() -> [(doc: RichDoc, headingStart: Int)] {
        var out: [(doc: RichDoc, headingStart: Int)] = []
        var current: [RichBlock] = []
        var start = 0, count = 0
        for b in blocks {
            if case .heading = b, !current.isEmpty {
                out.append((RichDoc(blocks: current), start))
                current = []
                start = count
            }
            current.append(b)
            RichDoc(blocks: [b]).walk { if case .heading = $0 { count += 1 } }
        }
        if !current.isEmpty || out.isEmpty { out.append((RichDoc(blocks: current), start)) }
        return out
    }

    /// 标题（目录）。
    public var headings: [(level: Int, text: String, index: Int)] {
        var out: [(Int, String, Int)] = []
        var n = 0
        walk { b in
            if case .heading(let level, let inl, _) = b {
                let text = RichInline.plain(inl).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && level <= 4 { out.append((level, text, n)) }
                n += 1
            }
        }
        return out
    }
}

public struct RichOpaque: Codable, Hashable, Sendable {
    public init(n: Int, label: String, block: Bool? = nil, image: String? = nil, user: String? = nil, issue: String? = nil) { self.n = n; self.label = label; self.block = block; self.image = image; self.user = user; self.issue = issue }
    public var n: Int
    public var label: String
    public var block: Bool?
    public var image: String?
    public var user: String?
    public var issue: String?
}

public struct RichItem: Codable, Hashable, Sendable {
    public init(task: RichTask? = nil, blocks: [RichBlock]) { self.task = task; self.blocks = blocks }
    public var task: RichTask?
    public var blocks: [RichBlock]
}

public struct RichTask: Codable, Hashable, Sendable {
    public init(done: Bool, id: String? = nil) { self.done = done; self.id = id }
    public var done: Bool
    public var id: String?
}

public struct RichRow: Codable, Hashable, Sendable {
    public init(cells: [RichCell]) { self.cells = cells }
    public var cells: [RichCell]
}

public struct RichCell: Codable, Hashable, Sendable {
    public var head: Bool = false
    public var blocks: [RichBlock]
    public var colspan: Int = 1
    public var rowspan: Int = 1

    private enum Keys: String, CodingKey { case head, blocks, colspan, rowspan }

    public init(head: Bool = false, blocks: [RichBlock], colspan: Int = 1, rowspan: Int = 1) {
        self.head = head
        self.blocks = blocks
        self.colspan = colspan
        self.rowspan = rowspan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        head = try c.decodeIfPresent(Bool.self, forKey: .head) ?? false
        blocks = try c.decode([RichBlock].self, forKey: .blocks)
        colspan = try c.decodeIfPresent(Int.self, forKey: .colspan) ?? 1
        rowspan = try c.decodeIfPresent(Int.self, forKey: .rowspan) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        if head { try c.encode(head, forKey: .head) }
        try c.encode(blocks, forKey: .blocks)
        if colspan != 1 { try c.encode(colspan, forKey: .colspan) }
        if rowspan != 1 { try c.encode(rowspan, forKey: .rowspan) }
    }
}

public indirect enum RichBlock: Codable, Hashable, Sendable {
    case para([RichInline])
    case heading(level: Int, [RichInline], id: String?)
    case list(ordered: Bool, start: Int, items: [RichItem])
    case quote([RichBlock])
    case code(lang: String, text: String)
    case table([RichRow])
    case rule
    case panel(kind: String, title: String, blocks: [RichBlock])
    case opaque(RichOpaque)
    case marker(Int)

    private enum Keys: String, CodingKey { case t, inl, level, id, ordered, start, items, blocks, lang, text, rows, kind, title, n, label, block, image, user, issue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "para": self = .para(try c.decode([RichInline].self, forKey: .inl))
        case "heading": self = .heading(level: try c.decode(Int.self, forKey: .level), try c.decode([RichInline].self, forKey: .inl), id: try c.decodeIfPresent(String.self, forKey: .id))
        case "list": self = .list(ordered: try c.decode(Bool.self, forKey: .ordered), start: try c.decodeIfPresent(Int.self, forKey: .start) ?? 0, items: try c.decode([RichItem].self, forKey: .items))
        case "quote": self = .quote(try c.decode([RichBlock].self, forKey: .blocks))
        case "code": self = .code(lang: try c.decodeIfPresent(String.self, forKey: .lang) ?? "", text: try c.decode(String.self, forKey: .text))
        case "table": self = .table(try c.decode([RichRow].self, forKey: .rows))
        case "panel": self = .panel(kind: try c.decode(String.self, forKey: .kind), title: try c.decodeIfPresent(String.self, forKey: .title) ?? "", blocks: try c.decode([RichBlock].self, forKey: .blocks))
        case "opaque": self = .opaque(try RichOpaque(from: decoder))
        case "marker": self = .marker(try c.decode(Int.self, forKey: .n))
        default: self = .rule
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .para(let inl):
            try c.encode("para", forKey: .t)
            try c.encode(inl, forKey: .inl)
        case .heading(let level, let inl, let id):
            try c.encode("heading", forKey: .t)
            try c.encode(level, forKey: .level)
            try c.encode(inl, forKey: .inl)
            try c.encodeIfPresent(id, forKey: .id)
        case .list(let ordered, let start, let items):
            try c.encode("list", forKey: .t)
            try c.encode(ordered, forKey: .ordered)
            if start != 0 { try c.encode(start, forKey: .start) }
            try c.encode(items, forKey: .items)
        case .quote(let blocks):
            try c.encode("quote", forKey: .t)
            try c.encode(blocks, forKey: .blocks)
        case .code(let lang, let text):
            try c.encode("code", forKey: .t)
            if !lang.isEmpty { try c.encode(lang, forKey: .lang) }
            try c.encode(text, forKey: .text)
        case .table(let rows):
            try c.encode("table", forKey: .t)
            try c.encode(rows, forKey: .rows)
        case .rule:
            try c.encode("rule", forKey: .t)
        case .panel(let kind, let title, let blocks):
            try c.encode("panel", forKey: .t)
            try c.encode(kind, forKey: .kind)
            if !title.isEmpty { try c.encode(title, forKey: .title) }
            try c.encode(blocks, forKey: .blocks)
        case .opaque(let o):
            try c.encode("opaque", forKey: .t)
            try o.encode(to: encoder)
        case .marker(let n):
            try c.encode("marker", forKey: .t)
            try c.encode(n, forKey: .n)
        }
    }
}

/// 文字格式按位组合，保证跨格式转换和编辑状态一致。
public struct Marks: OptionSet, Codable, Hashable, Sendable {
    public init(rawValue: Int) { self.rawValue = rawValue }
    public let rawValue: Int
    public static let bold = Marks(rawValue: 1)
    public static let italic = Marks(rawValue: 2)
    public static let underline = Marks(rawValue: 4)
    public static let strike = Marks(rawValue: 8)
    public static let code = Marks(rawValue: 16)
    public static let sup = Marks(rawValue: 32)
    public static let sub = Marks(rawValue: 64)
    public static let mark = Marks(rawValue: 128)
}

public struct RichImage: Codable, Hashable, Sendable {
    public init(src: String, alt: String? = nil, full: String? = nil, file: String? = nil, thumb: Bool? = nil, width: Int? = nil, height: Int? = nil) { self.src = src; self.alt = alt; self.full = full; self.file = file; self.thumb = thumb; self.width = width; self.height = height }
    public var src: String
    public var alt: String?
    public var full: String?
    public var file: String?
    public var thumb: Bool?
    public var width: Int?
    public var height: Int?
}

public enum RichInline: Codable, Hashable, Sendable {
    case text(String, Marks, link: String?, color: String?)
    case image(RichImage)
    case br
    case issue(String)
    case status(text: String, color: String)
    case mention(name: String, user: String)
    case attachment(String)
    case opaque(RichOpaque)
    case marker(Int)

    private enum Keys: String, CodingKey { case t, s, m, link, color, key, text, name, user, file, n }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "text": self = .text(try c.decode(String.self, forKey: .s), Marks(rawValue: try c.decodeIfPresent(Int.self, forKey: .m) ?? 0), link: try c.decodeIfPresent(String.self, forKey: .link), color: try c.decodeIfPresent(String.self, forKey: .color))
        case "image": self = .image(try RichImage(from: decoder))
        case "issue": self = .issue(try c.decode(String.self, forKey: .key))
        case "status": self = .status(text: try c.decode(String.self, forKey: .text), color: try c.decodeIfPresent(String.self, forKey: .color) ?? "")
        case "mention": self = .mention(name: try c.decode(String.self, forKey: .name), user: try c.decodeIfPresent(String.self, forKey: .user) ?? "")
        case "attachment": self = .attachment(try c.decode(String.self, forKey: .file))
        case "opaque": self = .opaque(try RichOpaque(from: decoder))
        case "marker": self = .marker(try c.decode(Int.self, forKey: .n))
        default: self = .br
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let s, let m, let link, let color):
            try c.encode("text", forKey: .t)
            try c.encode(s, forKey: .s)
            if m.rawValue != 0 { try c.encode(m.rawValue, forKey: .m) }
            try c.encodeIfPresent(link, forKey: .link)
            try c.encodeIfPresent(color, forKey: .color)
        case .image(let img):
            try c.encode("image", forKey: .t)
            try img.encode(to: encoder)
        case .br: try c.encode("br", forKey: .t)
        case .issue(let key):
            try c.encode("issue", forKey: .t)
            try c.encode(key, forKey: .key)
        case .status(let text, let color):
            try c.encode("status", forKey: .t)
            try c.encode(text, forKey: .text)
            try c.encode(color, forKey: .color)
        case .mention(let name, let user):
            try c.encode("mention", forKey: .t)
            try c.encode(name, forKey: .name)
            try c.encode(user, forKey: .user)
        case .attachment(let file):
            try c.encode("attachment", forKey: .t)
            try c.encode(file, forKey: .file)
        case .opaque(let o):
            try c.encode("opaque", forKey: .t)
            try o.encode(to: encoder)
        case .marker(let n):
            try c.encode("marker", forKey: .t)
            try c.encode(n, forKey: .n)
        }
    }

    public static func plain(_ list: [RichInline]) -> String {
        list.map { i -> String in
            switch i {
            case .text(let s, _, _, _): s
            case .br: "\n"
            case .issue(let k): k
            case .status(let t, _): t
            case .mention(let n, _): "@" + n
            case .attachment(let f): f
            case .opaque(let o): o.label
            default: ""
            }
        }.joined()
    }
}
