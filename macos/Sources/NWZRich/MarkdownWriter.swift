import Foundation

extension Markdown {
    public static func write(_ document: RichDoc) -> String { writeBlocks(document.blocks) }

    private static func writeBlocks(_ blocks: [RichBlock], indent: String = "") -> String {
        blocks.filter { if case .marker = $0 { return false }; return true }.map { writeBlock($0, indent: indent) }.joined(separator: "\n")
    }

    private static func prefixed(_ text: String, first: String, rest: String? = nil) -> String {
        text.components(separatedBy: "\n").enumerated().map { index, line in
            let prefix = index == 0 ? first : rest ?? first
            return (line.isEmpty ? prefix.trimmingCharacters(in: .whitespaces) : prefix + line) + "\n"
        }.joined()
    }

    private static func writeBlock(_ block: RichBlock, indent: String) -> String {
        switch block {
        case .para(let content): return prefixed(escapeLineStart(writeInlines(content)), first: indent)
        case .heading(let level, let content, _): return prefixed(String(repeating: "#", count: min(6, max(1, level))) + " " + writeInlines(content), first: indent)
        case .rule: return indent + "---\n"
        case .code(let language, let text):
            var fence = "```"
            while text.contains(fence) { fence += "`" }
            return indent + fence + language + "\n" + prefixed(text, first: indent) + indent + fence + "\n"
        case .quote(let blocks): return writeBlocks(blocks, indent: indent + "> ")
        case .panel(_, let title, let blocks):
            return (title.isEmpty ? "" : indent + "> **" + escape(title) + "**\n>\n") + writeBlocks(blocks, indent: indent + "> ")
        case .list(let ordered, let start, let items):
            return items.enumerated().map { index, item in
                let marker = ordered ? "\(max(start, 1) + index). " : "- "
                let task = item.task.map { $0.done ? "[x] " : "[ ] " } ?? ""
                let childIndent = indent + String(repeating: " ", count: marker.count)
                var blocks = item.blocks[...], output = ""
                if case .para(let content) = blocks.first {
                    output = prefixed(escapeLineStart(writeInlines(content)), first: indent + marker + task, rest: childIndent)
                    blocks = blocks.dropFirst()
                } else { output = indent + (marker + task).trimmingCharacters(in: .whitespaces) + "\n" }
                for block in blocks {
                    if case .list = block {} else { output += "\n" }
                    output += writeBlock(block, indent: childIndent)
                }
                return output
            }.joined()
        case .table(let rows):
            let width = rows.map { $0.cells.reduce(0) { $0 + max(1, $1.colspan) } }.max() ?? 0
            guard width > 0 else { return "" }
            var output = ""
            for (index, row) in rows.enumerated() {
                var cells: [String] = []
                for cell in row.cells {
                    let value = writeBlocks(cell.blocks).trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\\\n", with: "<br>")
                        .replacingOccurrences(of: "\n\n", with: "<br>")
                        .replacingOccurrences(of: "\n", with: "<br>")
                        .replacingOccurrences(of: "|", with: "\\|")
                    cells.append(value)
                    cells += Array(repeating: "", count: max(0, cell.colspan - 1))
                }
                cells += Array(repeating: "", count: max(0, width - cells.count))
                output += indent + "| " + cells.joined(separator: " | ") + " |\n"
                if index == 0 { output += indent + "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |\n" }
            }
            return output
        case .opaque(let opaque): return prefixed(escape(opaque.label), first: indent)
        case .marker: return ""
        }
    }

    private static func escapeLineStart(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            if let match = line.firstMatch(of: /^(\s*)([0-9]+)([.)])[ ]/) {
                return String(match.1) + String(match.2) + "\\" + String(match.3) + " " + line[match.range.upperBound...]
            }
            if let match = line.firstMatch(of: /^(\s*)(#+[ ]|[>+\-][ ])/) {
                return String(match.1) + "\\" + line[match.2.startIndex...]
            }
            return line
        }.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.map { "\\*_`[]<~".contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    private static func target(_ text: String) -> String {
        if text.contains(where: { " ()<>".contains($0) }) { return "<" + text.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">" }
        return text
    }

    private static func code(_ text: String) -> String {
        var delimiter = "`"
        while text.contains(delimiter) { delimiter += "`" }
        let pad = text.hasPrefix("`") || text.hasSuffix("`") || text.hasPrefix(" ") && text.hasSuffix(" ") && !text.allSatisfy(\.isWhitespace) ? " " : ""
        return delimiter + pad + text + pad + delimiter
    }

    static func writeInlines(_ content: [RichInline]) -> String {
        content.map { item in
            switch item {
            case .text(let value, let marks, let link, _):
                var text = escape(value)
                if marks.contains(.code) { text = code(value) }
                else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let leading = String(text.prefix(while: \.isWhitespace)), trailing = String(text.reversed().prefix(while: \.isWhitespace).reversed())
                    var core = String(text.dropFirst(leading.count).dropLast(trailing.count))
                    for (mark, prefix, suffix): (Marks, String, String) in [(.strike, "~~", "~~"), (.italic, "*", "*"), (.bold, "**", "**"), (.underline, "<u>", "</u>"), (.sup, "<sup>", "</sup>"), (.sub, "<sub>", "</sub>"), (.mark, "<mark>", "</mark>")] {
                        if marks.contains(mark) { core = prefix + core + suffix }
                    }
                    text = leading + core + trailing
                }
                return link.map { "[" + text + "](" + target($0) + ")" } ?? text
            case .image(let image): return "![" + escape(image.alt ?? "") + "](" + target(image.src) + ")"
            case .br: return "\\\n"
            case .issue(let key): return key
            case .status(let text, _): return code(text)
            case .mention(let name, _): return "@" + escape(name)
            case .attachment(let file): return escape(file)
            case .opaque(let opaque): return escape(opaque.label.replacingOccurrences(of: "\n", with: " "))
            case .marker: return ""
            }
        }.joined()
    }
}
