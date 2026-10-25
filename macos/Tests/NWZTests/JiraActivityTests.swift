import Foundation
import Testing
import NWZCore
@testable import NWZJira

struct JiraActivityTests {
    func fixture(_ name: String) throws -> JSONDocument {
        try JSONDocument(data: Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))))
    }
    @Test func findsMyActionsWithinRange() throws {
        let actions = JiraActivity.actions(try fixture("jira-actions"), me: "me", start: try #require(JiraActivity.time("2026-10-22T00:00:00.000+0800")), end: try #require(JiraActivity.time("2026-10-23T00:00:00.000+0800")))
        #expect(actions.map(\.kind) == ["create", "comment", "transition", "update"])
        #expect(actions.map(\.detail) == ["", "已修复，见 @bob", "处理中 → 已解决", "修改了计划日期"])
    }
    @Test func findsChangesByOthersAfterSince() throws {
        let events = JiraActivity.events(try fixture("jira-activity"), me: "me", since: try #require(JiraActivity.time("2026-10-22T10:00:00.000+0800")))
        #expect(events.map(\.id) == ["ABC-1:c:2", "ABC-1:c:4", "ABC-1:h:10", "ABC-1:h:11", "ABC-1:h:12"])
        #expect(events.map(\.kind) == ["mention", "comment", "status", "assigned", "field"])
        #expect(events.map(\.text) == ["请看 @me 这个", "同意", "处理中 → 已解决", "分配给你", "截止日期：2026-10-21 → 2026-10-27"])
        #expect(events[0].actor == "BOB")
    }
    @Test func reportsNewIssueAssignedToMe() throws {
        let events = JiraActivity.events(try fixture("jira-created"), me: "me", since: try #require(JiraActivity.time("2026-10-22T10:00:00.000+0800")))
        #expect(events.count == 1 && events[0].text == "创建了问题，并分配给你")
    }
    @Test func excerptsAreShortAndPlain() {
        #expect(JiraActivity.excerpt("*重要* 见 [文档|http://example.com] 和 [~bob]") == "重要 见 文档 和 @bob")
        #expect(JiraActivity.excerpt(String(repeating: "字", count: 300)).hasSuffix("…"))
    }
}
