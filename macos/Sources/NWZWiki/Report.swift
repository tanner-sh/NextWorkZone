import Foundation

public struct PastItem: Codable, Hashable, Sendable {
    public var group: String
    public var text: String
    public var progress: String?
    public init(group: String = "", text: String, progress: String? = nil) { self.group = group; self.text = text; self.progress = progress }
}

/// 分组与进度写法来自往周内容，缺少历史时使用中性的默认分隔符。
public enum WeeklyReport {
    public static let defaultSeparator = " --"
    private static func progressParts(_ text: String) -> (String, String, String)? {
        guard let match = text.wholeMatch(of: /(?s)(.*?\S)(\s*(?:-{2,}|–|—)\s*)([^\s\-–—][^\-–—]{0,11})\s*/) else { return nil }
        return (String(match.1), String(match.2), String(match.3).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public static func splitProgress(_ text: String) -> (String, String?) {
        if let parts = progressParts(text) { return (parts.0, parts.2) }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
    public static func isFinished(_ progress: String?) -> Bool { progress.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "100%" || $0.contains("完成") } ?? false }
    public static func similarity(_ a: String, _ b: String) -> Double {
        func normalize(_ text: String) -> [UnicodeScalar] { Array(String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })).lowercased().unicodeScalars) }
        let a = normalize(a), b = normalize(b)
        if a.isEmpty || b.isEmpty { return 0 }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 6, (0...(long.count - short.count)).contains(where: { long[$0..<($0 + short.count)].elementsEqual(short) }) { return 1 }
        if a.count < 2 || b.count < 2 { return a == b ? 1 : 0 }
        let pa = (0..<(a.count - 1)).map { String(String.UnicodeScalarView(a[$0...($0 + 1)])) }
        var pb = (0..<(b.count - 1)).map { String(String.UnicodeScalarView(b[$0...($0 + 1)])) }
        let total = pa.count + pb.count
        var common = 0
        for pair in pa { if let i = pb.firstIndex(of: pair) { pb.remove(at: i); common += 1 } }
        return 2 * Double(common) / Double(total)
    }
    public static func pastItems(_ content: [OutlineItem]) -> [PastItem] {
        let nested = content.contains { $0.level > 0 }
        var group = "", out: [PastItem] = []
        for item in content {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if nested && item.level == 0 { group = text; continue }
            let (body, progress) = splitProgress(text)
            out.append(PastItem(group: nested ? group : "", text: body, progress: progress))
        }
        return out
    }
    public static func pastGroups(_ weeks: [[OutlineItem]]) -> [String] {
        var counts: [(String, Int)] = []
        for week in weeks where week.contains(where: { $0.level > 0 }) {
            for item in week where item.level == 0 {
                let title = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { continue }
                if let i = counts.firstIndex(where: { $0.0 == title }) { counts[i].1 += 1 }
                else { counts.append((title, 1)) }
            }
        }
        return counts.enumerated().sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 > $1.element.1 }.map { $0.element.0 }
    }
    public static func pastSeparator(_ weeks: [[OutlineItem]]) -> String {
        var counts: [String: Int] = [:]
        for item in weeks.flatMap({ $0 }) {
            if let parts = progressParts(item.text.trimmingCharacters(in: .whitespacesAndNewlines)) { counts[parts.1, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first?.key ?? defaultSeparator
    }
    public static func findSame(_ text: String, items: [PastItem]) -> PastItem? {
        var best: PastItem?, score = 0.6
        for item in items {
            let current = similarity(text, item.text)
            if current >= score { score = current; best = item }
        }
        return best
    }
    public static func guessGroup(_ text: String, past: [PastItem], groups: [String]) -> String? {
        if let same = findSame(text, items: past), !same.group.isEmpty { return same.group }
        return groups.filter { $0.count >= 2 && text.contains($0) }.enumerated().max { $0.element.count == $1.element.count ? $0.offset < $1.offset : $0.element.count < $1.element.count }?.element
    }
}
