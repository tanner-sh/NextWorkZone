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
    static func fromHTML(_ html: String) async throws -> RichDoc { HTML.parse(html) }
    static func fromMarkdown(_ md: String) async throws -> RichDoc { Markdown.parse(md) }
    static func toMarkdown(_ doc: RichDoc) async throws -> String { Markdown.write(doc) }
    static func toWiki(_ doc: RichDoc) async throws -> String { JiraMarkup.write(doc) }
    static func toXHTML(_ doc: RichDoc) async throws -> String { XHTML.write(doc) }
    static func htmlToMarkdown(_ html: String, baseUrl: String) async throws -> String { HTML.markdown(html, baseURL: baseUrl) }

    typealias Storage = XHTML.Storage
    static func markdownToStorage(_ md: String) async throws -> Storage { XHTML.markdownToStorage(md) }

    typealias Segment = RichEdit.Segment
    typealias EditLoad = RichEdit.Load
    static func editLoad(_ html: String) async throws -> EditLoad { RichEdit.load(html) }
    static func editXHTML(segments: [Segment], baseline: RichDoc, doc: RichDoc) async throws -> String {
        RichEdit.xhtml(segments: segments, baseline: baseline, edited: doc)
    }
}
