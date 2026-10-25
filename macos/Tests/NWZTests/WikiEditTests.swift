import Testing
import NWZRich
import NWZWiki

@Suite struct WikiEditTests {
    let page = #"<ac:layout><ac:layout-section ac:type="single"><ac:layout-cell><p>文字 <strong>粗</strong> <ac:structured-macro ac:name="jira" ac:schema-version="1"><ac:parameter ac:name="key">ABC-1</ac:parameter></ac:structured-macro></p><ac:structured-macro ac:name="code"><ac:plain-text-body><![CDATA[a < b]]></ac:plain-text-body></ac:structured-macro><p><ac:link><ri:user ri:userkey="k1" /></ac:link></p></ac:layout-cell></ac:layout-section></ac:layout>"#

    @Test func opaqueAndContainers() throws {
        let ed = try WikiEdit.toEditable(page)
        #expect(ed.fragments.count == 9)
        #expect(ed.html.contains("<strong>粗</strong>"))
        #expect(ed.html.contains(#"data-jira-key="ABC-1""#))
        #expect(ed.html.contains(#"<span class="nwz-code">a &lt; b</span>"#))
        #expect(ed.html.contains(#"data-nwz-user="k1""#))
        #expect(ed.users == ["k1"])
        #expect(ed.html.hasPrefix(#"<div class="nwz-container" data-nwz-open="0" data-nwz-close="1">"#))
    }

    @Test func roundTrip() throws {
        let ed = try WikiEdit.toEditable(page), load = RichEdit.load(ed.html)
        let xhtml = RichEdit.xhtml(segments: load.segments, baseline: load.doc, edited: load.doc)
        #expect(try WikiEdit.fromEditable(xhtml, fragments: ed.fragments) == page)
    }

    @Test func rejectsBrokenXML() throws {
        #expect(throws: (any Error).self) { try WikiEdit.fromEditable("<p>a<b>c</p>", fragments: []) }
        #expect(throws: (any Error).self) { try WikiEdit.fromEditable("<p>x<!--nwz:5--></p>", fragments: []) }
        #expect(throws: (any Error).self) { try WikiStorage.validate("<p>") }
        try WikiStorage.validate("<p>a&nbsp;b<br /></p>")
    }

    @Test func selfClosingDate() throws {
        let ed = try WikiEdit.toEditable(#"<p>截止 <time datetime="2026-10-30" /> 前完成<br /></p>"#)
        #expect(ed.fragments == [#"<time datetime="2026-10-30" />"#])
        #expect(ed.html.contains("2026-10-30</span></span> 前完成<br />"))
    }

    @Test func templateVariables() {
        let s = #"<at:declarations><at:string at:name="x" /></at:declarations><p>日期 <at:var at:name="x" /></p>"#
        #expect(WikiEdit.stripTemplateVariables(s) == "<p>日期 </p>")
        #expect(WikiEdit.plainToStorage("a<b\n\nc") == "<p>a&lt;b</p><p>&nbsp;</p><p>c</p>")
    }

    @Test func preservesQuotedBracketsAndUnicode() throws {
        let page = #"<p title="a > b">文 &rarr; 字<ac:inline-comment-marker ac:ref="a">评</ac:inline-comment-marker></p><!--说明--><ac:structured-macro ac:name="unknown"><ac:plain-text-body><![CDATA[<not-a-tag>]]></ac:plain-text-body></ac:structured-macro>"#
        let editable = try WikiEdit.toEditable(page), load = RichEdit.load(editable.html)
        #expect(try WikiEdit.fromEditable(RichEdit.xhtml(segments: load.segments, baseline: load.doc, edited: load.doc), fragments: editable.fragments) == page)
    }
}
