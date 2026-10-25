import Foundation
import NWZCore
import NWZJira
import NWZWiki
import NWZWorkspace

public struct WeeklyService: Sendable {
    let settings: SettingsService
    let jira: JiraService
    let wiki: WikiService
    let code: any WeeklyCodeSource
    public init(settings: SettingsService, jira: JiraService, wiki: WikiService, code: any WeeklyCodeSource) {
        self.settings = settings; self.jira = jira; self.wiki = wiki; self.code = code
    }
    private func target() async throws -> (WikiClient, String, String) {
        let config = settings.configuration.snapshot().weekly
        guard !config.pageId.isEmpty else { throw NWZError.other("请先在设置中填写周报页面地址") }
        let client = try await wiki.client(), name = try await client.resolvePersonName(config.personName)
        return (client, config.pageId, name)
    }
    public func load(section: String? = nil) async throws -> WeeklyView {
        let (client, page, name) = try await target()
        return try await client.weeklyLoad(page: page, name: name, section: section)
    }
    public func save(_ input: WeeklySaveInput) async throws -> SaveResult {
        let (client, page, name) = try await target()
        let result = try await client.weeklySave(page: page, name: name, section: input.section, expected: (input.contentRaw, input.riskRaw), content: input.content, risk: input.risk)
        await wiki.requestIndexSync(); return result
    }
    public func createWeek() async throws -> WeeklyView {
        let (client, page, name) = try await target(), title = try await client.weeklyCreateWeek(page: page)
        await wiki.requestIndexSync()
        return try await client.weeklyLoad(page: page, name: name, section: title)
    }
    private func history(section: String?) async throws -> [WeekEntry] {
        guard let section else { return [] }
        let (client, page, name) = try await target()
        return try await client.weeklyHistory(page: page, name: name, section: section)
    }
    private func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
    public func draft(section: String?, workspace: Workspace, today: Date = Date()) async throws -> WeeklyDraft {
        let calendar = Calendar.current, day = calendar.startOfDay(for: today)
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: day) + 5) % 7), to: day)!
        let (start, last) = section.flatMap { Weekly.parseRange($0, today: day) } ?? (monday, calendar.date(byAdding: .day, value: 6, to: monday)!)
        let end = calendar.date(byAdding: .day, value: 1, to: last)!
        let from = Self.day(start), to = Self.day(last), endDay = Self.day(end)
        async let past = capture { try await history(section: section) }
        async let issues = capture { try await jiraWork(from: from, endDay: endDay, start: start, end: end) }
        async let logs = capture { try await worklogDraft(from: from, to: to) }
        async let gitlab = capture { try await code.weeklyWork(from: from, to: to) }
        async let pages = capture { try await wikiDraft(from: from, end: endDay) }
        async let local = capture { try await workspaceWork(workspace, start: start, end: end) }
        let results = await (past, issues, logs, gitlab, pages, local)
        var notes: [String] = []
        func value<T>(_ result: Result<T, Error>, label: String, fallback: T) -> T {
            switch result { case .success(let value): return value; case .failure(let error): notes.append(label + "：" + error.localizedDescription); return fallback }
        }
        let weeks = value(results.0, label: "往周周报", fallback: []), work = value(results.1, label: "Jira", fallback: []), code = value(results.3, label: "GitLab", fallback: [])
        let (todos, daily) = value(results.5, label: "工作空间", fallback: ([], []))
        let worklogs = value(results.2, label: "工作日志", fallback: []), wiki = value(results.4, label: "Wiki", fallback: [])
        return WeeklyComposition.compose(from: from, to: to, weeks: weeks, issues: work, code: code, todos: todos, daily: daily, worklogs: worklogs, wiki: wiki, notes: notes)
    }
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    private func jiraWork(from: String, endDay: String, start: Date, end: Date) async throws -> [WeeklyIssueWork] {
        guard let client = try? await jira.client() else { return [] }
        let me = try await jira.me()
        let jql = "((assignee = currentUser() AND updated >= \"\(from)\" AND updated < \"\(endDay)\") OR status CHANGED BY currentUser() DURING (\"\(from)\", \"\(endDay)\")) ORDER BY project, updated DESC"
        async let found = client.search(jql)
        async let actionsResult = capture { try await client.myActions(me: me, from: from, to: endDay, start: start, end: end) }
        var issues = try await found.issues
        let actions = (try? await actionsResult.get()) ?? []
        let missing = Set(actions.map(\.key)).subtracting(issues.map(\.key)).sorted()
        if !missing.isEmpty, let more = try? await client.search("key in (" + missing.joined(separator: ",") + ") ORDER BY project, updated DESC") { issues += more.issues }
        return issues.map { issue in
            let mine = actions.filter { $0.key == issue.key }
            var evidence: [String] = [], chain: [String] = []
            if mine.contains(where: { $0.kind == "create" }) { evidence.append("创建") }
            for action in mine where action.kind == "transition" {
                let parts = action.detail.components(separatedBy: " → ")
                guard parts.count >= 2 else { continue }
                if chain.last != parts[0] {
                    if !chain.isEmpty { evidence.append("流转：" + chain.joined(separator: " → ")) }
                    chain = [parts[0]]
                }
                chain.append(parts[1])
            }
            if chain.count > 1 { evidence.append("流转：" + chain.joined(separator: " → ")) }
            let comments = mine.filter { $0.kind == "comment" }.count
            if comments > 0 { evidence.append("评论 \(comments) 条") }
            return WeeklyIssueWork(key: issue.key, summary: issue.summary.trimmingCharacters(in: .whitespacesAndNewlines), project: issue.project.name, progress: issue.status.category == "done" ? "100%" : issue.status.name, evidence: evidence)
        }
    }
    private func worklogDraft(from: String, to: String) async throws -> [DraftGroup] {
        guard let client = try? await jira.client() else { return [] }
        let logs = try await client.myWorklogs(me: jira.me(), from: from, to: to)
        guard !logs.isEmpty else { return [] }
        var total = 0
        let items = logs.map { issue, logs in
            let seconds = logs.reduce(0) { $0 + $1.timeSpentSeconds }; total += seconds
            var comments: [String] = []
            for comment in logs.map({ $0.comment.trimmingCharacters(in: .whitespacesAndNewlines) }) where !comment.isEmpty && comments.last != comment { comments.append(comment) }
            return DraftItem(text: issue.summary + "（" + WeeklyComposition.duration(seconds) + "）" + (comments.isEmpty ? "" : "：" + comments.joined(separator: "；")), key: issue.key)
        }
        return [DraftGroup(title: "工作日志 · 合计 " + WeeklyComposition.duration(total), source: "worklog", items: items)]
    }
    private func wikiDraft(from: String, end: String) async throws -> [DraftGroup] {
        guard let client = try? await wiki.client() else { return [] }
        let weeklyPage = settings.configuration.snapshot().weekly.pageId
        let work = try await client.myWork(from: from, to: end)
        var items: [DraftItem] = []
        for item in work where item.kind != "comment" && item.pageId != weeklyPage {
            if !items.contains(where: { $0.text.hasSuffix("：" + item.title) }) { items.append(DraftItem(text: (item.kind == "create" ? "新建" : "更新") + " Wiki 页面：" + item.title)) }
        }
        return items.isEmpty ? [] : [DraftGroup(title: "Wiki", source: "wiki", items: items)]
    }
    private func workspaceWork(_ store: Workspace, start: Date, end: Date) async throws -> ([(String, String?)], [String]) {
        let from = Int64(start.timeIntervalSince1970 * 1000), to = Int64(end.timeIntervalSince1970 * 1000)
        let todos = try await store.todos().filter { $0.done && !$0.autoDone && $0.source != "jira" && ($0.completedAt.map { $0 >= from && $0 < to } ?? false) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { ($0.title, $0.refSystem == "jira" ? $0.refKey : nil) }
        var day = start, lines: [String] = []
        while day < end {
            let doc = try await store.daily(Self.day(day))
            for line in References.plainText(doc.content).components(separatedBy: "\n") {
                var text = String(line.drop(while: { "-*+ ".contains($0) }))
                for marker in ["[ ]", "[x]"] { if text.hasPrefix(marker) { text = String(text.dropFirst(marker.count)) } }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { WeeklyComposition.unique(text, into: &lines) }
            }
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }; day = next
        }
        return (todos, lines)
    }
}
