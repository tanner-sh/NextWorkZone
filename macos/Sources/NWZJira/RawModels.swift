import Foundation
import NWZCore

extension JiraStatus {
    init(raw: JSONDocument) { self.init(name: raw["name"].text, category: raw["statusCategory"]["key"].string ?? "new") }
}
extension Named {
    init(raw: JSONDocument) { self.init(name: raw["name"].text, iconUrl: raw["iconUrl"].string) }
}
extension IssueSummary {
    public init(raw: JSONDocument, extra: [String] = []) {
        let f = raw["fields"]
        self.init(key: raw["key"].text, summary: f["summary"].text, status: JiraStatus(raw: f["status"]), issueType: Named(raw: f["issuetype"]), priority: f["priority"].isNull ? nil : Named(raw: f["priority"]), project: Named(raw: f["project"]), assignee: f["assignee"]["displayName"].string, assigneeName: f["assignee"]["name"].string, reporter: f["reporter"]["displayName"].string, reporterName: f["reporter"]["name"].string, lastViewed: f["lastViewed"].string, resolution: f["resolution"]["name"].string, created: f["created"].text, updated: f["updated"].text, dueDate: f["duedate"].string, extra: Dictionary(extra.map { ($0, JiraFields.text(f[$0])) }.filter { !$0.1.isEmpty }, uniquingKeysWith: { _, new in new }))
    }
}
extension IssueRef {
    init(raw: JSONDocument) {
        let fields = raw["fields"]
        self.init(key: JiraFields.text(raw["key"]), summary: JiraFields.text(fields["summary"]), status: fields["status"].isNull ? nil : JiraStatus(raw: fields["status"]), issueType: fields["issuetype"].isNull ? nil : Named(raw: fields["issuetype"]))
    }
}
extension Attachment {
    init(raw: JSONDocument) { self.init(id: raw["id"].text, filename: raw["filename"].text, size: raw["size"].int, mimeType: raw["mimeType"].text, contentUrl: raw["content"].text, thumbnailUrl: raw["thumbnail"].string, author: raw["author"]["displayName"].text, created: raw["created"].text) }
}
extension Comment {
    init(raw: JSONDocument, rendered: String? = nil) {
        let body = raw["body"].text
        let fallback = body.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br/>")
        self.init(id: raw["id"].text, author: raw["author"]["displayName"].text, authorName: raw["author"]["name"].text, mine: false, created: raw["created"].text, updated: raw["updated"].text, body: body, bodyHtml: rendered ?? raw["renderedBody"].string ?? fallback, visibility: raw["visibility"].value.decode(CommentVisibility.self))
    }
    public mutating func markMine(_ name: String) { mine = !name.isEmpty && authorName == name }
}
extension TimeTracking {
    init?(raw: JSONDocument) {
        guard ["originalEstimate", "remainingEstimate", "timeSpent"].contains(where: { raw[$0].string != nil }) else { return nil }
        self.init(originalEstimate: raw["originalEstimate"].string, remainingEstimate: raw["remainingEstimate"].string, timeSpent: raw["timeSpent"].string, originalEstimateSeconds: raw["originalEstimateSeconds"].number.map(Int.init), remainingEstimateSeconds: raw["remainingEstimateSeconds"].number.map(Int.init), timeSpentSeconds: raw["timeSpentSeconds"].number.map(Int.init))
    }
}
extension Worklog {
    init(raw: JSONDocument, me: String) {
        self.init(id: JiraFields.text(raw["id"]), author: JiraFields.text(raw["author"]), mine: raw["author"]["name"].string == me, started: raw["started"].text, timeSpent: raw["timeSpent"].text, timeSpentSeconds: raw["timeSpentSeconds"].int, comment: JiraFields.text(raw["comment"]))
    }
}
extension HistoryEntry {
    init(raw: JSONDocument, names: JSONDocument) {
        func side(_ item: JSONDocument, _ text: String, _ id: String) -> String? { (item[text].string ?? item[id].string).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(id: JiraFields.text(raw["id"]), author: JiraFields.text(raw["author"]), authorName: raw["author"]["name"].text, created: raw["created"].text, items: raw["items"].list.map { item in
            let field = JiraFields.text(item["field"]), fieldID = item["fieldId"].string ?? field.lowercased()
            var name = field
            if item["fieldtype"].string == "jira" {
                let lookup = item["fieldId"].string ?? ["Component":"components", "Version":"versions", "Fix Version":"fixVersions"][field] ?? field.lowercased()
                name = names[lookup].string ?? ["Link":"链接", "RemoteIssueLink":"链接", "WorklogId":"工作日志", "Parent":"父任务", "Parent Issue":"父任务", "Workflow":"工作流", "timespent":"耗费时间", "timeestimate":"剩余估算", "timeoriginalestimate":"初始估算"][field] ?? field
            }
            return HistoryItem(fieldId: fieldID, field: name, from: side(item, "fromString", "from"), to: side(item, "toString", "to"))
        })
    }
}

extension IssueDetail {
    public init(raw: JSONDocument) {
        let summary = IssueSummary(raw: raw), fields = raw["fields"], rendered = raw["renderedFields"]
        let links: [IssueLink] = fields["issuelinks"].list.compactMap { link in
            let outward = !link["outwardIssue"].isNull
            let value = outward ? link["outwardIssue"] : link["inwardIssue"]
            guard !value.isNull else { return nil }
            let issue = IssueRef(raw: value)
            return IssueLink(id: JiraFields.text(link["id"]), key: issue.key, summary: issue.summary, status: issue.status, issueType: issue.issueType, relation: JiraFields.text(link["type"][outward ? "outward" : "inward"]))
        }
        self.init(id: JiraFields.text(raw["id"]), key: summary.key, summary: summary.summary, status: summary.status, issueType: summary.issueType, priority: summary.priority, project: summary.project, assignee: summary.assignee, assigneeName: summary.assigneeName, reporter: summary.reporter, reporterName: summary.reporterName, lastViewed: summary.lastViewed, resolution: summary.resolution, created: summary.created, updated: summary.updated, dueDate: summary.dueDate, extra: summary.extra, descriptionHtml: rendered["description"].string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }, fields: JiraFields.display(fields, rendered: rendered, names: raw["names"], schema: raw["schema"], screen: raw["editmeta"]["fields"].keys), timeTracking: TimeTracking(raw: fields["timetracking"]), parent: fields["parent"].isObject ? IssueRef(raw: fields["parent"]) : nil, subtasks: fields["subtasks"].list.map(IssueRef.init(raw:)), links: links, attachments: fields["attachment"].list.map(Attachment.init(raw:)), comments: fields["comment"]["comments"].list.enumerated().map { Comment(raw: $0.element, rendered: rendered["comment"]["comments"][$0.offset]["body"].string) }, epicIssuesJql: Self.epicIssuesJql(key: summary.key, fields: fields, schema: raw["schema"]))
    }

    /// Epic（有 Epic 名称的问题）中的问题：Epic 链接字段指向它的问题。字段名可能被改过或翻译，按字段编号查询。
    static func epicIssuesJql(key: String, fields: JSONDocument, schema: JSONDocument) -> String? {
        let ids = schema.keys
        guard let label = ids.first(where: { schema[$0]["custom"].text.hasSuffix("gh-epic-label") }), !JiraFields.text(fields[label]).isEmpty else { return nil }
        let link = ids.first { schema[$0]["custom"].text.hasSuffix("gh-epic-link") }
        let field = link.flatMap { $0.hasPrefix("customfield_") ? "cf[\($0.dropFirst("customfield_".count))]" : nil } ?? "\"Epic Link\""
        return "\(field) = \(key) ORDER BY Rank ASC"
    }
}
