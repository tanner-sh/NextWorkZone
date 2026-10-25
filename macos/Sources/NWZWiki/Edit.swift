import Foundation
import NWZCore
import NWZRich

public struct Editable: Codable, Hashable, Sendable {
    public var html: String
    public var fragments: [String]
    public var users: [String]
    public init(html: String = "", fragments: [String] = [], users: [String] = []) { self.html = html; self.fragments = fragments; self.users = users }
}

/// 只有普通文字结构交给编辑器。带命名空间的元素保存原文，避免编辑器改变宏和链接的语义。
public enum WikiEdit {
    private static let voids: Set<String> = ["br", "hr", "img", "col", "wbr", "area", "input", "source"]
    private static let containers: Set<String> = ["ac:layout", "ac:layout-section", "ac:layout-cell", "ac:inline-comment-marker"]
    private static let inlineMacros: Set<String> = ["jira", "status", "anchor", "emoticon", "mention", "profile-picture", "lozenge", "highlight"]
    private static let inlineElements: Set<String> = ["ac:link", "ac:image", "ac:emoticon", "ac:placeholder", "ri:user", "ri:page", "ri:attachment", "at:var", "time"]

    public static func toEditable(_ storage: String) throws -> Editable {
        let doc = try StorageDocument(storage)
        var editable = Editable()
        emit(doc, doc.tokens.indices, &editable)
        return editable
    }

    private static func fragment(_ source: String, _ ed: inout Editable) -> Int {
        let n = ed.fragments.count
        ed.fragments.append(source)
        return n
    }

    private static func emit(_ doc: StorageDocument, _ range: Range<Int>, _ ed: inout Editable) {
        var i = range.lowerBound
        while i < range.upperBound {
            let tok = doc.tokens[i], src = doc.tag(i), name = tok.name
            switch tok.kind {
            case .text: ed.html += src
            case .other:
                if src.hasPrefix("<![CDATA["), src.hasSuffix("]]>") { ed.html += WikiStorage.escapeText(String(src.dropFirst(9).dropLast(3))) }
                else { ed.html += src }
            case .end: break
            case .start, .empty:
                let selfClosing = tok.kind == .empty && !voids.contains(name)
                if !name.contains(":"), !selfClosing {
                    ed.html += src
                    if tok.kind == .start {
                        emit(doc, doc.children(i), &ed)
                        if let close = tok.close { ed.html += doc.tag(close) }
                        i = tok.close ?? i
                    }
                } else if containers.contains(name), tok.kind == .start, let close = tok.close {
                    let openN = fragment(src, &ed), closeN = fragment(doc.tag(close), &ed)
                    let tag = name == "ac:inline-comment-marker" ? "span" : "div"
                    ed.html += "<\(tag) class=\"nwz-container\" data-nwz-open=\"\(openN)\" data-nwz-close=\"\(closeN)\">"
                    emit(doc, doc.children(i), &ed)
                    ed.html += "</\(tag)>"
                    i = close
                } else {
                    let n = fragment(doc.string(doc.outer(i)), &ed)
                    let (inline, label) = describe(doc, i, &ed)
                    let cls = inline ? "nwz-opaque" : "nwz-opaque nwz-block"
                    ed.html += "<span class=\"\(cls)\" contenteditable=\"false\" data-nwz=\"\(n)\">\(label)</span>"
                    i = tok.close ?? i
                }
            }
            i += 1
        }
    }

