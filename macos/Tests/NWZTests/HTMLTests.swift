import Testing
@testable import NWZRich

struct HTMLTests {
    @Test func splitsLongPagesIntoSectionsAtTopLevelHeadings() {
        // 折叠区中的标题也计数：分段后的标题序号要与整页的目录一致
        let doc = HTML.parse(#"<p>前言</p><h1>A</h1><div class="expand-container"><span class="expand-control-text">展开</span><div class="expand-content"><h2>A1</h2><p>x</p></div></div><h1>B</h1><p>y</p>"#)
        let sections = doc.sections()
        #expect(sections.count == 3)
        #expect(sections.map(\.headingStart) == [0, 0, 2])
        #expect(sections.flatMap(\.doc.blocks) == doc.blocks)
        #expect(doc.headings.map(\.index) == [0, 1, 2])
        #expect(RichDoc(blocks: [.para([])]).sections().count == 1)
        #expect(RichDoc.empty.sections().count == 1)
    }

    @Test func splitsLongSectionsBetweenTopLevelBlocks() {
        // 第一个标题之前就很长：在顶层块之间再切开，标题序号仍与整页目录一致
        let doc = HTML.parse(#"<p>aaaa</p><table><tr><td><h3>T</h3>bbbb</td></tr></table><p>cccc</p><p>dddd</p><h1>A</h1><p>eeee</p>"#)
        let sections = doc.sections(limit: 5)
        #expect(sections.flatMap(\.doc.blocks) == doc.blocks)
        #expect(sections.map(\.doc.blocks.count) == [2, 2, 2])
        #expect(sections.map(\.headingStart) == [0, 1, 1])
        #expect(doc.headings.map(\.index) == [0, 1])
    }

    @Test func collapsesWhitespaceAndMergesRuns() {
        let blocks = HTML.parse("<p>  a \n b <b>c</b><b> d</b></p>").blocks
        #expect(blocks == [.para([.text("a b ", [], link: nil, color: nil), .text("c d", .bold, link: nil, color: nil)])])
    }
    @Test func listsTasksAndNesting() throws {
        let doc = HTML.parse(#"<ul class="inline-task-list"><li data-inline-task-id="3" class="checked">done</li><li data-inline-task-id="4">todo<ul><li>sub</li></ul></li></ul>"#)
        guard case .list(_, _, let items) = try #require(doc.blocks.first) else { Issue.record("缺少列表"); return }
        #expect(items[0].task == .init(done: true, id: "3"))
        #expect(items[1].task?.done == false)
        #expect(items[1].blocks.count == 2)
    }
    @Test func codePanelAndAttachmentImage() throws {
        let doc = HTML.parse("<div class=\"code panel\"><div class=\"codeContent panelContent\"><pre class=\"code-java\">int a = 1;\n</pre></div></div><p><span class=\"image-wrap\"><a file-preview-title=\"x.png\" href=\"/secure/attachment/1/1_x.png\"><img src=\"/secure/thumbnail/1/_thumb_1.png\"></a></span></p>")
        #expect(doc.blocks[0] == .code(lang: "java", text: "int a = 1;"))
        guard case .para(let inline) = doc.blocks[1], case .image(let image) = try #require(inline.first) else { Issue.record("缺少图片"); return }
        #expect(image.file == "x.png" && image.thumb == true && image.full == "/secure/attachment/1/1_x.png")
    }
    @Test func wikiEditorPlaceholders() {
        let doc = HTML.parse(#"<div class="nwz-container" data-nwz-open="0" data-nwz-close="1"><p>文字 <span class="nwz-opaque" contenteditable="false" data-nwz="2"><span class="nwz-jira" data-jira-key="AB-1">AB-1</span></span></p><span class="nwz-opaque nwz-block" data-nwz="3"><span class="nwz-macro-title">信息</span><span class="nwz-line">一行</span></span></div>"#)
        #expect(doc.blocks.first == .marker(0) && doc.blocks.last == .marker(1))
        guard doc.blocks.count == 4, case .para(let inline) = doc.blocks[1], case .opaque(let issue) = inline.last, case .opaque(let block) = doc.blocks[2] else { Issue.record("占位结构不正确"); return }
        #expect(issue.n == 2 && issue.issue == "AB-1")
        #expect(block.n == 3 && block.label == "信息\n一行")
    }
    @Test func colorsAndStyles() {
        #expect(HTML.color("rgb(255, 0, 0)") == "#ff0000")
        #expect(HTML.color("#abc") == "#aabbcc")
        #expect(HTML.color("#000000") == nil)
        #expect(HTML.parse(#"<p><span style="font-weight:700; color:#ff0000">x</span></p>"#).blocks == [.para([.text("x", .bold, link: nil, color: "#ff0000")])])
    }
    @Test func ignoresScriptsAndPreservesEntities() {
        #expect(HTML.parse("<script>alert(1)</script><style>body{}</style><p>中文 &rarr; &amp; &nbsp;正文</p>").plainText == "中文 → & \u{a0}正文")
        #expect(HTML.parse("<p><a href='javascript:bad()'>文字</a></p>").blocks == [.para([.text("文字", [], link: nil, color: nil)])])
    }
    @Test func recoversMalformedHTMLAndTableSpans() {
        let doc = HTML.parse("<h2>标题</h2><p>正文<b>粗体</b><p>第二段<table><tr><th colspan='2'>表头</th></tr><tr><td>a</td><td>b</td></tr></table>")
        #expect(doc.headings.first?.text == "标题")
        guard case .table(let rows) = doc.blocks.last else { Issue.record("缺少表格"); return }
        #expect(rows.count == 2 && rows[0].cells[0].colspan == 2)
    }
    @Test func htmlToMarkdownAbsolutizesOriginalImage() {
        var doc = HTML.parse(#"<p><a href="/browse/AB-1">AB-1</a><a href="/original.png"><img src="/thumb.png"></a></p>"#)
        doc.absolutize(baseURL: "https://jira.example.com")
        let markdown = Markdown.write(doc)
        #expect(markdown.contains("https://jira.example.com/original.png"))
        #expect(markdown.contains("https://jira.example.com/browse/AB-1"))
    }
}

struct JiraMarkupTests {
    func wiki(_ source: String) -> String { JiraMarkup.write(HTML.parse(source)) }
    @Test func formatsAndBraces() {
        #expect(wiki("<p>a <b>粗</b> b</p>") == "a *粗* b")
        #expect(wiki("<p>前<b>粗</b>后</p>") == "前{*}粗{*}后")
        #expect(wiki("<p>x <code>a{b}</code></p>") == "x {{a\\{b\\}}}")
    }
    @Test func blocks() {
        #expect(wiki("<h2>标题</h2><ul><li>一<ul><li>二</li></ul></li></ul><ol><li>甲</li></ol>") == "h2. 标题\n\n* 一\n** 二\n\n# 甲")
        #expect(wiki("<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>") == "||a||b||\n|1|2|")
        #expect(wiki(#"<div class="code panel"><pre class="code-java">x</pre></div>"#) == "{code:java}\nx\n{code}")
    }
    @Test func escapes() {
        #expect(wiki("<p>2026-07-17 - 项目 [x]</p>") == "2026-07-17 - 项目 \\[x\\]")
        #expect(wiki("<p>* 不是列表</p>") == "\\* 不是列表")
        #expect(wiki(#"<p><a href="https://example.com">https://example.com</a> <a href="https://example.com/x">文字</a></p>"#) == "[https://example.com] [文字|https://example.com/x]")
        #expect(wiki(#"<p><a class="user-hover" rel="zhangsan">张三</a></p>"#) == "[~zhangsan]")
    }
    @Test func attachmentAndTaskOutput() {
        #expect(wiki(#"<ul><li><input type="checkbox" checked>done</li><li><input type="checkbox">todo</li></ul>"#) == "* (/) done\n* (x) todo")
        #expect(wiki(#"<p><a data-attachment="notes.txt">notes.txt</a><img data-filename="x.png" src="/x.png" width="20"></p>"#) == "[^notes.txt]!x.png|width=20!")
    }
}
