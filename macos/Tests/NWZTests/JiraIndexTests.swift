import Foundation
import Testing
import NWZCore
@testable import NWZJira

struct JiraIndexTests {
    func issue(_ key: String, _ summary: String, _ description: String = "", resolved: Bool = false, comments: [(String, String)] = []) -> IndexedIssue {
        let raw: JSONValue = ["key": .string(key), "fields":["summary":.string(summary), "description":.string(description), "status":["name":"处理中", "statusCategory":["key":"indeterminate"]], "project":["name":"测试项目"], "assignee":["name":"zs", "displayName":"张三"], "resolution":resolved ? ["name":"已修复"] : .null, "updated":"2026-10-20T10:00:00.000+0800", "created":"2026-10-01T10:00:00.000+0800", "comment":["comments":.array(comments.map { ["author":["name":.string($0.0), "displayName":.string($0.0.uppercased())], "created":"2026-10-02T10:00:00.000+0800", "body":.string($0.1)] })]]]
        return IndexedIssue(raw: JSONDocument(value: raw))
    }
    func sample() async throws -> IssueIndex {
        let index = try IssueIndex()
        try await index.upsert([issue("ABC-1", "导入批量文件报错", "导入 *TXT* 文件时提示格式错误", resolved: true, comments: [("ls", "原因是编码为 GBK，已改为自动识别")]), issue("ABC-2", "订单报表字段调整", "报表增加订单状态"), issue("ABC-3", "单据类型", "批量执行单据", resolved: true, comments: [("me", "参考 ABC-1 的处理")]), issue("PROJ-1", "Report export", "Export to Excel fails")])
        return index
    }
    func query(_ text: String = "", project: String = "", state: String = "all", mine: Bool = false) -> IndexQuery { .init(text: text, project: project, state: state, mine: mine) }
    @Test func searchesSummaryDescriptionAndComments() async throws {
        let index = try await sample()
        #expect(try await index.search(query("批量"), me: "").map(\.key) == ["ABC-1", "ABC-3"])
        #expect(try await index.search(query("编码"), me: "").map(\.key) == ["ABC-1"])
        #expect(try await index.search(query("EXCEL"), me: "").map(\.key) == ["PROJ-1"])
        #expect(try await index.search(query("批量 编码"), me: "").map(\.key) == ["ABC-1"])
        #expect(try await index.search(query("abc-2"), me: "").map(\.key) == ["ABC-2"])
        let snippet = try #require(await index.search(query("编码"), me: "").first?.snippet)
        #expect(snippet.source == "comment" && snippet.author == "LS")
        #expect(try await index.search(query("批量", state: "unresolved"), me: "").isEmpty)
        #expect(try await index.search(query(mine: true), me: "me").map(\.key) == ["ABC-3"])
        #expect(try await index.search(query(project: "PROJ"), me: "").map(\.key) == ["PROJ-1"])
    }
    @Test func findsSimilarWithComments() async throws {
        let index = try await sample()
        let hits = try #require(await index.similar(key: "ABC-9", summary: "导入批量txt文件", resolvedOnly: true, limit: 5))
        #expect(hits[0].key == "ABC-1" && hits[0].lastComments[0].body == "原因是编码为 GBK，已改为自动识别")
        #expect(hits.allSatisfy { $0.resolution != nil })
        #expect(try await index.similar(key: "ZZ-1", summary: "导入批量", resolvedOnly: true, limit: 5) == nil)
    }
    @Test func skipsBoilerplateComments() async throws {
        let index = try await sample(), bot = "您好，此问题已解决但超过三个月未验证，系统自动关闭"
        try await index.upsert((10..<40).map { issue("ABC-\($0)", "其他问题", resolved: true, comments: [("bot", bot)]) })
        try await index.upsert([issue("ABC-5", "导入批量文件格式", resolved: true, comments: [("ls", "改为自动识别编码"), ("bot", bot)])])
        try await index.finishSync(changed: 1)
        let hits = try #require(await index.similar(key: "ABC-9", summary: "导入批量文件格式", resolvedOnly: true, limit: 3))
        #expect(hits.first { $0.key == "ABC-5" }?.lastComments.map(\.body) == ["改为自动识别编码"])
    }
    @Test func recordsViewsAndResetsOnlyWhenServerChanges() async throws {
        let index = try await sample()
        try await index.ensureBase("https://jira.example.com")
        #expect(try await index.markViewed("ABC-1", at: 100) == nil)
        #expect(try await index.markViewed("ABC-1", at: 50) == 100)
        let result = try await index.viewed(["ABC-1", "ABC-2"])
        #expect(result.viewed == ["ABC-1":100] && result.baseline > 0)
        try await index.clear()
        #expect(try await index.viewed(["ABC-1"]).viewed["ABC-1"] == 100)
        try await index.ensureBase("https://other.example.com")
        #expect(try await index.viewed(["ABC-1"]).viewed.isEmpty)
    }
    @Test func findsIssuesMentioningALink() async throws {
        let index = try IssueIndex()
        try await index.upsert([issue("ABC-1", "一", comments: [("ls", "代码已提交至 [分支|https://git.example.com/G/App/-/merge_requests/12]")]), issue("ABC-2", "二", "见 https://git.example.com/g/app/-/merge_requests/123"), issue("ABC-3", "三", "无关")])
        #expect(try await index.mentioning(["g/app/-/merge_requests/12"], accept: { _ in true }, limit: 10).count == 2)
        let hits = try await index.mentioning(["g/app/-/merge_requests/12"], accept: { $0.lowercased().hasSuffix("merge_requests/12") }, limit: 10)
        #expect(hits.map(\.key) == ["ABC-1"] && hits[0].snippet?.source == "comment")
    }
    @Test func stripsWikiMarkup() {
        #expect(JiraIndexText.plain("h2. 标题\n* *加粗* 文字 [~zs]\n{code:java}int a;{code}\n!img.png|thumbnail! [链接|http://example.com] [问题|PROJ-1]") == "标题\n加粗 文字 @zs\nint a;\n链接 http://example.com 问题")
        #expect(JiraIndexText.plain(#"<p>见 <a href="https://git.example.com/g/a/-/tree/dev" class="x">分支</a></p>"#) == "见 https://git.example.com/g/a/-/tree/dev 分支")
        #expect(JiraIndexText.plain("<p>补丁&nbsp;已上传</p><p>第二段<br>换行</p>") == "补丁 已上传\n第二段\n换行")
        #expect(JiraIndexText.stripOrder("project = ABC ORDER BY created DESC") == "project = ABC")
    }
}
