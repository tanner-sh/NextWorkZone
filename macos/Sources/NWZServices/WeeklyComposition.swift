import Foundation
import NWZWiki

public struct WeeklyCodeWork: Codable, Hashable, Sendable {
    public var kind: String
    public var keys: [String]
    public var project: String
    public var evidence: String
    public var standalone: String?
    public init(kind: String, keys: [String], project: String, evidence: String, standalone: String?) {
        self.kind = kind; self.keys = keys; self.project = project; self.evidence = evidence; self.standalone = standalone
    }
}
public protocol WeeklyCodeSource: Sendable {
    func weeklyWork(from: String, to: String) async throws -> [WeeklyCodeWork]
}
struct WeeklyIssueWork: Sendable {
    var key = "", summary = "", project = "", progress = ""
    var evidence: [String] = []
}

/// 把同一件事的不同来源归在一起，分组与进度写法沿用往周周报。
enum WeeklyComposition {
    static func unique(_ text: String, into list: inout [String]) { if !list.contains(text) { list.append(text) } }
    static func guessIssue(_ text: String, issues: [WeeklyIssueWork]) -> Int? {
        let scores = issues.enumerated().map { ($0.offset, WeeklyReport.similarity(text, $0.element.summary)) }.sorted { $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= 0.2, best.1 >= (scores.dropFirst().first?.1 ?? 0) * 1.5 else { return nil }
        return best.0
    }
    static func duration(_ seconds: Int) -> String {
        let minutes = max(0, seconds + 59) / 60, hours = minutes / 60, rest = minutes % 60
        return hours == 0 ? "\(rest)m" : rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
    static func compose(from: String, to: String, weeks: [WeekEntry], issues initial: [WeeklyIssueWork], code: [WeeklyCodeWork], todos done: [(String, String?)], daily: [String], worklogs: [DraftGroup], wiki: [DraftGroup], notes: [String]) -> WeeklyDraft {
        let contents = weeks.map(\.content), last = weeks.first.map { WeeklyReport.pastItems($0.content) } ?? []
        let past = contents.flatMap(WeeklyReport.pastItems), pastGroups = WeeklyReport.pastGroups(contents), separator = WeeklyReport.pastSeparator(contents)
        var issues = initial, standalone: [(String, String)] = [], todos: [String] = []
        for event in code {
            if let i = issues.firstIndex(where: { event.keys.contains($0.key) }) { unique(event.evidence, into: &issues[i].evidence); continue }
            guard let text = event.standalone else { continue }
            if event.kind == "push", let i = guessIssue(text, issues: issues) { unique("提交（按内容推测）：" + text, into: &issues[i].evidence) }
            else { standalone.append((event.project, text)) }
        }
        for (title, key) in done {
            if let key, let i = issues.firstIndex(where: { $0.key == key }) { unique("完成待办：" + title, into: &issues[i].evidence) }
            else { todos.append(title) }
        }
        var groups: [DraftGroup] = []
        func add(_ title: String, source: String, item: DraftItem) {
            if let i = groups.firstIndex(where: { $0.title == title && $0.source == source }) {
                if !groups[i].items.contains(where: { $0.text == item.text }) { groups[i].items.append(item) }
            } else { groups.append(DraftGroup(title: title, source: source, items: [item])) }
        }
        for issue in issues {
            let title = WeeklyReport.guessGroup(issue.summary, past: past, groups: pastGroups) ?? issue.project
            add(title, source: "jira", item: DraftItem(text: issue.summary + separator + issue.progress, key: issue.key, evidence: issue.evidence, lastWeek: WeeklyReport.findSame(issue.summary, items: last)?.progress))
        }
        groups = groups.enumerated().sorted {
            let a = pastGroups.firstIndex(of: $0.element.title) ?? Int.max, b = pastGroups.firstIndex(of: $1.element.title) ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        groups += worklogs
        for (project, text) in standalone { add(project, source: "gitlab", item: DraftItem(text: text)) }
        groups += wiki
        if !todos.isEmpty { groups.append(DraftGroup(title: "完成的待办", source: "todo", items: todos.map { DraftItem(text: $0) })) }
        if !daily.isEmpty { groups.append(DraftGroup(title: "日记", source: "daily", items: daily.map { DraftItem(text: $0) })) }
        let current = groups.filter { $0.source == "jira" }.flatMap(\.items).map { item in
            let (text, progress) = WeeklyReport.splitProgress(item.text); return PastItem(text: text, progress: progress)
        }
        let carry = last.filter { !WeeklyReport.isFinished($0.progress) }.map { old in
            CarryOver(group: old.group, text: old.text, progress: old.progress, thisWeek: WeeklyReport.findSame(old.text, items: current).map { $0.text + ($0.progress.map { separator + $0 } ?? "") })
        }
        return WeeklyDraft(from: from, to: to, groups: groups, carryOver: carry, lastWeekTitle: weeks.first?.sectionTitle, separator: separator, notes: notes)
    }
}
