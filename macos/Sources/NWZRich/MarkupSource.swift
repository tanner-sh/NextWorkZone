import Foundation
import NWZCore

/// 只定位原文，不重新序列化。UTF-8 字节范围保证中文、实体和宏的原始写法都能保留。
public struct MarkupSource: Sendable {
    public enum Kind: Sendable { case start, end, empty, text, other }
    public struct Token: Sendable {
        public var kind: Kind
        public var name: String
        public var span: Range<Int>
        public var depth: Int
        public var close: Int?
    }
    public let bytes: [UInt8]
    public let tokens: [Token]
    private static let voids: Set<String> = ["br", "img", "hr", "col", "input", "meta", "link", "area", "base", "wbr", "source"]

    public init(_ source: String, html: Bool = false, strict: Bool = false) throws {
        let b = Array(source.utf8)
        var tokens: [Token] = [], stack: [Int] = [], i = 0
        func slice(_ range: Range<Int>) -> String { String(decoding: b[range], as: UTF8.self) }
        func error(_ at: Int) -> NWZError { .other("页面内容格式不正确，未保存（位置 \(at)）") }
        func endOf(_ suffix: [UInt8], from: Int) -> Int? {
            guard from <= b.count - suffix.count else { return nil }
            for p in from...(b.count - suffix.count) where b[p..<(p + suffix.count)].elementsEqual(suffix) { return p + suffix.count }
            return nil
        }
        while i < b.count {
            let start = i
            if b[i] != 60 {
                while i < b.count, b[i] != 60 { i += 1 }
                tokens.append(Token(kind: .text, name: "", span: start..<i, depth: stack.count))
                continue
            }
            var special: (String, String)?
            if b[i...].starts(with: Array("<!--".utf8)) { special = ("<!--", "-->") }
            else if b[i...].starts(with: Array("<![CDATA[".utf8)) { special = ("<![CDATA[", "]]>") }
            else if b[i...].starts(with: Array("<?".utf8)) { special = ("<?", "?>") }
            else if b[i...].starts(with: Array("<!".utf8)) { special = ("<!", ">") }
            if let (prefix, suffix) = special {
                guard let end = endOf(Array(suffix.utf8), from: i + prefix.utf8.count) else { throw error(i) }
                i = end
                tokens.append(Token(kind: .other, name: "", span: start..<i, depth: stack.count))
                continue
            }
            i += 1
            let closing = i < b.count && b[i] == 47
            if closing { i += 1 }
            let nameStart = i
            while i < b.count, Self.nameByte(b[i]) { i += 1 }
            if i == nameStart {
                if strict { throw error(start) }
                tokens.append(Token(kind: .text, name: "", span: start..<i, depth: stack.count))
                continue
            }
            let name = html ? slice(nameStart..<i).lowercased() : slice(nameStart..<i)
            var quote: UInt8?
            while i < b.count {
                let c = b[i]
                if let q = quote { if c == q { quote = nil } }
                else if c == 34 || c == 39 { quote = c }
                else if c == 62 { break }
                else if strict && c == 60 { throw error(i) }
                i += 1
            }
            guard i < b.count, quote == nil else { throw error(start) }
            i += 1
            let empty = !closing && (b[i - 2] == 47 || (html && Self.voids.contains(name)))
            var tok = Token(kind: closing ? .end : (empty ? .empty : .start), name: name, span: start..<i, depth: stack.count)
            if closing {
                if strict && stack.last.map({ tokens[$0].name }) != name { throw error(start) }
                if let pos = stack.lastIndex(where: { tokens[$0].name == name }) {
                    let open = stack[pos]
                    stack.removeSubrange(pos...)
                    tokens[open].close = tokens.count
                    tok.depth = pos
                } else { tok.kind = .other }
            } else if !empty {
                guard stack.count < 512 else { throw error(start) }
                stack.append(tokens.count)
            }
            tokens.append(tok)
        }
        if strict && !stack.isEmpty { throw error(b.count) }
        self.bytes = b
        self.tokens = tokens
    }

    private static func nameByte(_ b: UInt8) -> Bool {
        (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || [58, 45, 95, 46].contains(b)
    }

    public func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
    public func tag(_ i: Int) -> String { string(tokens[i].span) }
    public func outer(_ i: Int) -> Range<Int> { tokens[i].span.lowerBound..<(tokens[i].close.map { tokens[$0].span.upperBound } ?? tokens[i].span.upperBound) }
    public func inner(_ i: Int) -> Range<Int> { tokens[i].span.upperBound..<(tokens[i].close.map { tokens[$0].span.lowerBound } ?? tokens[i].span.upperBound) }
    public func children(_ i: Int) -> Range<Int> { (i + 1)..<(tokens[i].close ?? (i + 1)) }
    public func findChildren(_ range: Range<Int>, depth: Int, name: String) -> [Int] {
        range.filter { tokens[$0].kind == .start && tokens[$0].depth == depth && tokens[$0].name == name }
    }

    public static func rawAttribute(_ tag: String, _ name: String) -> String? {
        for match in tag.matches(of: /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/) where String(match.1) == name {
            return String(match.2 ?? match.3 ?? "")
        }
        return nil
    }
}
