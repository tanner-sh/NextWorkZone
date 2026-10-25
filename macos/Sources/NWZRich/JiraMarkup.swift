import Foundation

public enum JiraMarkup {
    private static let open: Character = "\u{e000}", close: Character = "\u{e001}"
    public static func write(_ doc: RichDoc) -> String {
        let text = resolveMarks(blocks(doc.blocks, table: false).joined(separator: "\n\n"))
        var output = "", newlines = 0
        for character in text {
            if character == "\n" { newlines += 1; if newlines <= 2 { output.append(character) } }
            else { newlines = 0; output.append(character) }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func blocks(_ content: [RichBlock], table: Bool) -> [String] {
        content.map { block($0, table: table) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private static func block(_ value: RichBlock, table: Bool) -> String {
        switch value {
        case .para(let content): return escapeLineStarts(inline(content, table: table))
        case .heading(let level, let content, _): return "h\(min(6, max(1, level))). " + inline(content, table: table).trimmingCharacters(in: .whitespacesAndNewlines)
        case .list(let ordered, _, let items): return list(ordered, items: items, prefix: "", table: table)
        case .quote(let content):
            let text = blocks(content, table: table).joined(separator: "\n\n")
            return text.contains("\n") ? "{quote}\n" + text + "\n{quote}" : "bq. " + text
        case .code(let language, let text): return language.isEmpty ? "{noformat}\n" + text + "\n{noformat}" : "{code:" + language + "}\n" + text + "\n{code}"
        case .table(let rows): return rows.compactMap { row -> String? in
            var line = "", last = "|"
            for cell in row.cells {
                let separator = cell.head ? "||" : "|"
                let content = blocks(cell.blocks, table: true).joined(separator: "\n").split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                line += separator + (content.isEmpty ? " " : content); last = separator
            }
            return line.isEmpty ? nil : line + last
        }.joined(separator: "\n")
        case .rule: return "----"
        case .panel(let kind, let title, let content):
            let name = ["info", "note", "warning", "tip"].contains(kind) ? kind : "panel"
            return "{" + name + (title.isEmpty ? "" : ":title=" + title) + "}\n" + blocks(content, table: table).joined(separator: "\n\n") + "\n{" + name + "}"
        case .opaque(let value): return value.label
        case .marker: return ""
        }
    }
    private static func list(_ ordered: Bool, items: [RichItem], prefix: String, table: Bool) -> String {
        let marker = prefix + (ordered ? "#" : "*")
        return items.flatMap { item -> [String] in
            var nested: [RichBlock] = [], rest: [RichBlock] = []
            for block in item.blocks { if case .list = block { nested.append(block) } else { rest.append(block) } }
            let text = blocks(rest, table: table).joined(separator: " ").split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
            let task = item.task.map { $0.done ? "(/) " : "(x) " } ?? ""
            var output = [marker + " " + task + text]
            for block in nested { if case .list(let ordered, _, let items) = block { output.append(list(ordered, items: items, prefix: marker, table: table)) } }
            return output
        }.joined(separator: "\n")
    }
    private static func inline(_ content: [RichInline], table: Bool) -> String {
        content.map { item in
            switch item {
            case .text(let value, let marks, let link, let color):
                var text = marks.contains(.code) ? wrap("{{", value.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")) : escape(value, table: table)
                if !marks.contains(.code) {
                    for (mark, delimiter): (Marks, String) in [(.sub, "~"), (.sup, "^"), (.strike, "-"), (.underline, "+"), (.italic, "_"), (.bold, "*")] where marks.contains(mark) { text = wrap(delimiter, text) }
                }
                if let color, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "{color:" + color + "}" + text + "{color}" }
                if let link, !link.hasPrefix("#") {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == link || (trimmed.removingPercentEncoding ?? trimmed) == (link.removingPercentEncoding ?? link) { return "[" + link + "]" }
                    let label = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "]", with: "\\]")
                    return "[" + label + "|" + link + "]"
                }
                return text
            case .br: return "\n"
            case .image(let image):
                let parameters = image.thumb == true ? ["thumbnail"] : [image.width.map { "width=\($0)" }, image.height.map { "height=\($0)" }].compactMap { $0 }
                let suffix = parameters.isEmpty ? "" : "|" + parameters.joined(separator: ",")
                if let file = image.file { return "!" + file + suffix + "!" }
                if let emoticon = emoticon(image.src) { return emoticon }
                if image.src.hasPrefix("https://") || image.src.hasPrefix("http://") { return "!" + image.src + suffix + "!" }
                return ""
            case .issue(let key): return key
            case .status(let text, _): return escape(text, table: table)
            case .mention(let name, let user): return user.isEmpty ? escape("@" + name, table: table) : "[~" + user + "]"
            case .attachment(let file): return "[^" + file + "]"
            case .opaque(let opaque): return opaque.label
            case .marker: return ""
            }
        }.joined()
    }
    private static func emoticon(_ source: String) -> String? {
        guard let range = source.range(of: "/images/icons/emoticons/"), let name = source[range.upperBound...].split(separator: ".").first else { return nil }
        let values = ["smile": ":)", "sad": ":(", "tongue": ":P", "biggrin": ":D", "wink": ";)", "thumbs_up": "(y)", "thumbs_down": "(n)", "information": "(i)", "check": "(/)", "error": "(x)", "warning": "(!)", "add": "(+)", "forbidden": "(-)", "help_16": "(?)", "lightbulb_on": "(on)", "lightbulb": "(off)", "star_yellow": "(*)", "star_red": "(*r)", "star_green": "(*g)", "star_blue": "(*b)", "flag": "(flag)", "flag_grey": "(flagoff)"]
        return values[String(name)]
    }
    private static func wrap(_ mark: String, _ text: String) -> String {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return text }
        let leading = text.prefix(while: \.isWhitespace), trailing = String(text.reversed().prefix(while: \.isWhitespace).reversed())
        return leading + String(open) + mark + String(open) + core + String(close) + mark + String(close) + trailing
    }
    private static func resolveMarks(_ text: String) -> String {
        var chars = Array(text)
        func matches(_ token: [Character], _ position: Int) -> Bool { position + token.count <= chars.count && chars[position..<(position + token.count)].elementsEqual(token) }
        func visible(_ values: [Character]) -> Character? {
            var inside = false
            for value in values {
                if value == open || value == close { inside.toggle() }
                else if !inside { return value }
            }
            return nil
        }
        while let start = chars.firstIndex(of: open) {
            guard let end = chars[(start + 1)...].firstIndex(of: open) else { break }
            let mark = String(chars[(start + 1)..<end]), openToken = Array(chars[start...end]), closeToken = Array(String(close) + String(chars[(start + 1)..<end]) + String(close))
            var depth = 0, closing: Int?, index = end + 1
            while index < chars.count {
                if matches(openToken, index) { depth += 1 }
                else if matches(closeToken, index) { if depth == 0 { closing = index; break }; depth -= 1 }
                index += 1
            }
            guard let closing else { chars.removeSubrange(start...end); continue }
            let before = visible(Array(chars[..<start].reversed())), after = visible(Array(chars[(closing + closeToken.count)...]))
            let braces = before.map { $0.isLetter || $0.isNumber } == true || after.map { $0.isLetter || $0.isNumber } == true
            let right = mark == "{{" ? "}}" : mark
            chars.replaceSubrange(closing..<(closing + closeToken.count), with: Array(braces ? "{" + right + "}" : right))
            chars.replaceSubrange(start...end, with: Array(braces ? "{" + mark + "}" : mark))
        }
        return String(chars.filter { $0 != open && $0 != close })
    }
    private static func escape(_ text: String, table: Bool) -> String {
        let chars = Array(text)
        return chars.enumerated().map { index, character in
            let previousSpace = index == 0 || chars[index - 1].isWhitespace, nextSpace = index + 1 == chars.count || chars[index + 1].isWhitespace
            let escaped = "\\{}[]".contains(character) || character == "|" && table || character == "!" && !nextSpace || "*_+-^~?".contains(character) && previousSpace != nextSpace
            return (escaped ? "\\" : "") + String(character)
        }.joined()
    }
    private static func escapeLineStarts(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let marks = line.prefix { "*#-".contains($0) }
            let list = !marks.isEmpty && Set(marks).count == 1 && line.dropFirst(marks.count).first?.isWhitespace == true
            let heading = line.firstMatch(of: /^(?:h[1-6]|bq)\.[ ]/) != nil
            return list || heading || line.hasPrefix("----") ? "\\" + line : line
        }.joined(separator: "\n")
    }
}
