import Foundation

/// 页面按可读段落比较，输出统一 diff，供界面与代码差异共用同一个视图。
public enum WikiDiff {
    public static func unified(_ oldStorage: String, _ newStorage: String) -> String {
        text(WikiText.readableLines(oldStorage).joined(separator: "\n") + "\n", WikiText.readableLines(newStorage).joined(separator: "\n") + "\n")
    }

    public static func text(_ old: String, _ new: String) -> String {
        guard old != new else { return "" }
        func lines(_ s: String) -> [String] {
            guard !s.isEmpty else { return [] }
            let parts = s.components(separatedBy: "\n")
            return parts.dropLast().map { $0 + "\n" } + (parts.last == "" ? [] : [parts.last!])
        }
        let a = lines(old), b = lines(new), difference = b.difference(from: a)
        var removes: Set<Int> = [], inserts: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let i, _, _): removes.insert(i)
            case .insert(let i, _, _): inserts.insert(i)
            }
        }
        struct Line {
            var sign: String
            var text: String
            var old: Int
            var new: Int
        }
        var edits: [Line] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if removes.contains(i), i < a.count { edits.append(Line(sign: "-", text: a[i], old: i, new: j)); i += 1 }
            else if inserts.contains(j), j < b.count { edits.append(Line(sign: "+", text: b[j], old: i, new: j)); j += 1 }
            else if i < a.count, j < b.count { edits.append(Line(sign: " ", text: a[i], old: i, new: j)); i += 1; j += 1 }
            else { break }
        }
        var groups: [Range<Int>] = []
        for (n, line) in edits.enumerated() where line.sign != " " {
            let range = max(0, n - 3)..<min(edits.count, n + 4)
            if let last = groups.last, range.lowerBound <= last.upperBound { groups[groups.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound) }
            else { groups.append(range) }
        }
        func position(_ offset: Int, _ count: Int) -> String { count == 1 ? String(offset + 1) : "\(offset + (count == 0 ? 0 : 1)),\(count)" }
        return groups.map { range in
            let group = edits[range], first = edits[range.lowerBound]
            let oldCount = group.filter { $0.sign != "+" }.count, newCount = group.filter { $0.sign != "-" }.count
            var out = "@@ -\(position(first.old, oldCount)) +\(position(first.new, newCount)) @@\n"
            for line in group {
                out += line.sign + line.text
                if !line.text.hasSuffix("\n") { out += "\n\\ No newline at end of file\n" }
            }
            return out
        }.joined()
    }
}
