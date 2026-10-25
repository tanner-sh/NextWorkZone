import Foundation
import NWZRich

typealias RichDoc = NWZRich.RichDoc
typealias RichBlock = NWZRich.RichBlock
typealias RichInline = NWZRich.RichInline
typealias RichOpaque = NWZRich.RichOpaque
typealias RichItem = NWZRich.RichItem
typealias RichTask = NWZRich.RichTask
typealias RichRow = NWZRich.RichRow
typealias RichCell = NWZRich.RichCell
typealias Marks = NWZRich.Marks
typealias RichImage = NWZRich.RichImage

/// 格式转换。已迁移的格式直接使用 Swift。
enum Rich {
    static func fromHTML(_ html: String) async throws -> RichDoc { try await API.shared.call("rich_from_html", ["html": .string(html)]) }
    static func fromMarkdown(_ md: String) async throws -> RichDoc { Markdown.parse(md) }
    static func toMarkdown(_ doc: RichDoc) async throws -> String { Markdown.write(doc) }
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
