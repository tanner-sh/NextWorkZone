import Foundation

/// 富文本的文档模型，与 Rust 的 nextworkzone-richdoc 相同（JSON 中 `t` 为类型）。
struct RichDoc: Codable, Hashable {
    var blocks: [RichBlock]

    static let empty = RichDoc(blocks: [])

    var isEmpty: Bool { blocks.isEmpty }

    /// 文档中出现的 Jira 问题键（Jira 宏、问题链接），按出现顺序去重。
    func issueKeys(jiraBase: String) -> [String] {
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
    func walk(_ visit: (RichBlock) -> Void) {
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

    /// 标题（目录）。
    var headings: [(level: Int, text: String, index: Int)] {
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

struct RichOpaque: Codable, Hashable {
    var n: Int
    var label: String
    var block: Bool?
    var image: String?
    var user: String?
    var issue: String?
}

struct RichItem: Codable, Hashable {
    var task: RichTask?
    var blocks: [RichBlock]
}

struct RichTask: Codable, Hashable {
    var done: Bool
    var id: String?
}

struct RichRow: Codable, Hashable {
    var cells: [RichCell]
}

struct RichCell: Codable, Hashable {
    var head: Bool = false
    var blocks: [RichBlock]
    var colspan: Int = 1
    var rowspan: Int = 1

    private enum Keys: String, CodingKey { case head, blocks, colspan, rowspan }

    init(head: Bool = false, blocks: [RichBlock], colspan: Int = 1, rowspan: Int = 1) {
        self.head = head
        self.blocks = blocks
        self.colspan = colspan
        self.rowspan = rowspan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        head = try c.decodeIfPresent(Bool.self, forKey: .head) ?? false
        blocks = try c.decode([RichBlock].self, forKey: .blocks)
        colspan = try c.decodeIfPresent(Int.self, forKey: .colspan) ?? 1
        rowspan = try c.decodeIfPresent(Int.self, forKey: .rowspan) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        if head { try c.encode(head, forKey: .head) }
        try c.encode(blocks, forKey: .blocks)
        if colspan != 1 { try c.encode(colspan, forKey: .colspan) }
        if rowspan != 1 { try c.encode(rowspan, forKey: .rowspan) }
    }
}

indirect enum RichBlock: Codable, Hashable {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

/// 文字格式（按位组合），与 Rust 的 `marks` 相同。
struct Marks: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let bold = Marks(rawValue: 1)
    static let italic = Marks(rawValue: 2)
    static let underline = Marks(rawValue: 4)
    static let strike = Marks(rawValue: 8)
    static let code = Marks(rawValue: 16)
    static let sup = Marks(rawValue: 32)
    static let sub = Marks(rawValue: 64)
    static let mark = Marks(rawValue: 128)
}

struct RichImage: Codable, Hashable {
    var src: String
    var alt: String?
    var full: String?
    var file: String?
    var thumb: Bool?
    var width: Int?
    var height: Int?
}

enum RichInline: Codable, Hashable {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

    static func plain(_ list: [RichInline]) -> String {
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

/// 格式转换（在 Rust 中完成）。
enum Rich {
    static func fromHTML(_ html: String) async throws -> RichDoc { try await API.shared.call("rich_from_html", ["html": .string(html)]) }
    static func fromMarkdown(_ md: String) async throws -> RichDoc { try await API.shared.call("rich_from_markdown", ["markdown": .string(md)]) }
    static func toMarkdown(_ doc: RichDoc) async throws -> String { try await API.shared.call("rich_to_markdown", ["doc": json(doc)]) }
    static func toWiki(_ doc: RichDoc) async throws -> String { try await API.shared.call("rich_to_wiki", ["doc": json(doc)]) }
    static func toXHTML(_ doc: RichDoc) async throws -> String { try await API.shared.call("rich_to_xhtml", ["doc": json(doc)]) }
    static func htmlToMarkdown(_ html: String, baseUrl: String) async throws -> String { try await API.shared.call("rich_html_to_markdown", ["html": .string(html), "baseUrl": .string(baseUrl)]) }

    struct Storage: Decodable {
        var storage: String
        var assets: [String]
    }

    static func markdownToStorage(_ md: String) async throws -> Storage { try await API.shared.call("rich_markdown_to_storage", ["markdown": .string(md)]) }

    /// Wiki 编辑的片段：原文和对应的块数（见 Rust 的 richdoc::edit）。
    struct Segment: Codable, Hashable {
        var source: String
        var count: Int
    }

    struct EditLoad: Decodable {
        var doc: RichDoc
        var segments: [Segment]
    }

    static func editLoad(_ html: String) async throws -> EditLoad { try await API.shared.call("rich_edit_load", ["html": .string(html)]) }
    static func editXHTML(segments: [Segment], baseline: RichDoc, doc: RichDoc) async throws -> String {
        try await API.shared.call("rich_edit_xhtml", ["segments": json(segments), "baseline": json(baseline), "doc": json(doc)])
    }
}
