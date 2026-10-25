import Foundation
import NWZRich

public struct InlineTask: Codable, Hashable, Sendable {
    public var taskId: String
    public var done: Bool
    public var text: String
    public var assignees: [String]
    public var due: String?
    public init(taskId: String = "", done: Bool = false, text: String = "", assignees: [String] = [], due: String? = nil) {
        self.taskId = taskId; self.done = done; self.text = text; self.assignees = assignees; self.due = due
    }
}

public enum WikiText {
    private static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "pre", "blockquote", "table", "ul", "ol", "hr", "ac:task", "ac:layout-cell", "ac:layout-section", "ac:rich-text-body", "ac:plain-text-body"]

    public static func readableLines(_ storage: String) -> [String] {
        guard let doc = try? StorageDocument(storage) else {
            return [WikiStorage.collapseWhitespace(WikiStorage.decodeEntities(storage.replacing(/<[^>]*>/, with: " ")))]
        }
        var out = Lines(), macros: [String] = [], cells = 0, i = 0
        while i < doc.tokens.count {
            let tok = doc.tokens[i], name = tok.name, tag = doc.tag(i)
            switch tok.kind {
            case .start, .empty:
                if blockTags.contains(name) { out.newlineOrSpace(cells > 0) }
                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6": out.current += String(repeating: "#", count: Int(name.dropFirst()) ?? 1) + " "
                case "li": out.current += "- "
                case "td", "th":
                    out.current += " | "
                    if tok.kind == .start { cells += 1 }
                case "br": out.newlineOrSpace(cells > 0)
                case "ac:task-status":
                    out.current += doc.text(doc.children(i)) == "complete" ? "[x] " : "[ ] "
                    i = (tok.close ?? i) + 1; continue
                case "ac:task-id": i = (tok.close ?? i) + 1; continue
                case "ac:structured-macro", "ac:macro":
                    if tok.kind == .start { macros.append(doc.attribute(i, "ac:name") ?? "") }
                case "ac:parameter":
                    if macros.last == "jira", doc.attribute(i, "ac:name") == "key" { out.current += " [\(doc.text(doc.children(i)))] " }
                    i = (tok.close ?? i) + 1; continue
                case "ac:image":
                    let file = doc.child(i, "ri:attachment").flatMap { doc.attribute($0, "ri:filename") }
                    out.current += "[图片\(file.map { " " + $0 } ?? "")]"
                    i = (tok.close ?? i) + 1; continue
                case "ri:page": out.current += doc.attribute(i, "ri:content-title") ?? ""
                case "ri:user": out.current += "@用户"
                default: break
                }
            case .end:
                if name == "ac:structured-macro" || name == "ac:macro" { _ = macros.popLast() }
                if name == "td" || name == "th" { cells = max(0, cells - 1) }
                if blockTags.contains(name) { out.newlineOrSpace(cells > 0) }
            case .text: out.current += WikiStorage.decodeEntities(tag)
            case .other:
                if tag.hasPrefix("<![CDATA["), tag.hasSuffix("]]>") {
                    out.newlineOrSpace(cells > 0)
                    for line in tag.dropFirst(9).dropLast(3).split(separator: "\n", omittingEmptySubsequences: false) {
                        out.current += line
                        out.newlineOrSpace(cells > 0)
                    }
                }
            }
            i += 1
        }
        out.newlineOrSpace(false)
        return out.lines
    }

    public static func jiraKeys(storage: String, text: String) -> [String] {
        var keys: [String] = []
        if let doc = try? StorageDocument(storage) {
            var inJira = false
            for (i, tok) in doc.tokens.enumerated() {
                if tok.name == "ac:structured-macro" {
                    if tok.kind == .start { inJira = doc.attribute(i, "ac:name") == "jira" }
                    if tok.kind == .end { inJira = false }
                }
                if inJira, tok.kind == .start, tok.name == "ac:parameter", doc.attribute(i, "ac:name") == "key" {
                    let key = doc.text(doc.children(i))
                    if !key.isEmpty && !keys.contains(key) { keys.append(key) }
                }
            }
        }
        var rest = text[...]
        while let match = rest.firstMatch(of: /(?:^|[^A-Za-z0-9_\-])([A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,6})(?:$|[^A-Za-z0-9_])/) {
            let key = String(match.1)
            if !keys.contains(key) { keys.append(key) }
            rest = rest[match.1.endIndex...]
        }
        return keys
    }

    public static func inlineTasks(_ storage: String) -> [InlineTask] {
        guard let doc = try? StorageDocument(storage) else { return [] }
        var tasks: [InlineTask] = []
        for (i, tok) in doc.tokens.enumerated() where tok.kind == .start && tok.name == "ac:task" {
            var task = InlineTask(), body: Int?
            for j in doc.children(i) {
                let t = doc.tokens[j]
                switch (t.kind, t.name) {
                case (.start, "ac:task-id"): task.taskId = doc.text(doc.children(j))
                case (.start, "ac:task-status"): task.done = doc.text(doc.children(j)) == "complete"
                case (.start, "ac:task-body"): body = j
                case (.start, "ri:user"), (.empty, "ri:user"):
                    if let key = doc.attribute(j, "ri:userkey") ?? doc.attribute(j, "ri:username"), !task.assignees.contains(key) { task.assignees.append(key) }
                case (.start, "time"), (.empty, "time"):
                    if task.due == nil { task.due = doc.attribute(j, "datetime") }
                default: break
                }
            }
            if let body { task.text = readableLines(doc.string(doc.inner(body))).joined(separator: " ") }
            if !task.taskId.isEmpty { tasks.append(task) }
        }
        return tasks
    }

    private struct Lines {
        var lines: [String] = []
        var current = ""
        mutating func newlineOrSpace(_ space: Bool) {
            if space { current += " "; return }
            var line = WikiStorage.collapseWhitespace(current)
            if line.hasPrefix("| ") { line = String(line.dropFirst(2)) }
            if !line.isEmpty && line != "-" && line != "|" { lines.append(line) }
            current = ""
        }
    }
}
