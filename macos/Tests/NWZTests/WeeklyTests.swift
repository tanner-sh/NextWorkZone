import Foundation
import Testing
import NWZCore
import NWZWiki

@Suite struct WeeklyTests {
    let page = #"<h1 class="auto-cursor-target">10.12-10.18</h1><p>说明</p><table><tbody><tr><th>本周工作总结</th><th>下周</th></tr><tr><td><ul><li>汇总</li></ul></td><td><br /></td></tr></tbody></table><table><tbody><tr><th>人员名称（个人填）</th><th>周报内容（个人填）</th><th>风险事项（个人填）</th></tr><tr><td><strong>李四</strong></td><td><ul><li>知识库开发</li></ul></td><td><br /></td></tr><tr><td><strong>张三</strong></td><td><ul><li>模块 A<ul><li>导出功能&nbsp; &nbsp;--100%</li></ul></li><li>模块 B</li></ul></td><td><br /></td></tr></tbody></table><p><br /></p><h1>10.05-10.11</h1><table><tbody><tr><th>人员名称</th><th>内容</th><th>风险</th></tr><tr><td><strong>张三</strong></td><td><ul><li>上周的内容</li></ul></td><td><br /></td></tr></tbody></table>"#
    func day(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 15) -> Date { Calendar.current.date(from: DateComponents(year: year, month: month, day: day))! }
    func item(_ level: Int, _ text: String) -> OutlineItem { OutlineItem(level: level, text: text) }

    @Test func overviewAndEntry() throws {
        let ov = try Weekly.overview(page, today: day())
        #expect(ov.sections.count == 2 && ov.sections[0].coversToday && ov.currentWeekExists)
        #expect(ov.currentWeekTitle == "10.12-10.18")
        let entry = try Weekly.entry(page, section: "10.12-10.18", name: "张三")
        #expect(entry.rowFound && entry.risk.isEmpty && !entry.lossy)
        #expect(entry.content == [item(0, "模块 A"), item(1, "导出功能 --100%"), item(0, "模块 B")])
        #expect(try !Weekly.entry(page, section: "10.12-10.18", name: "不存在").rowFound)
    }
    @Test func editsOnlyOwnCells() throws {
        let entry = try Weekly.entry(page, section: "10.12-10.18", name: "张三")
        let content = [item(0, "模块 A"), item(1, "导出功能 --100%"), item(0, "新增 <b> & 任务")], risk = [item(0, "无")]
        let edit = try Weekly.applyEntry(page, section: "10.12-10.18", name: "张三", expected: (entry.contentRaw, entry.riskRaw), content: content, risk: risk)
        #expect(edit.changed)
        let after = try Weekly.entry(edit.storage, section: "10.12-10.18", name: "张三")
        #expect(after.content == content && after.risk == risk)
        let oldCells = "<td>" + entry.contentRaw + "</td><td>" + entry.riskRaw + "</td>"
        let newCells = "<td>" + after.contentRaw + "</td><td>" + after.riskRaw + "</td>"
        #expect(edit.storage.replacingOccurrences(of: newCells, with: oldCells) == page)
        #expect(edit.storage.contains("新增 &lt;b&gt; &amp; 任务"))
    }
    @Test func unchangedKeepsOriginalBytes() throws {
        let entry = try Weekly.entry(page, section: "10.12-10.18", name: "张三")
        let edit = try Weekly.applyEntry(page, section: "10.12-10.18", name: "张三", expected: (entry.contentRaw, entry.riskRaw), content: entry.content, risk: entry.risk)
        #expect(!edit.changed && edit.storage == page)
    }
    @Test func conflict() {
        #expect(throws: NWZError.self) { try Weekly.applyEntry(page, section: "10.12-10.18", name: "张三", expected: ("<ul><li>旧</li></ul>", "<br />"), content: [], risk: []) }
    }
    @Test func newWeekUsesTemplate() throws {
        let out = try Weekly.insertWeek(page, title: "10.19-10.25")
        #expect(out.hasPrefix(#"<h1 class="auto-cursor-target">10.19-10.25</h1><p>说明</p>"#))
        #expect(out.hasSuffix(page))
        let ov = try Weekly.overview(out, today: day(2026, 10, 22))
        #expect(ov.sections[0].coversToday)
        let entry = try Weekly.entry(out, section: "10.19-10.25", name: "张三")
        #expect(entry.rowFound && entry.content.isEmpty)
        #expect(try Weekly.entry(out, section: "10.19-10.25", name: "李四").rowFound)
        #expect(throws: NWZError.self) { try Weekly.insertWeek(out, title: "10.19-10.25") }
    }
    @Test func nestedOutline() {
        #expect(Weekly.renderOutline([item(0, "a"), item(2, "b"), item(0, "c")]) == "<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>")
        #expect(Weekly.renderOutline([]) == "<br />")
    }
    @Test func rangesAcrossYears() throws {
        let range = try #require(Weekly.parseRange("12.29-01.04", today: day(2027, 1, 2)))
        #expect(range.0 == day(2026, 12, 29) && range.1 == day(2027, 1, 4))
        let date = day(2026, 3, 4)
        #expect(Weekly.weekTitle(today: date, template: "10.12-10.18") == "03.02-03.08")
        #expect(Weekly.weekTitle(today: date, template: "10/5 ~ 10/11 周报") == "3/2 ~ 3/8")
        #expect(Weekly.weekTitle(today: date, template: "第 42 周") == "03.02-03.08")
        #expect(Weekly.weekTitle(today: date) == "03.02-03.08")
        #expect(Weekly.parseRange("06.08-06.14（本周说明）", today: day()) != nil)
        #expect(Weekly.parseRange("02.30-03.01", today: day()) == nil)
    }
    @Test func richCellsKeepOriginalFormattingWithoutChanges() throws {
        let source = page.replacingOccurrences(of: "模块 B", with: "<strong>模块 B</strong>")
        let entry = try Weekly.entry(source, section: "10.12-10.18", name: "张三")
        #expect(entry.lossy)
        #expect(try Weekly.applyEntry(source, section: "10.12-10.18", name: "张三", content: entry.content, risk: entry.risk).storage == source)
    }
    @Test func retryRebasesOnlyOwnCells() async throws {
        let entry = try Weekly.entry(page, section: "10.12-10.18", name: "张三")
        let changedOther = page.replacingOccurrences(of: "知识库开发", with: "知识库已完成")
        func response(_ storage: String, _ version: Int) throws -> OfflineTransport.Reply {
            let value: JSONValue = ["id":"1", "title":"周报", "space":["key":"DEMO"], "version":["number":.number(Double(version))], "body":["storage":["value":.string(storage)]]]
            return .response(200, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
        }
        let t = OfflineTransport([try response(page, 2), .response(409, "{}"), try response(changedOther, 3), .response(200, "{}")])
        let client = WikiClient(rest: RESTClient(baseURL: "https://wiki.example.com", token: "test-token", http: HTTPClient(transport: t)))
        let result = try await client.weeklySave(page: "1", name: "张三", section: "10.12-10.18", expected: (entry.contentRaw, entry.riskRaw), content: [item(0, "新内容")], risk: [])
        #expect(result.changed && result.version == 4)
        let requests = await t.requests
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "GET", "PUT"])
        let last = try JSONDocument(data: #require(requests.last?.httpBody))
        #expect(last["body"]["storage"]["value"].text.contains("知识库已完成"))
        #expect(last["version"]["number"].int == 4)
    }
}
