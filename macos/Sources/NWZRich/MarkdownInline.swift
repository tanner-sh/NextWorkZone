import Foundation

internal enum InlineParser {
    static func parse(_ source: String, marks: Marks = [], link: String? = nil, depth: Int = 0) -> [RichInline] {
        guard depth < 128 else { return [.text(source, marks, link: link, color: nil)] }
        let chars = Array(source)
        var index = 0, buffer = "", result: [RichInline] = []
        func append(_ item: RichInline) {
            if case .text(let text, let style, let href, let color) = item, let last = result.last,
               case .text(let previous, let previousStyle, let previousLink, let previousColor) = last,
               style == previousStyle, href == previousLink, color == previousColor {
                result[result.count - 1] = .text(previous + text, style, link: href, color: color)
            } else { result.append(item) }
        }
        func flush() { if !buffer.isEmpty { append(.text(buffer, marks, link: link, color: nil)); buffer = "" } }
        func matches(_ text: String, at start: Int) -> Bool {
            let pattern = Array(text)
            return start + pattern.count <= chars.count && chars[start..<(start + pattern.count)].elementsEqual(pattern)
        }
        func run(at start: Int) -> Int {
            var end = start
            while end < chars.count && chars[end] == chars[start] { end += 1 }
            return end - start
        }
        func closing(_ delimiter: String, from start: Int, exact: Bool = false) -> Int? {
            var position = start
            while position < chars.count {
                if chars[position] == "\\" && delimiter.first != "`" { position += 2; continue }
                if matches(delimiter, at: position), (!exact || run(at: position) == delimiter.count), position > start, !chars[position - 1].isWhitespace || delimiter.first == "`" { return position }
                position += 1
            }
            return nil
        }
        func bracketEnd(from start: Int) -> Int? {
            var nesting = 1, position = start
            while position < chars.count {
                if chars[position] == "\\" { position += 2; continue }
                if chars[position] == "[" { nesting += 1 }
                if chars[position] == "]" { nesting -= 1; if nesting == 0 { return position } }
                position += 1
            }
            return nil
        }
        func destination(from start: Int) -> (String, Int)? {
            var position = start, nesting = 0, address = ""
            while position < chars.count && chars[position].isWhitespace { position += 1 }
            if position < chars.count && chars[position] == "<" {
                position += 1
                while position < chars.count && chars[position] != ">" { address.append(chars[position]); position += 1 }
                guard position < chars.count else { return nil }
                position += 1
            } else {
                while position < chars.count {
                    let c = chars[position]
                    if c == "\\" && position + 1 < chars.count { address.append(chars[position + 1]); position += 2; continue }
                    if c == "(" { nesting += 1 }
                    if c == ")" { if nesting == 0 { break }; nesting -= 1 }
                    if c.isWhitespace && nesting == 0 { break }
                    address.append(c); position += 1
                }
            }
            while position < chars.count && chars[position].isWhitespace { position += 1 }
            if position < chars.count && (chars[position] == "\"" || chars[position] == "'") {
                let quote = chars[position]; position += 1
                while position < chars.count && chars[position] != quote { position += 1 }
                guard position < chars.count else { return nil }; position += 1
                while position < chars.count && chars[position].isWhitespace { position += 1 }
            }
            guard position < chars.count && chars[position] == ")" else { return nil }
            return (decodeEntities(address), position + 1)
        }
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                if chars[index + 1] == "\n" { flush(); append(.br); index += 2; continue }
                if chars[index + 1].isASCII && chars[index + 1].isPunctuation || chars[index + 1] == "|" {
                    buffer.append(chars[index + 1]); index += 2; continue
                }
            }
            if character == "\n" {
                if buffer.hasSuffix("  ") { while buffer.last == " " { buffer.removeLast() }; flush(); append(.br) }
                else { buffer.append(" ") }
                index += 1
                while index < chars.count && (chars[index] == " " || chars[index] == "\t") { index += 1 }
                continue
            }
            if character == "`" {
                let count = run(at: index), delimiter = String(repeating: "`", count: run(at: index))
                if let end = closing(delimiter, from: index + count, exact: true) {
                    var text = String(chars[(index + count)..<end]).replacingOccurrences(of: "\n", with: " ")
                    if text.hasPrefix(" ") && text.hasSuffix(" ") && !text.allSatisfy(\.isWhitespace) { text.removeFirst(); text.removeLast() }
                    flush(); append(.text(text, marks.union(.code), link: link, color: nil)); index = end + count; continue
                }
                buffer += delimiter; index += count; continue
            }
            let image = character == "!" && index + 1 < chars.count && chars[index + 1] == "["
            if character == "[" || image {
                let start = index + (image ? 2 : 1)
                if let end = bracketEnd(from: start), end + 1 < chars.count, chars[end + 1] == "(", let (target, next) = destination(from: end + 2) {
                    flush()
                    let label = String(chars[start..<end])
                    if image { append(.image(.init(src: target, alt: RichInline.plain(parse(label, depth: depth + 1))))) }
                    else { parse(label, marks: marks, link: target, depth: depth + 1).forEach(append) }
                    index = next; continue
                }
            }
            if character == "*" || character == "_" || character == "~" {
                let count = run(at: index)
                let width = character == "~" ? 2 : min(count, 3)
                let intraword = character == "_" && index > 0 && chars[index - 1].isLetter && index + width < chars.count && chars[index + width].isLetter
                if !intraword, count >= width, index + width < chars.count, !chars[index + width].isWhitespace,
                   let end = closing(String(repeating: String(character), count: width), from: index + width) {
                    let style: Marks = character == "~" ? .strike : width == 3 ? [.bold, .italic] : width == 2 ? .bold : .italic
                    flush(); parse(String(chars[(index + width)..<end]), marks: marks.union(style), link: link, depth: depth + 1).forEach(append)
                    index = end + width; continue
                }
            }
            if character == "<", let end = chars[(index + 1)...].firstIndex(of: ">") {
                let tag = String(chars[(index + 1)..<end]), lower = tag.lowercased()
                if ["br", "br/", "br /"].contains(lower) { flush(); append(.br); index = end + 1; continue }
                let htmlMarks: [String: Marks] = ["u": .underline, "sup": .sup, "sub": .sub, "mark": .mark, "strong": .bold, "b": .bold, "em": .italic, "i": .italic, "s": .strike, "del": .strike]
                if let style = htmlMarks[lower], let close = closing("</" + lower + ">", from: end + 1) {
                    flush(); parse(String(chars[(end + 1)..<close]), marks: marks.union(style), link: link, depth: depth + 1).forEach(append)
                    index = close + lower.count + 3; continue
                }
                if tag.hasPrefix("https://") || tag.hasPrefix("http://") || tag.hasPrefix("mailto:") {
                    flush(); append(.text(tag, marks, link: tag, color: nil)); index = end + 1; continue
                }
            }
            if character == "&", let end = chars[index...].prefix(32).firstIndex(of: ";") {
                let entity = String(chars[index...end]), decoded = decodeEntities(entity)
                if decoded != entity { buffer += decoded; index = end + 1; continue }
            }
            buffer.append(character); index += 1
        }
        flush()
        return result
    }

    static func decodeEntities(_ source: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}", "rarr": "→", "larr": "←", "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©"]
        var value = source
        for match in source.matches(of: /&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/).reversed() {
            let name = String(match.1)
            let decoded: String?
            if name.hasPrefix("#x") { decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init) }
            else if name.hasPrefix("#") { decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init) }
            else { decoded = named[name] }
            if let decoded { value.replaceSubrange(match.range, with: decoded) }
        }
        return value
    }
}
