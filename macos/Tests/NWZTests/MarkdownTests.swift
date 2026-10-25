import Foundation
import Testing
@testable import NWZRich

struct MarkdownTests {
    static let common = "# 标题\n\n一段 **粗体** 和 *斜体*、`代码`，[链接](https://example.com)。\n\n- 一\n  - 二\n- 三\n\n1. 甲\n2. 乙\n\n- [ ] 未完成\n- [x] 已完成\n\n> 引用\n\n```swift\nlet n = 1\n```\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n![图](ws://asset/abc)\n\n---\n"
    @Test func roundTripsCommonMarkdown() { #expect(Markdown.write(Markdown.parse(Self.common)) == Self.common) }
    @Test func escapesMarkdownSymbols() {
        let doc = RichDoc(blocks: [.para([.text("1. 不是列表 *星号*", [], link: nil, color: nil)])])
        let text = Markdown.write(doc)
        #expect(text == "1\\. 不是列表 \\*星号\\*\n")
        #expect(Markdown.parse(text) == doc)
    }
    @Test func headingsAndParagraphs() {
        #expect(Markdown.parse("# 一级\n\n## 二级\n\n正文\n接着写").blocks == [.heading(level: 1, [.text("一级", [], link: nil, color: nil)], id: nil), .heading(level: 2, [.text("二级", [], link: nil, color: nil)], id: nil), .para([.text("正文 接着写", [], link: nil, color: nil)])])
    }
    @Test func inlineMarksAndNestedFormatting() {
        let doc = Markdown.parse("**粗体** *斜体* ~~删除~~ ***组合*** `a*b`")
        guard case .para(let content) = doc.blocks.first else { Issue.record("缺少段落"); return }
        #expect(content.contains(.text("粗体", .bold, link: nil, color: nil)))
        #expect(content.contains(.text("斜体", .italic, link: nil, color: nil)))
        #expect(content.contains(.text("删除", .strike, link: nil, color: nil)))
        #expect(content.contains(.text("组合", [.bold, .italic], link: nil, color: nil)))
        #expect(content.contains(.text("a*b", .code, link: nil, color: nil)))
    }
    @Test func linksImagesAndBalancedDestinations() {
        let doc = Markdown.parse("[说明](https://example.com/a(b)) ![图](ws://asset/abc)")
        #expect(doc.plainText == "说明")
        #expect(Markdown.write(doc).contains("(<https://example.com/a(b)>)"))
        #expect(Markdown.parse(Markdown.write(doc)) == doc)
    }
    @Test func nestedListsAndTaskLists() {
        let doc = Markdown.parse("3. 三\n   - 子项\n     - [x] 完成\n4. 四")
        guard case .list(let ordered, let start, let items) = doc.blocks.first else { Issue.record("缺少列表"); return }
        #expect(ordered && start == 3 && items.count == 2)
        #expect(Markdown.write(doc).contains("    - [x] 完成"))
        #expect(Markdown.parse(Markdown.write(doc)) == doc)
    }
    @Test func quotesAndCodeFences() {
        let doc = Markdown.parse("> 第一段\n>\n> - 引用列表\n\n~~~~text\n```\n~~~~")
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks.last == .code(lang: "text", text: "```"))
        #expect(Markdown.write(doc).contains("````text\n```\n````"))
    }
    @Test func tablesEscapedPipesAndLineBreaks() {
        let doc = Markdown.parse("| 标题 | 内容 |\n| :--- | ---: |\n| a\\|b | 一<br>二 |\n")
        guard case .table(let rows) = doc.blocks.first else { Issue.record("缺少表格"); return }
        #expect(rows.count == 2 && rows[1].cells.count == 2)
        #expect(RichInline.plain(Markdown.inlines("一<br>二")) == "一\n二")
        #expect(Markdown.parse(Markdown.write(doc)) == doc)
    }
    @Test func hardBreaksAndRules() {
        let doc = Markdown.parse("第一行  \n第二行\\\n第三行\n\n***")
        #expect(doc.blocks.last == .rule)
        #expect(doc.plainText == "第一行\n第二行\n第三行")
    }
    @Test func literalDelimitersAndCodeSpans() {
        #expect(Markdown.parse("未闭合 *星号 和 `代码").plainText == "未闭合 *星号 和 `代码")
        #expect(Markdown.parse("`` `示例` ``").plainText == "`示例`")
        #expect(Markdown.parse("snake_case_name").plainText == "snake_case_name")
    }
    @Test func unicodeEntitiesAndHTMLMarks() {
        let doc = Markdown.parse("&amp; &#8594; <u>下划线</u> <sup>上标</sup>")
        #expect(doc.plainText == "& → 下划线 上标")
        #expect(Markdown.parse(Markdown.write(doc)) == doc)
    }
    @Test(arguments: [common, "- [ ] 项目\n  - 子项\n\n> **引用**", "| x | y |\n| --- | --- |\n| `a` | [b](ws://doc/id) |", "# 标题\n\n正文\\\n继续\n\n~~~\n多行\n代码\n~~~", "[说明](<https://example.com/a b>)"])
    func normalizedRoundTripIsStable(_ source: String) {
        let first = Markdown.write(Markdown.parse(source))
        #expect(Markdown.write(Markdown.parse(first)) == first)
    }
    @Test func absolutizesNestedContentAndOriginalImages() {
        var doc = RichDoc(blocks: [.quote([.para([.text("AB-1", [], link: "/browse/AB-1", color: nil), .image(.init(src: "/thumb.png", full: "/original.png"))])])])
        doc.absolutize(baseURL: "https://jira.example.com")
        #expect(Markdown.write(doc).contains("https://jira.example.com/original.png"))
        #expect(Markdown.write(doc).contains("https://jira.example.com/browse/AB-1"))
    }
}
