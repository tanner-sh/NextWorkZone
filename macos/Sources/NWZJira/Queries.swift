import Foundation
import NWZRich

public enum JiraQueries {
    public static func escape(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    public static func looksLikeKey(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].utf8.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
        return parts[0].utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 } && !parts[1].isEmpty && parts[1].utf8.allSatisfy { (48...57).contains($0) }
    }
    public static func similarJQL(key: String, summary: String, resolvedOnly: Bool) -> String? {
        let terms = summaryTerms(summary)
        guard !terms.isEmpty else { return nil }
        return "summary ~ \"\(escape(terms.joined(separator: " OR ")))\" AND key != \"\(escape(key))\"" + (resolvedOnly ? " AND resolution is not EMPTY" : "")
    }
    public static func summaryTerms(_ text: String) -> [String] {
        let stop: Set<String> = ["需要", "调整", "增加", "新增", "修改", "优化", "处理", "问题", "功能", "字段", "显示", "对应", "相关", "时候", "需求", "支持", "实现", "进行", "导致", "无法", "不能", "错误", "报错", "异常", "没有", "一个", "应该", "目前", "现在", "可以", "以及", "或者", "如果", "这个", "那个", "其中", "要求", "情况", "是否"]
        let particles = Set("的了与及和时需将在为是把被从等或并中对后前里上下".unicodeScalars)
        let chars = Array(text.unicodeScalars); var index = 0, result: [String] = []
        func cjk(_ value: Unicode.Scalar) -> Bool { (0x4e00...0x9fff).contains(value.value) }
        func ascii(_ value: Unicode.Scalar) -> Bool { (65...90).contains(value.value) || (97...122).contains(value.value) || (48...57).contains(value.value) }
        func push(_ value: String) { if result.count < 30 && !result.contains(value) { result.append(value) } }
        func string(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(chars[from..<to])) }
        while index < chars.count {
            let start = index
            if cjk(chars[index]) {
                while index < chars.count && cjk(chars[index]) { index += 1 }
                let candidates = index - start <= 2 ? [string(start, index)] : (start..<(index - 1)).map { string($0, $0 + 2) }
                for value in candidates where !stop.contains(value) && !value.unicodeScalars.contains(where: particles.contains) { push(value) }
            } else if ascii(chars[index]) {
                while index < chars.count && (ascii(chars[index]) || chars[index] == "_") { index += 1 }
                let word = string(start, index)
                if word.count > 1 && !word.utf8.allSatisfy({ (48...57).contains($0) }) { push(word) }
            } else { index += 1 }
        }
        return result
    }
}

public enum JiraForms {
    public static func commentLevels(_ html: String) -> [CommentLevel] {
        guard let select = HTMLNode.parse(html).first(where: { $0.tag == "select" && $0.attribute("name") == "commentLevel" }) else { return [] }
        return select.descendants(where: { $0.tag == "option" }).compactMap { option in
            let type = (option.attribute("value") ?? "").split(separator: ":").first.map(String.init) ?? ""
            guard ["role", "group"].contains(type) else { return nil }
            return CommentLevel(visibility: CommentVisibility(type: type, value: option.trimmed), label: option.trimmed)
        }
    }
    public static func suggestedAssignees(_ html: String) -> [UserRef] {
        guard let group = HTMLNode.parse(html).first(where: { $0.tag == "optgroup" && $0.attribute("id") == "assignee-group-suggested" }) else { return [] }
        return group.descendants(where: { $0.tag == "option" }).compactMap { option in
            let name = option.attribute("value") ?? ""
            return name.isEmpty || name == "-1" ? nil : UserRef(name: name, displayName: option.trimmed)
        }
    }
}
