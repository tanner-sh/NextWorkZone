import Foundation
import Testing
import NWZCore
@testable import NWZJira

struct JiraClientTests {
    func json(_ text: String) throws -> JSONDocument { try JSONDocument(data: Data(text.utf8)) }
    @Test func recognizesIssueKeys() {
        #expect(JiraQueries.looksLikeKey("ABC-123"))
        #expect(JiraQueries.looksLikeKey("proj-123"))
        #expect(!JiraQueries.looksLikeKey("清理-1") && !JiraQueries.looksLikeKey("ABC-") && !JiraQueries.looksLikeKey("批量清理"))
    }
    @Test func splitsSummaryIntoTerms() {
        #expect(JiraQueries.summaryTerms("导入测试txt文件") == ["导入", "入测", "测试", "txt", "文件"])
        #expect(JiraQueries.summaryTerms("报表中订单的字段需调整") == ["报表", "订单"])
        #expect(JiraQueries.summaryTerms("【WEB】列表 v2 1234") == ["WEB", "列表", "v2"])
        #expect(JiraQueries.summaryTerms("！？…").isEmpty)
        #expect(JiraQueries.similarJQL(key: "ABC-1", summary: "订单表", resolvedOnly: true) == "summary ~ \"订单 OR 单表\" AND key != \"ABC-1\" AND resolution is not EMPTY")
    }
    @Test func parsesCommentLevelsFromForm() {
        let html = #"<select name="commentLevel"><option value="">所有用户</option><optgroup><option value="role:10">Developers</option><option value="role:20">开发</option></optgroup><option value="group:jira-users">jira-users</option></select><select name="other"><option value="role:1">x</option></select>"#
        let levels = JiraForms.commentLevels(html)
        #expect(levels.map(\.visibility.type) == ["role", "role", "group"])
        #expect(levels.map(\.label) == ["Developers", "开发", "jira-users"])
        #expect(JiraForms.commentLevels("<html>登录</html>").isEmpty)
    }
    @Test func parsesSuggestedAssigneesFromForm() {
        let html = #"<select><optgroup id="assignee-group-suggested"><option value="zs">张三</option><option value="">未分配</option><option value="-1">自动</option><option value="ls">李四 &amp; Co</option></optgroup><optgroup id="other"><option value="other">其他</option></optgroup></select>"#
        let users = JiraForms.suggestedAssignees(html)
        #expect(users.map(\.name) == ["zs", "ls"] && users.map(\.displayName) == ["张三", "李四 & Co"])
        #expect(JiraForms.suggestedAssignees("<html>登录</html>").isEmpty)
    }
    @Test func escapesJQLStrings() { #expect(JiraQueries.escape(#"a"b\c"#) == #"a\"b\\c"#) }
    @Test func valueTextHandlesCommonShapes() throws {
        #expect(JiraFields.text(try json(#"{"value":"上海","child":{"value":"浦东"}}"#)) == "上海 / 浦东")
        #expect(JiraFields.text(try json(#"[{"name":"v1"},{"name":"v2"}]"#)) == "v1、v2")
        #expect(JiraFields.text(try json(#"{"displayName":"张三","name":"zs"}"#)) == "张三")
        #expect(JiraFields.text(try json("null")) == "")
        #expect(JiraFields.text(try json("0.0")) == "0")
        #expect(JiraFields.text(try json("2.5")) == "2.5")
        #expect(JiraFields.formatMillis(757650000) == "8天 18小时 28分")
    }
    @Test func followsScreenConfiguration() throws {
        let fields = try json(#"{"assignee":{"displayName":"张三"},"customfield_2":"第二个","customfield_1":"第一个","customfield_9":"隐藏默认值"}"#)
        let names = try json(#"{"assignee":"经办人","customfield_1":"甲","customfield_2":"乙","customfield_9":"丙"}"#)
        let list = JiraFields.display(fields, rendered: .null, names: names, schema: .null, screen: ["customfield_1", "customfield_2"])
        #expect(list.map(\.name) == ["经办人", "甲", "乙", "丙"])
        #expect(list.map(\.hidden) == [false, false, false, true])
        #expect(JiraFields.display(fields, rendered: .null, names: names, schema: .null, screen: []).allSatisfy { !$0.hidden })
    }
    @Test func parsesTransitionFields() throws {
        let raw = try json(#"{"transitions":[{"id":"5","name":"解决","to":{"name":"已解决","statusCategory":{"key":"done"}},"fields":{"resolution":{"required":true,"name":"解决结果","schema":{"type":"resolution"},"allowedValues":[{"id":"1","name":"已修复"}]},"comment":{"required":false,"name":"备注","schema":{"type":"comments-page"}}}}]}"#)
        let t = JiraFields.transitions(raw)[0]
        #expect(t.to.category == "done" && t.fields[0].key == "resolution" && t.fields[0].kind == "select" && t.fields.count == 1)
    }
    @Test func classifiesFieldsAndPreservesOrder() throws {
        let raw = try json(#"{"summary":{"required":true,"name":"概要","schema":{"type":"string"}},"issuetype":{"schema":{"type":"issuetype"}},"customfield_1":{"name":"区域","allowedValues":[{"id":"10","value":"华东"}],"schema":{"custom":"com.atlassian.jira.plugin.system.customfieldtypes:select"}},"customfield_2":{"schema":{"custom":"plugin.jep:generic-counter"}},"components":{"allowedValues":[{"id":"1","name":"核心"}],"schema":{"type":"array"}},"customfield_3":{"schema":{"custom":"com.pyxis.greenhopper.jira:gh-epic-link"}},"priority":{"hasDefaultValue":true,"defaultValue":{"id":"3"},"allowedValues":[{"id":"3","name":"中"}],"schema":{"type":"priority"}}}"#)
        let fields = JiraFields.parse(raw)
        #expect(fields.map(\.key) == ["summary", "customfield_1", "customfield_2", "components", "customfield_3", "priority"])
        #expect(fields.map(\.kind) == ["text", "select", "unsupported", "multiselect", "epic", "select"])
        #expect(fields[1].options[0].name == "华东" && fields[5].value == "3")
    }
    @Test func convertsCurrentValues() throws {
        #expect(JiraFields.formValue("cascading", try json(#"{"id":"1","child":{"id":"2"}}"#)) == ["1", "2"])
        #expect(JiraFields.formValue("multiselect", try json(#"[{"id":"5"},{"id":"6"}]"#)) == ["5", "6"])
        #expect(JiraFields.formValue("user", try json(#"{"name":"zs","displayName":"张三"}"#)) == ["name":"zs", "displayName":"张三"])
        #expect(JiraFields.formValue("datetime", try json(#""2026-09-21T15:00:00.000+0800""#)) == "2026-09-21T15:00")
        #expect(JiraFields.formValue("number", try json("3.5")) == "3.5")
        #expect(JiraFields.formValue("labels", try json("[]")) == .null)
        #expect(JiraFields.formValue("epic", try json(#""ABC-1""#)) == ["key":"ABC-1", "summary":""])
        #expect(JiraFields.formValue("timetracking", try json(#"{"originalEstimate":"2d"}"#)) == ["originalEstimate":"2d"])
        #expect(JiraFields.formValue("text", .null) == .null)
    }
}
