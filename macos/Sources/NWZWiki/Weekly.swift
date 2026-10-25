import Foundation
import NWZCore
import NWZRich

public struct WeeklyOverview: Codable, Hashable, Sendable {
    public var sections: [SectionInfo]
    public var currentWeekTitle: String
    public var currentWeekExists: Bool
    public var defaultSection: String? { (sections.first { $0.coversToday } ?? sections.first)?.title }
}
public struct WeeklyEdit: Sendable {
    public var storage: String
    public var changed: Bool
}

/// 只改写匹配到的人名行，所有范围都指向原文的 UTF-8 字节。
public enum Weekly {
    struct Section { var title: String; var tokens: Range<Int>; var start: Int }
    static func sections(_ doc: StorageDocument) -> [Section] {
        let heads = doc.findChildren(doc.tokens.indices, depth: 0, name: "h1")
        return heads.enumerated().map { i, open in
            Section(title: doc.text(doc.children(open)), tokens: open..<(i + 1 < heads.count ? heads[i + 1] : doc.tokens.count), start: doc.tokens[open].span.lowerBound)
        }.filter { !$0.title.isEmpty }
    }
    private static func date(_ y: Int, _ m: Int, _ d: Int, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)), calendar.component(.year, from: date) == y, calendar.component(.month, from: date) == m, calendar.component(.day, from: date) == d else { return nil }
        return date
    }
    public static func parseRange(_ title: String, today: Date, calendar: Calendar = .current) -> (Date, Date)? {
        let nums = title.split { !$0.isASCII || !$0.isNumber }.prefix(4).compactMap { Int($0) }
        guard nums.count == 4 else { return nil }
        let today = calendar.startOfDay(for: today), year = calendar.component(.year, from: today)
        guard var start = date(year, nums[0], nums[1], calendar: calendar), var end = date(year, nums[2], nums[3], calendar: calendar) else { return nil }
        if end < start { guard let next = date(year + 1, nums[2], nums[3], calendar: calendar) else { return nil }; end = next }
        if start > calendar.date(byAdding: .day, value: 60, to: today)! {
            guard let s = date(year - 1, nums[0], nums[1], calendar: calendar), let e = date(calendar.component(.year, from: end) - 1, nums[2], nums[3], calendar: calendar) else { return nil }
            start = s; end = e
        }
        return (start, end)
    }
    public static func weekTitle(today: Date, template: String? = nil, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: today), offset = (calendar.component(.weekday, from: day) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -offset, to: day)!, sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
        let style = template.flatMap(DateStyle.detect) ?? DateStyle()
        func fmt(_ n: Int) -> String { style.padded ? String(format: "%02d", n) : String(n) }
        return fmt(calendar.component(.month, from: monday)) + style.dateSep + fmt(calendar.component(.day, from: monday)) + style.rangeSep + fmt(calendar.component(.month, from: sunday)) + style.dateSep + fmt(calendar.component(.day, from: sunday))
    }
    private struct DateStyle {
        var dateSep = ".", rangeSep = "-", padded = true
        static func detect(_ title: String) -> DateStyle? {
            var numbers: [String] = [], separators: [String] = [], rest = title.drop(while: \.isWhitespace)
            while numbers.count < 4 {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard (1...2).contains(digits.count) else { return nil }
                numbers.append(String(digits)); rest = rest.dropFirst(digits.count)
                if numbers.count < 4 {
                    let sep = rest.prefix { !$0.isASCII || !$0.isNumber }
                    guard (1...3).contains(sep.utf8.count) else { return nil }
                    separators.append(String(sep)); rest = rest.dropFirst(sep.count)
                }
            }
            return DateStyle(dateSep: separators[0], rangeSep: separators[1], padded: numbers.allSatisfy { $0.count == 2 })
        }
    }
    public static func overview(_ storage: String, today: Date, calendar: Calendar = .current) throws -> WeeklyOverview {
        let all = sections(try StorageDocument(storage)), today = calendar.startOfDay(for: today)
        func covers(_ title: String) -> Bool { parseRange(title, today: today, calendar: calendar).map { $0 <= today && today <= $1 } ?? false }
        return WeeklyOverview(sections: all.prefix(6).map { SectionInfo(title: $0.title, coversToday: covers($0.title)) }, currentWeekTitle: weekTitle(today: today, template: all.first?.title, calendar: calendar), currentWeekExists: all.contains { covers($0.title) })
    }
    static func tableRows(_ doc: StorageDocument, _ table: Int) -> [Int] {
        let depth = doc.tokens[table].depth
        return doc.children(table).filter { doc.tokens[$0].kind == .start && doc.tokens[$0].name == "tr" && (doc.tokens[$0].depth == depth + 1 || doc.tokens[$0].depth == depth + 2) }
    }
    static func rowCells(_ doc: StorageDocument, _ row: Int) -> [Int] {
        let depth = doc.tokens[row].depth + 1
        return (doc.findChildren(doc.children(row), depth: depth, name: "td") + doc.findChildren(doc.children(row), depth: depth, name: "th")).sorted()
    }
    private static func row(_ doc: StorageDocument, _ section: Section, _ name: String) -> [Int]? {
        let wanted = WikiStorage.collapseWhitespace(name).replacingOccurrences(of: " ", with: "")
        return doc.findChildren(section.tokens, depth: 0, name: "table").flatMap { tableRows(doc, $0) }.map { rowCells(doc, $0) }.first { $0.count >= 2 && doc.text(doc.children($0[0])).replacingOccurrences(of: " ", with: "") == wanted }
    }
    private static func section(_ doc: StorageDocument, _ title: String) throws -> Section {
        guard let s = sections(doc).first(where: { $0.title == title }) else { throw NWZError.other("页面中没有找到小节「\(title)」，它可能已被他人改名或删除") }
        return s
    }
    public static func entry(_ storage: String, section title: String, name: String) throws -> WeekEntry {
        let doc = try StorageDocument(storage), s = try section(doc, title)
        guard let cells = row(doc, s, name) else { return WeekEntry(sectionTitle: title) }
        let (content, lossyContent) = parseOutline(doc, doc.children(cells[1]))
        let (risk, lossyRisk) = cells.count > 2 ? parseOutline(doc, doc.children(cells[2])) : ([], false)
        return WeekEntry(sectionTitle: title, rowFound: true, content: normalize(content), risk: normalize(risk), contentRaw: doc.string(doc.inner(cells[1])), riskRaw: cells.count > 2 ? doc.string(doc.inner(cells[2])) : "", lossy: lossyContent || lossyRisk)
    }
    public static func applyEntry(_ storage: String, section title: String, name: String, expected: (String, String)? = nil, content: [OutlineItem], risk: [OutlineItem]) throws -> WeeklyEdit {
        let doc = try StorageDocument(storage), s = try section(doc, title)
        guard let cells = row(doc, s, name) else { throw NWZError.other("小节「\(title)」中没有找到「\(name)」的行") }
        let contentRange = doc.inner(cells[1]), riskRange = cells.count > 2 ? doc.inner(cells[2]) : nil
        if let expected, doc.string(contentRange) != expected.0 || (riskRange.map(doc.string) ?? "") != expected.1 {
            throw NWZError.conflict("你在这一周的周报内容在 Wiki 上已被修改（可能是在网页中编辑过），请重新加载后再编辑")
        }
        var replacements: [(Range<Int>, String)] = [(contentRange, renderOutline(content))]
        if let riskRange { replacements.append((riskRange, renderOutline(risk))) }
        replacements.removeAll { outline(doc.string($0.0)) == outline($0.1) }
        return WeeklyEdit(storage: replace(doc.bytes, replacements), changed: !replacements.isEmpty)
    }
    public static func insertWeek(_ storage: String, title: String) throws -> String {
        let doc = try StorageDocument(storage), all = sections(doc)
        guard !all.contains(where: { $0.title.hasPrefix(title) }) else { throw NWZError.other("小节「\(title)」已存在") }
        guard let latest = all.first else { throw NWZError.other("页面中没有可作为模板的周小节") }
        let end = all.count > 1 ? all[1].start : doc.bytes.count
        var replacements = [(doc.inner(latest.tokens.lowerBound), WikiStorage.escapeText(title))]
        for table in doc.findChildren(latest.tokens, depth: 0, name: "table") {
            let rows = tableRows(doc, table).map { doc.findChildren(doc.children($0), depth: doc.tokens[$0].depth + 1, name: "td") }.filter { !$0.isEmpty }
            let names = rows.count >= 2 && rows.allSatisfy { cells in
                let first = cells[0], text = doc.text(doc.children(first))
                let structured = doc.children(first).contains { doc.tokens[$0].kind == .start && ["ul", "ol", "table", "p", "div"].contains(doc.tokens[$0].name) }
                return !structured && !text.isEmpty && text.count <= 20
            }
            for cells in rows {
                for (col, td) in cells.enumerated() where !names || col != 0 { replacements.append((doc.inner(td), "<br />")) }
            }
        }
        let source = Array(doc.bytes[latest.start..<end])
        let relative = replacements.map { (($0.0.lowerBound - latest.start)..<($0.0.upperBound - latest.start), $0.1) }
        return doc.string(0..<latest.start) + replace(source, relative) + doc.string(latest.start..<doc.bytes.count)
    }
    static func replace(_ bytes: [UInt8], _ replacements: [(Range<Int>, String)]) -> String {
        var out = bytes
        for (range, text) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { out.replaceSubrange(range, with: text.utf8) }
        return String(decoding: out, as: UTF8.self)
    }
    static func outline(_ html: String) -> [OutlineItem] {
        guard let doc = try? StorageDocument(html) else { return [] }
        return normalize(parseOutline(doc, doc.tokens.indices).0)
    }
    private static func parseOutline(_ doc: StorageDocument, _ range: Range<Int>) -> ([OutlineItem], Bool) {
        var items: [OutlineItem] = [], stack: [Int] = [], depth = 0, loose: Int?, lossy = false
        for i in range {
            let tok = doc.tokens[i], raw = doc.tag(i)
            switch tok.kind {
            case .start, .empty:
                if !["ul", "ol", "li", "p", "br", "span", "div"].contains(tok.name) || (tok.name == "span" && raw.contains("font-weight")) { lossy = true }
                switch (tok.kind, tok.name) {
                case (.start, "ul"), (.start, "ol"): depth += 1; loose = nil
                case (.start, "li"): items.append(OutlineItem(level: max(0, depth - 1), text: "")); stack.append(items.count - 1)
                case (.start, "p"), (.start, "div"):
                    if stack.isEmpty { items.append(OutlineItem(level: depth, text: "")); loose = items.count - 1 }
                case (.empty, "br"):
                    if let i = stack.last ?? loose { items[i].text += " " }
                default: break
                }
            case .end:
                switch tok.name {
                case "ul", "ol": depth = max(0, depth - 1)
                case "li": _ = stack.popLast()
                case "p", "div": if stack.isEmpty { loose = nil }
                default: break
                }
            case .text:
                let text = WikiStorage.decodeEntities(raw)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && stack.isEmpty && loose == nil { continue }
                let target: Int
                if let index = stack.last ?? loose { target = index }
                else { items.append(OutlineItem(level: 0, text: "")); loose = items.count - 1; target = items.count - 1 }
                items[target].text += text
            case .other: lossy = true
            }
        }
        return (items, lossy)
    }
    static func normalize(_ items: [OutlineItem]) -> [OutlineItem] {
        var out: [OutlineItem] = []
        for item in items {
            let text = WikiStorage.collapseWhitespace(item.text)
            if text.isEmpty { continue }
            out.append(OutlineItem(level: min(max(0, item.level), out.last.map { $0.level + 1 } ?? 0), text: text))
        }
        return out
    }
    public static func renderOutline(_ items: [OutlineItem]) -> String {
        let items = normalize(items)
        guard !items.isEmpty else { return "<br />" }
        var out = "", current = -1
        for item in items {
            let level = min(item.level, current + 1)
            if level > current { out += "<ul>" }
            else {
                while current > level { out += "</li></ul>"; current -= 1 }
                out += "</li>"
            }
            out += "<li>" + WikiStorage.escapeText(item.text); current = level
        }
        while current >= 0 { out += "</li></ul>"; current -= 1 }
        return out
    }
}
