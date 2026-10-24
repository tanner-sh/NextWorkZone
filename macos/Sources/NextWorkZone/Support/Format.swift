import Foundation

/// 时间、日期、大小的显示方式，与 src/lib/format.ts、src/lib/workspace.ts 相同。
enum Fmt {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 解析三个系统返回的时间。Jira 使用 `+0800` 形式的时区，需要先补上冒号。
    static func parse(_ value: String?) -> Date? {
        guard var value, !value.isEmpty else { return nil }
        if let m = value.firstMatch(of: /([+-]\d{2})(\d{2})$/) {
            value = String(value[..<m.range.lowerBound]) + m.1 + ":" + m.2
        }
        if let d = iso.date(from: value) ?? isoNoFraction.date(from: value) { return d }
        // 只有日期
        if value.count == 10 { return dayFormatter.date(from: value) }
        // 小数位多于三位（例如微秒）
        if let m = value.firstMatch(of: /^(.+\.\d{3})\d+(.*)$/) { return iso.date(from: String(m.1) + String(m.2)) }
        return nil
    }

    static func ms(_ value: String?) -> Int64 {
        guard let d = parse(value) else { return 0 }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// 一小时内显示“x 分钟前”，当天显示时间，今年显示月日，否则显示完整日期。
    static func time(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        guard let date = parse(value) else { return value }
        return time(date)
    }

    static func time(_ date: Date) -> String {
        let now = Date()
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes >= 0 && minutes < 60 { return minutes <= 1 ? "刚刚" : "\(minutes) 分钟前" }
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hm = "\(pad(c.hour!)):\(pad(c.minute!))"
        if cal.isDateInToday(date) { return "今天 \(hm)" }
        let md = "\(pad(c.month!))-\(pad(c.day!))"
        if c.year == cal.component(.year, from: now) { return "\(md) \(hm)" }
        return "\(c.year!)-\(md)"
    }

    static func time(ms: Int64) -> String { time(Date(timeIntervalSince1970: Double(ms) / 1000)) }

    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    static func size(_ bytes: Int) -> String { size(Int64(bytes)) }

    /// Jira 时长（3d 4h 30m）显示为中文单位（3日 4小时 30分钟）。
    static func duration(_ value: String) -> String {
        let units = ["w": "周", "d": "日", "h": "小时", "m": "分钟"]
        return value.replacing(/(\d+(?:\.\d+)?)([wdhm])\b/) { m in "\(m.1)\(units[String(m.2)]!)" }
    }

    // MARK: 日期（YYYY-MM-DD）

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func today() -> String { day(Date()) }

    static func date(ofDay day: String) -> Date? { dayFormatter.date(from: day) }

    static func addDays(_ day: String, _ days: Int) -> String {
        guard let d = date(ofDay: day), let r = Calendar.current.date(byAdding: .day, value: days, to: d) else { return day }
        return self.day(r)
    }

    /// 下一个周一。
    static func nextMonday() -> String {
        let weekday = Calendar.current.component(.weekday, from: Date()) - 1 // 0 = 周日
        let offset = ((8 - weekday) % 7 == 0) ? 7 : (8 - weekday) % 7
        return addDays(today(), offset)
    }

    private static let weekdays = Array("日一二三四五六")

    /// 截止日期的显示：今天、明天、昨天、本周内显示星期，否则显示月日。
    static func dayLabel(_ day: String) -> String {
        let t = today()
        if day == t { return "今天" }
        if day == addDays(t, 1) { return "明天" }
        if day == addDays(t, -1) { return "昨天" }
        guard let date = date(ofDay: day), let todayDate = self.date(ofDay: t) else { return day }
        let c = Calendar.current.dateComponents([.year, .month, .day, .weekday], from: date)
        let diff = Int((date.timeIntervalSince(todayDate) / 86400).rounded())
        if diff > 1 && diff < 7 { return "周\(weekdays[c.weekday! - 1])" }
        return c.year == Calendar.current.component(.year, from: Date()) ? "\(c.month!)月\(c.day!)日" : "\(c.year!)年\(c.month!)月\(c.day!)日"
    }

    static func weekday(_ day: String) -> String {
        guard let date = date(ofDay: day) else { return "" }
        return "星期\(weekdays[Calendar.current.component(.weekday, from: date) - 1])"
    }

    /// 某天某个钟点的时间戳（毫秒）。
    static func at(_ day: String, hour: Int, minute: Int = 0) -> Int64 {
        guard let d = date(ofDay: day), let r = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: d) else { return 0 }
        return Int64(r.timeIntervalSince1970 * 1000)
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 提醒时间的显示，例如“今天 18:00”“明天 09:00”。
    static func moment(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return "\(dayLabel(day(d))) \(pad(c.hour!)):\(pad(c.minute!))"
    }

    /// 常用的提醒、稍后提醒时间：1 小时后、今天傍晚（已过时不提供）、明天上午、下周一上午。
    static func momentPresets() -> [(label: String, at: Int64)] {
        let now = nowMs()
        let t = today()
        var list: [(String, Int64)] = [("1 小时后", now + 3_600_000)]
        if at(t, hour: 18) - now > 3_600_000 { list.append(("今天 18:00", at(t, hour: 18))) }
        list.append(("明天 09:00", at(addDays(t, 1), hour: 9)))
        list.append(("下周一 09:00", at(nextMonday(), hour: 9)))
        return list
    }

    static let repeatLabels = ["daily": "每天", "weekdays": "工作日", "weekly": "每周", "monthly": "每月"]
}

/// 开发版的调试输出（写到标准错误，不经缓冲）。
func debugLog(_ text: String) {
    #if DEBUG
    FileHandle.standardError.write(Data((text + "\n").utf8))
    #endif
}
