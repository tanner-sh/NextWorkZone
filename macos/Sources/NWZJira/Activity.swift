import Foundation
import NWZCore

public enum JiraActivity {
    public static func time(_ value: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
    public static func activityJQL(me: String, since: String) -> String {
        "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser() OR text ~ \"\(JiraQueries.escape(me))\") AND updated >= \"\(since)\" ORDER BY updated DESC"
    }
    public static func actionsJQL(from: String, to: String) -> String {
        "updated >= \"\(from)\" AND updated < \"\(to)\" AND (assignee was currentUser() OR reporter = currentUser() OR watcher = currentUser() OR status changed by currentUser() DURING (\"\(from)\", \"\(to)\")) ORDER BY updated DESC"
    }
    public static func events(_ issue: JSONDocument, me: String, since: Date) -> [ActivityEvent] {
        let key = issue["key"].text, fields = issue["fields"]
        func after(_ at: String) -> Bool { time(at).map { $0 > since } ?? false }
        func event(_ id: String, _ kind: String, _ author: JSONDocument, _ at: String, _ text: String) -> ActivityEvent {
            ActivityEvent(id: id, issueKey: key, issueSummary: fields["summary"].text, issueTypeIcon: fields["issuetype"]["iconUrl"].string, kind: kind, actor: author["displayName"].text, at: at, text: text, read: false, system: "jira")
        }
        var events: [ActivityEvent] = []
        let created = fields["created"].text
        if after(created) && fields["reporter"]["name"].string != me { events.append(event(key + ":created", "created", fields["reporter"], created, fields["assignee"]["name"].string == me ? "创建了问题，并分配给你" : "创建了问题")) }
        for comment in fields["comment"]["comments"].list {
            let at = comment["created"].text, body = comment["body"].text
            if after(at) && comment["author"]["name"].string != me { events.append(event(key + ":c:" + comment["id"].text, body.contains("[~\(me)]") ? "mention" : "comment", comment["author"], at, excerpt(body))) }
        }
        for history in issue["changelog"]["histories"].list {
            let at = history["created"].text
            guard after(at) && history["author"]["name"].string != me else { continue }
            let items = history["items"].list, id = key + ":h:" + history["id"].text
            func change(_ item: JSONDocument) -> String { textOr(item["fromString"], "无") + " → " + textOr(item["toString"], "无") }
            if let status = items.first(where: { $0["field"].text == "status" }) { events.append(event(id, "status", history["author"], at, change(status))) }
            else if let assigned = items.first(where: { $0["field"].text == "assignee" }) {
                let mine = assigned["to"].string == me
                events.append(event(id, mine ? "assigned" : "field", history["author"], at, mine ? "分配给你" : "经办人：" + change(assigned)))
            } else if !items.isEmpty { events.append(event(id, "field", history["author"], at, items.map { $0["field"].text + "：" + change($0) }.joined(separator: "；"))) }
        }
        return events
    }
    public static func actions(_ issue: JSONDocument, me: String, start: Date, end: Date) -> [MyAction] {
        let key = issue["key"].text, fields = issue["fields"]
        func within(_ at: String) -> Bool { time(at).map { $0 >= start && $0 < end } ?? false }
        func action(_ at: String, _ kind: String, _ detail: String) -> MyAction { MyAction(at: at, kind: kind, key: key, summary: fields["summary"].text, detail: detail) }
        var result: [MyAction] = []
        let created = fields["created"].text
        if within(created) && fields["reporter"]["name"].string == me { result.append(action(created, "create", "")) }
        for comment in fields["comment"]["comments"].list where within(comment["created"].text) && comment["author"]["name"].string == me { result.append(action(comment["created"].text, "comment", excerpt(comment["body"].text))) }
        for history in issue["changelog"]["histories"].list {
            let at = history["created"].text
            guard within(at) && history["author"]["name"].string == me else { continue }
            var changed: [String] = []
            for item in history["items"].list {
                let field = item["field"].text
                switch field {
                case "status": result.append(action(at, "transition", textOr(item["fromString"], "无") + " → " + textOr(item["toString"], "无")))
                case "assignee": result.append(action(at, "assign", "分配给 " + textOr(item["toString"], "未分配")))
                case "resolution", "WorklogId", "timespent", "timeestimate": break
                default:
                    let name = ["Attachment":"附件", "description":"描述", "summary":"概要", "priority":"优先级", "labels":"标签", "duedate":"到期日", "Fix Version":"修复版本", "Version":"影响版本", "Component":"模块", "Link":"链接", "issuetype":"问题类型", "reporter":"报告人", "environment":"环境"][field] ?? field
                    if !changed.contains(name) { changed.append(name) }
                }
            }
            if !changed.isEmpty { result.append(action(at, "update", "修改了" + changed.joined(separator: "、"))) }
        }
        return result
    }
    static func textOr(_ value: JSONDocument, _ fallback: String) -> String {
        let text = JiraFields.text(value)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
    }
    public static func excerpt(_ body: String) -> String {
        var lines: [String] = [], quoted = false
        for line in body.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("{quote}") || line.hasSuffix("{quote}") {
                if !(line.count > 14 && line.hasPrefix("{quote}") && line.hasSuffix("{quote}")) { quoted.toggle() }
                continue
            }
            if !quoted && !line.hasPrefix("bq.") { lines.append(line) }
        }
        let chars = Array(lines.joined(separator: " ")), count = chars.count
        var index = 0, out = ""
        while index < count {
            let current = chars[index]
            if current == "[" || current == "!", let end = chars[(index + 1)...].firstIndex(of: current == "[" ? "]" : "!") {
                let inner = String(chars[(index + 1)..<end])
                if current == "[" || !inner.contains(" ") {
                    if current == "[" { out += inner.hasPrefix("~") ? "@" + inner.dropFirst() : String(inner.split(separator: "|", omittingEmptySubsequences: false).first ?? "") }
                    index = end + 1; continue
                }
            }
            if !["*", "{", "}"].contains(current) { out.append(current) }; index += 1
        }
        let text = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(text.prefix(160)) + (text.count > 160 ? "…" : "")
    }
}

