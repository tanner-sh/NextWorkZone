import Foundation
import NWZCore

public enum JiraReminders {
    public static func candidates(configured: String, fields: [FieldInfo]) -> [FieldInfo] {
        func named(_ id: String) -> FieldInfo { fields.first { $0.id == id } ?? FieldInfo(id: id, name: id, custom: false, kind: "date") }
        if !configured.isEmpty { return [named(configured)] }
        var standard = named("duedate"); standard.name = fields.first { $0.id == "duedate" }?.name ?? "到期日"
        let words = ["到期", "截止", "期望完成", "计划完成", "完成日期", "due", "deadline"]
        return [standard] + fields.filter { $0.custom && ["date", "datetime"].contains($0.kind) && words.contains(where: $0.name.lowercased().contains) }.prefix(5)
    }
    public static func make(issues: [IssueSummary], candidates: [FieldInfo], config: JiraToolsConfig, now: Date = Date(), calendar: Calendar = .current) -> Reminders {
        func date(_ text: String) -> Date? {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard text.count == 10, let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
            return date
        }
        func due(_ field: FieldInfo, _ issue: IssueSummary) -> String? {
            let raw = field.id == "duedate" ? issue.dueDate : issue.extra?[field.id]
            guard let raw, raw.count >= 10 else { return nil }
            let day = String(raw.prefix(10)); return date(day) != nil ? day : nil
        }
        let field = config.dueField.isEmpty ? candidates.first { field in issues.contains { due(field, $0) != nil } } : candidates.first
        let today = calendar.startOfDay(for: now)
        var dates: [String: String] = [:], items: [Reminder] = []
        for issue in issues {
            let due = field.flatMap { due($0, issue) }
            if let due { dates[issue.key] = due }
            let dueDays = due.flatMap(date).flatMap { calendar.dateComponents([.day], from: today, to: $0).day }
            let idle = JiraActivity.time(issue.updated).flatMap { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: today).day }
            let kind: String, days: Int
            if let value = dueDays, value < 0 { kind = "overdue"; days = value }
            else if dueDays == 0 { kind = "today"; days = 0 }
            else if let value = dueDays, value <= config.dueSoonDays { kind = "soon"; days = value }
            else if let value = idle, config.staleDays > 0 && value >= config.staleDays { kind = "stale"; days = value }
            else { continue }
            items.append(Reminder(issue: issue, kind: kind, due: due, days: days))
        }
        func rank(_ value: Reminder) -> (Int, Int) { (["overdue":0, "today":1, "soon":2][value.kind] ?? 3, value.kind == "stale" ? -value.days : value.days) }
        items.sort { rank($0) < rank($1) }
        return Reminders(dueField: field.map { DueFieldRef(id: $0.id, name: $0.name) }, items: items, dueDates: dates, remind: config.remind)
    }
}

extension Reminder {
    public init(issue: IssueSummary, kind: String, due: String?, days: Int) {
        self.init(key: issue.key, summary: issue.summary, status: issue.status, issueType: issue.issueType, priority: issue.priority, project: issue.project, assignee: issue.assignee, assigneeName: issue.assigneeName, reporter: issue.reporter, reporterName: issue.reporterName, lastViewed: issue.lastViewed, resolution: issue.resolution, created: issue.created, updated: issue.updated, dueDate: issue.dueDate, extra: issue.extra, kind: kind, due: due, days: days)
    }
}
