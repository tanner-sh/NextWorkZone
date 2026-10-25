import Testing
import NWZCore
import NWZRich
import NWZWiki

@Suite struct WikiStorageTests {
    let sample = #"""
<h1>标题</h1><p>说明&nbsp;文字 ABC-1 见<ac:structured-macro ac:name="jira" ac:schema-version="1"><ac:parameter ac:name="server">JIRA</ac:parameter><ac:parameter ac:name="key">PROJ-123</ac:parameter></ac:structured-macro></p><table><tbody><tr><th>A</th><th>B</th></tr><tr><td>1</td><td><p>2</p></td></tr></tbody></table><ac:structured-macro ac:name="code"><ac:parameter ac:name="language">java</ac:parameter><ac:plain-text-body><![CDATA[int a = 1;
int b = 2;]]></ac:plain-text-body></ac:structured-macro><ac:task-list><ac:task><ac:task-id>3</ac:task-id><ac:task-status>incomplete</ac:task-status><ac:task-body>写文档 <ac:link><ri:user ri:userkey="abc" /></ac:link> <time datetime="2026-10-30" /></ac:task-body></ac:task></ac:task-list><p><ac:image><ri:attachment ri:filename="a.png" /></ac:image></p>
"""#

    @Test func spansAndDepth() throws {
        let doc = try StorageDocument("<h1>标题</h1><table><tbody><tr><td>a&nbsp;b<br />c</td></tr></tbody></table>")
        let cells = doc.findChildren(doc.tokens.indices, depth: 3, name: "td")
        #expect(cells.count == 1)
        let cell = try #require(cells.first)
        #expect(doc.string(doc.inner(cell)) == "a&nbsp;b<br />c")
        #expect(doc.text(doc.children(cell)) == "a b c")
        #expect(doc.string(doc.outer(0)) == "<h1>标题</h1>")
    }

    @Test func entities() {
        #expect(WikiStorage.decodeEntities("a&nbsp;&ndash;&#65;&#x42;&unknown;&") == "a –AB&unknown;&")
        #expect(WikiStorage.decodeEntities("内容&汇总文档") == "内容&汇总文档")
        #expect(WikiStorage.decodeEntities("A&B；中文") == "A&B；中文")
        #expect(WikiStorage.decodeEntities("1.14&rarr;1.30 &ne;") == "1.14→1.30 ≠")
        #expect(WikiStorage.normalizeEntities("a&rarr;b &amp; &lt;p&gt; &#160; &quot;x&quot;") == "a→b &amp; &lt;p&gt; \u{a0} \"x\"")
    }

    @Test func readableText() {
        let lines = WikiText.readableLines(sample)
        #expect(lines.first == "# 标题")
        #expect(lines.dropFirst().first == "说明 文字 ABC-1 见 [PROJ-123]")
        for line in ["A | B", "1 | 2", "int a = 1;", "int b = 2;", "[图片 a.png]"] { #expect(lines.contains(line)) }
        #expect(lines.contains { $0.hasPrefix("[ ] 写文档") })
        #expect(!lines.contains { $0.contains("java") || $0.contains("JIRA") })
    }

    @Test func findsIssueKeys() {
        #expect(WikiText.jiraKeys(storage: sample, text: WikiText.readableLines(sample).joined(separator: "\n")) == ["PROJ-123", "ABC-1"])
    }

    @Test func findsTasks() throws {
        let tasks = WikiText.inlineTasks(sample)
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        #expect(task.taskId == "3" && !task.done && task.assignees == ["abc"] && task.due == "2026-10-30")
        #expect(task.text.hasPrefix("写文档"))
    }
}