extension JiraClient {
    public func activity(me: String, since: String, cutoff: Date) async throws -> [ActivityEvent] {
        let raw = try await get("/rest/api/2/search", query: [("jql", JiraActivity.activityJQL(me: me, since: since)), ("fields", "summary,issuetype,created,reporter,assignee,comment"), ("expand", "changelog"), ("maxResults", "50")])
        return raw["issues"].list.flatMap { JiraActivity.events($0, me: me, since: cutoff) }.sorted { $0.at > $1.at }
    }
    public func myActions(me: String, from: String, to: String, start: Date, end: Date) async throws -> [MyAction] {
        let raw = try await get("/rest/api/2/search", query: [("jql", JiraActivity.actionsJQL(from: from, to: to)), ("fields", "summary,created,reporter,comment"), ("expand", "changelog"), ("maxResults", "100")])
        return raw["issues"].list.flatMap { JiraActivity.actions($0, me: me, start: start, end: end) }.sorted { (JiraActivity.time($0.at) ?? .distantPast) < (JiraActivity.time($1.at) ?? .distantPast) }
    }
    public func myWorklogs(me: String, from: String, to: String) async throws -> [(IssueSummary, [Worklog])] {
        let issues = try await search("worklogAuthor = currentUser() AND worklogDate >= \"\(JiraQueries.escape(from))\" AND worklogDate <= \"\(JiraQueries.escape(to))\" ORDER BY project, updated DESC", maxResults: 50).issues
        var result: [(IssueSummary, [Worklog])] = []
        for issue in issues {
            let raw = try await get(Self.issuePath(issue.key) + "/worklog")
            let logs = raw["worklogs"].list.map { Worklog(raw: $0, me: me) }.filter { $0.mine && String($0.started.prefix(10)) >= from && String($0.started.prefix(10)) <= to }
            if !logs.isEmpty { result.append((issue, logs)) }
        }
        return result
    }
}
