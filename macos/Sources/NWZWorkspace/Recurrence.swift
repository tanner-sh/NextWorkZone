import Foundation

extension Workspace {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    static func parseDay(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, value.count == 10,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])), formatDay(date) == value else { return nil }
        return date
    }
    static func formatDay(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    public nonisolated static func today() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    public nonisolated static func nextOccurrence(_ due: String?, _ rule: String, _ today: String) -> String? {
        guard let current = parseDay(today), ["daily", "weekdays", "weekly", "monthly"].contains(rule) else { return nil }
        var date = due.flatMap(parseDay) ?? current
        repeat {
            guard let next = calendar.date(byAdding: rule == "monthly" ? .month : .day, value: rule == "weekly" ? 7 : 1, to: date) else { return nil }
            date = next
            if rule == "weekdays" {
                while [1, 7].contains(calendar.component(.weekday, from: date)) {
                    guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
                    date = next
                }
            }
        } while date <= current
        return formatDay(date)
    }
}
