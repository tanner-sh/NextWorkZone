import Foundation

/// 工作空间使用的 Markdown 语法；解析直接生成文档树，不经过 HTML 中间表示。
public enum Markdown {
    public static func parse(_ text: String) -> RichDoc {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var parser = BlockParser(lines: lines)
        return RichDoc(blocks: parser.parse())
    }
    public static func inlines(_ text: String) -> [RichInline] { InlineParser.parse(text) }

    private struct Marker {
        var ordered: Bool
        var start: Int
        var indentation: Int
        var width: Int
        var body: String
        var bullet: String
    }
    private static func marker(_ line: String) -> Marker? {
        if let match = line.firstMatch(of: /^( *)([-+*])(?:[ \t]+(.*)|$)/) {
            let width = line.count - String(match.3 ?? "").count
            return Marker(ordered: false, start: 0, indentation: match.1.count, width: max(width, match.1.count + 2), body: String(match.3 ?? ""), bullet: String(match.2))
        }
        if let match = line.firstMatch(of: /^( *)([0-9]{1,9})([.)])(?:[ \t]+(.*)|$)/) {
            let number = Int(match.2) ?? 1
            return Marker(ordered: true, start: number == 1 ? 0 : number, indentation: match.1.count, width: max(line.count - String(match.4 ?? "").count, match.1.count + match.2.count + 2), body: String(match.4 ?? ""), bullet: String(match.3))
        }
        return nil
    }
    private static func fence(_ line: String) -> (Character, Int, String)? {
        let trimmed = String(line.drop(while: { $0 == " " }).prefix(line.count))
        guard line.prefix(while: { $0 == " " }).count < 4, let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let rest = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        if first == "`" && rest.contains("`") { return nil }
        return (first, count, rest)
    }
    private static func rule(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " }).count < 4 else { return false }
        let compact = line.filter { $0 != " " && $0 != "\t" }
        return compact.count >= 3 && ["*", "-", "_"].contains(String(compact.first!)) && compact.allSatisfy { $0 == compact.first }
    }
    private static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [], current = "", escaped = false
        for c in text {
            if escaped { current.append(c); escaped = false }
            else if c == "\\" { current.append(c); escaped = true }
            else if c == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(c) }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
    private static func tableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { $0.wholeMatch(of: /:?-{3,}:?/) != nil }
    }

    private struct BlockParser {
        var lines: [String]
        var index = 0
        func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
        func startsBlock(_ line: String) -> Bool {
            rule(line) || fence(line) != nil || line.firstMatch(of: /^ {0,3}#{1,6}(?:[ \t]|$)/) != nil || line.firstMatch(of: /^ {0,3}>/) != nil || marker(line) != nil
        }
        mutating func parse() -> [RichBlock] {
            var blocks: [RichBlock] = []
            while index < lines.count {
                let line = lines[index]
                if blank(line) { index += 1; continue }
                if let (character, length, info) = fence(line) {
                    index += 1
                    var body: [String] = []
                    while index < lines.count {
                        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                        if candidate.count >= length && candidate.allSatisfy({ $0 == character }) { index += 1; break }
                        body.append(lines[index]); index += 1
                    }
                    while body.last == "" { body.removeLast() }
                    blocks.append(.code(lang: String(info.split(whereSeparator: \.isWhitespace).first ?? ""), text: body.joined(separator: "\n")))
                } else if let match = line.firstMatch(of: /^ {0,3}(#{1,6})(?:[ \t]+(.*?)|$)(?:[ \t]+#+[ \t]*)?$/) {
                    blocks.append(.heading(level: match.1.count, inlines(String(match.2 ?? "")), id: nil)); index += 1
                } else if rule(line) { blocks.append(.rule); index += 1 }
                else if line.firstMatch(of: /^ {0,3}>/) != nil {
                    var nested: [String] = []
                    while index < lines.count {
                        if let match = lines[index].firstMatch(of: /^ {0,3}> ?(.*)$/) { nested.append(String(match.1)); index += 1 }
                        else if !blank(lines[index]) && !startsBlock(lines[index]) && nested.last?.isEmpty == false { nested.append(lines[index]); index += 1 }
                        else { break }
                    }
                    var child = BlockParser(lines: nested)
                    blocks.append(.quote(child.parse()))
                } else if let first = marker(line), first.indentation < 4 {
                    var items: [RichItem] = []
                    while index < lines.count, let mark = marker(lines[index]), mark.ordered == first.ordered, mark.indentation == first.indentation, mark.bullet == first.bullet {
                        var body = [mark.body]
                        index += 1
                        while index < lines.count {
                            if let next = marker(lines[index]), next.indentation == first.indentation { break }
                            if blank(lines[index]) {
                                var next = index + 1
                                while next < lines.count && blank(lines[next]) { next += 1 }
                                if next == lines.count { index = next; break }
                                if let nextMarker = marker(lines[next]), nextMarker.indentation == first.indentation { index = next; break }
                                if lines[next].prefix(while: { $0 == " " }).count < mark.width { break }
                                body.append(""); index += 1; continue
                            }
                            let indent = lines[index].prefix(while: { $0 == " " }).count
                            if indent >= mark.width { body.append(String(lines[index].dropFirst(mark.width))); index += 1 }
                            else if !startsBlock(lines[index]) { body.append(lines[index]); index += 1 }
                            else { break }
                        }
                        var task: RichTask?
                        if let match = body[0].firstMatch(of: /^\[([ xX])\](?:[ \t]+(.*)|$)/) {
                            task = RichTask(done: match.1 != " ")
                            body[0] = String(match.2 ?? "")
                        }
                        var child = BlockParser(lines: body)
                        var children = child.parse()
                        if children.isEmpty { children = [.para([])] }
                        items.append(.init(task: task, blocks: children))
                    }
                    blocks.append(.list(ordered: first.ordered, start: first.start, items: items))
                } else if index + 1 < lines.count, line.contains("|"), tableSeparator(lines[index + 1]) {
                    let headers = tableCells(line)
                    var rows = [RichRow(cells: headers.map { .init(head: true, blocks: [.para(inlines($0))]) })]
                    index += 2
                    while index < lines.count && !blank(lines[index]) && lines[index].contains("|") {
                        var cells = tableCells(lines[index]); cells = Array(cells.prefix(headers.count))
                        while cells.count < headers.count { cells.append("") }
                        rows.append(.init(cells: cells.map { .init(blocks: [.para(inlines($0))]) })); index += 1
                    }
                    blocks.append(.table(rows))
                } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                    var body: [String] = []
                    while index < lines.count {
                        if lines[index].hasPrefix("    ") { body.append(String(lines[index].dropFirst(4))) }
                        else if lines[index].hasPrefix("\t") { body.append(String(lines[index].dropFirst())) }
                        else if blank(lines[index]) { body.append("") }
                        else { break }
                        index += 1
                    }
                    while body.last == "" { body.removeLast() }
                    blocks.append(.code(lang: "", text: body.joined(separator: "\n")))
                } else {
                    var paragraph = [line]; index += 1
                    if index < lines.count, let match = lines[index].firstMatch(of: /^ {0,3}(=+|-+)[ \t]*$/) {
                        blocks.append(.heading(level: match.1.first == "=" ? 1 : 2, inlines(line), id: nil)); index += 1; continue
                    }
                    while index < lines.count && !blank(lines[index]) && !startsBlock(lines[index]) {
                        if index + 1 < lines.count && tableSeparator(lines[index + 1]) { break }
                        paragraph.append(lines[index]); index += 1
                    }
                    blocks.append(.para(inlines(paragraph.joined(separator: "\n"))))
                }
            }
            return blocks
        }
    }
}