    private static func describe(_ doc: StorageDocument, _ i: Int, _ ed: inout Editable) -> (Bool, String) {
        let name = doc.tokens[i].name
        func text(_ s: String) -> String { WikiStorage.escapeText(s) }
        func attr(_ s: String) -> String { XHTML.escape(s) }
        switch name {
        case "ac:structured-macro", "ac:macro":
            let macro = doc.attribute(i, "ac:name") ?? ""
            let inline = inlineMacros.contains(macro)
            let label: String
            switch macro {
            case "jira":
                label = doc.parameter(i, "key").map { "<span class=\"nwz-jira\" data-jira-key=\"\(attr($0))\">\(text($0))</span>" } ?? "Jira 问题列表"
            case "status": label = "<span class=\"nwz-status\">\(text(doc.parameter(i, "title") ?? ""))</span>"
            case "anchor": label = "⚓"
            case "code", "noformat":
                let body = doc.child(i, "ac:plain-text-body").map { b in
                    doc.children(b).map { doc.tag($0) }.filter { $0.hasPrefix("<![CDATA[") && $0.hasSuffix("]]>") }.map { String($0.dropFirst(9).dropLast(3)) }.joined()
                } ?? ""
                let title = doc.parameter(i, "title").map { "<span class=\"nwz-macro-title\">\(text($0))</span>" } ?? ""
                label = title + "<span class=\"nwz-code\">\(text(body))</span>"
            default:
                let title = doc.parameter(i, "title").map { "：" + text($0) } ?? ""
                let body = doc.child(i, "ac:rich-text-body").map { WikiText.readableLines(doc.string(doc.inner($0))) } ?? []
                label = "<span class=\"nwz-macro-title\">\(text(macroLabel(macro)))\(title)</span>" + body.prefix(12).map { "<span class=\"nwz-line\">\(text($0))</span>" }.joined() + (body.count > 12 ? "<span class=\"nwz-line\">…</span>" : "")
            }
            return (inline, label)
        case "ac:task-list":
            var html = ""
            for task in WikiText.inlineTasks(doc.string(doc.outer(i))) {
                for key in task.assignees where !ed.users.contains(key) { ed.users.append(key) }
                html += "<span class=\"nwz-line\">\(task.done ? "☑" : "☐") \(text(task.text))</span>"
            }
            return (false, html)
        case "ac:image":
            if let a = doc.child(i, "ri:attachment") {
                let file = attr(doc.attribute(a, "ri:filename") ?? "")
                return (true, "<img data-nwz-attachment=\"\(file)\" alt=\"\(file)\">")
            }
            if let u = doc.child(i, "ri:url") { return (true, "<img data-nwz-url=\"\(attr(doc.attribute(u, "ri:value") ?? ""))\" alt=\"\">") }
            return (true, "[图片]")
        case "ac:link":
            if let u = doc.child(i, "ri:user") {
                let key = doc.attribute(u, "ri:userkey") ?? doc.attribute(u, "ri:username") ?? ""
                if !ed.users.contains(key) { ed.users.append(key) }
                return (true, "<span class=\"nwz-user\" data-nwz-user=\"\(attr(key))\">@用户</span>")
            }
            let body = (doc.child(i, "ac:plain-text-link-body") ?? doc.child(i, "ac:link-body")).map { doc.text(doc.children($0)).replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "") }
            let target = doc.child(i, "ri:page").flatMap { doc.attribute($0, "ri:content-title") } ?? doc.child(i, "ri:attachment").flatMap { doc.attribute($0, "ri:filename") } ?? doc.attribute(i, "ac:anchor") ?? "链接"
            return (true, "<span class=\"nwz-link\">\(text(body.flatMap { $0.isEmpty ? nil : $0 } ?? target))</span>")
        case "ac:emoticon": return (true, emoticon(doc.attribute(i, "ac:name") ?? ""))
        case "time": return (true, "<span class=\"nwz-date\">\(text(doc.attribute(i, "datetime") ?? ""))</span>")
        case "ac:placeholder": return (true, "<span class=\"nwz-placeholder\">\(text(doc.text(doc.children(i))))</span>")
        default:
            let label = WikiText.readableLines(doc.string(doc.outer(i))).joined(separator: " ")
            return (inlineElements.contains(name), label.isEmpty ? "[\(text(name))]" : text(label))
        }
    }

    private static func macroLabel(_ name: String) -> String {
        ["info": "信息", "note": "注意", "tip": "提示", "warning": "警告", "panel": "面板", "expand": "展开块", "toc": "目录", "children": "子页面列表", "include": "引用其他页面", "excerpt-include": "引用其他页面", "excerpt": "摘要", "section": "分栏", "column": "分栏", "attachments": "附件列表"][name] ?? "宏 \(name)"
    }
    public static func emoticon(_ name: String) -> String {
        ["smile": "🙂", "sad": "🙁", "cheeky": "😛", "laugh": "😄", "wink": "😉", "thumbs-up": "👍", "thumbs-down": "👎", "information": "ℹ️", "tick": "✅", "cross": "❌", "warning": "⚠️", "plus": "➕", "minus": "➖", "question": "❓", "light-on": "💡", "light-off": "💡", "yellow-star": "⭐", "red-star": "⭐", "green-star": "⭐", "blue-star": "⭐", "heart": "❤️", "broken-heart": "💔"][name] ?? "🙂"
    }

    public static func fromEditable(_ xhtml: String, fragments: [String]) throws -> String {
        var storage = "", start = xhtml.startIndex
        for m in xhtml.matches(of: /<!--nwz:(\d+)-->/) {
            guard let n = Int(m.1), fragments.indices.contains(n) else { throw NWZError.other("编辑内容中有无法识别的占位块（\(m.1)）") }
            storage += xhtml[start..<m.range.lowerBound] + fragments[n]
            start = m.range.upperBound
        }
        storage += xhtml[start...]
        try WikiStorage.validate(storage)
        return storage
    }

    public static func stripTemplateVariables(_ storage: String) -> String {
        storage.replacing(/(?s)<at:declarations\s*\/>|<at:declarations>.*?<\/at:declarations>/, with: "")
            .replacing(/(?s)<at:var\b[^>]*\/>|<at:var\b[^>]*>.*?<\/at:var>/, with: "")
    }
    public static func plainToStorage(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<p>&nbsp;</p>" : "<p>\(WikiStorage.escapeText($0))</p>"
        }.joined()
    }
}
