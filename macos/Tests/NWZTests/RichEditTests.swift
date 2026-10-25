import Testing
import NWZRich

@Suite struct RichEditTests {
    let html = #"<div class="nwz-container" data-nwz-open="0" data-nwz-close="1"><p>文字 <strong>粗</strong> <span class="nwz-opaque" contenteditable="false" data-nwz="2"><span class="nwz-jira" data-jira-key="ABC-1">ABC-1</span></span></p><p class="auto-cursor-target"><br /></p><table class="wrapped"><colgroup><col style="width: 100.0px;" /></colgroup><tbody><tr><td>格</td></tr></tbody></table><p>第二段&nbsp; 末尾</p></div>"#

    @Test func unchangedRoundTrip() {
        let load = RichEdit.load(html)
        #expect(load.segments.map(\.count).reduce(0, +) == load.doc.blocks.count)
        #expect(RichEdit.xhtml(segments: load.segments, baseline: load.doc, edited: load.doc) == RichEdit.placeholders(html))
        #expect(load.segments.map(\.source).joined() == RichEdit.placeholders(html))
    }

    @Test func changesOnlyOneBlock() throws {
        let load = RichEdit.load(html)
        var edited = load.doc
        let last = try #require(edited.blocks.lastIndex { if case .para = $0 { true } else { false } })
        edited.blocks[last] = .para([.text("改过", [], link: nil, color: nil)])
        let out = RichEdit.xhtml(segments: load.segments, baseline: load.doc, edited: edited)
        #expect(out.contains(#"<table class="wrapped"><colgroup><col style="width: 100.0px;" /></colgroup>"#))
        #expect(out.contains("<p>改过</p>"))
        #expect(!out.contains("第二段"))
        #expect(out.hasPrefix("<!--nwz:0--><p>文字 <strong>粗</strong> <!--nwz:2--></p>"))
        #expect(out.hasSuffix("<!--nwz:1-->"))
    }

    @Test func insertionPreservesNeighbours() {
        let load = RichEdit.load(html)
        var edited = load.doc
        edited.blocks.insert(.para([.text("新的", [], link: nil, color: nil)]), at: 2)
        let out = RichEdit.xhtml(segments: load.segments, baseline: load.doc, edited: edited)
        #expect(out.contains("<p>新的</p>"))
        #expect(out.contains("第二段&nbsp; 末尾"))
    }

    @Test func xhtmlPlaceholders() {
        let html = #"<div class="nwz-container" data-nwz-open="0" data-nwz-close="1"><p>文字 <strong>粗</strong> <span class="nwz-opaque" data-nwz="2">ABC-1</span></p></div>"#
        #expect(XHTML.write(HTML.parse(html)) == "<!--nwz:0--><p>文字 <strong>粗</strong> <!--nwz:2--></p><!--nwz:1-->")
    }

    @Test func publishAssetsAndCode() {
        let result = XHTML.markdownToStorage("![](ws://asset/a1)\n\n```js\nx]]>y\n```\n\n[笔记](ws://doc/d1) [网站](https://example.com)\n\n- [x] 完成\n")
        #expect(result.assets == ["a1"])
        #expect(result.storage.contains(#"<ri:attachment ri:filename="ws-asset:a1" />"#))
        #expect(result.storage.contains("<![CDATA[x]]]]><![CDATA[>y]]>"))
        #expect(result.storage.contains(#"<p>笔记 <a href="https://example.com">网站</a></p>"#))
        #expect(result.storage.contains("<li>☑ 完成</li>"))
    }

    @Test func emptyAndInlineContainers() {
        for html in ["<p>&nbsp;</p>", " <!--原注释--><p></p> ", #"<p>字<span class="nwz-container" data-nwz-open="0" data-nwz-close="1">评论</span>后</p>"#] {
            let load = RichEdit.load(html)
            #expect(RichEdit.xhtml(segments: load.segments, baseline: load.doc, edited: load.doc) == RichEdit.placeholders(html))
        }
    }
}
