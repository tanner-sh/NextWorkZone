import Foundation
import NWZCore
import NWZRich

public typealias StorageDocument = MarkupSource

public enum WikiStorage {
    public static func collapseWhitespace(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    public static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func decodeEntities(_ raw: String) -> String { entities(raw, normalize: false) }
    public static func normalizeEntities(_ raw: String) -> String { entities(raw, normalize: true) }
    private static func entities(_ raw: String, normalize: Bool) -> String {
        var out = "", rest = raw[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            if let end = rest.prefix(12).firstIndex(of: ";") {
                let name = String(rest[rest.index(after: amp)..<end])
                var decoded = named[name]
                if name.hasPrefix("#") {
                    let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
                    if let n = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(n) { decoded = String(scalar) }
                }
                if let decoded, !(normalize && (["amp", "lt", "gt"].contains(name) || decoded == "&")) {
                    out += decoded
                    rest = rest[rest.index(after: end)...]
                    continue
                }
            }
            out += "&"
            rest = rest.dropFirst()
        }
        return out + rest
    }

    private static let named: [String: String] = [
        "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "times": "×",
        "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "harr": "↔", "rArr": "⇒", "lArr": "⇐", "hArr": "⇔",
        "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "plusmn": "±", "divide": "÷", "minus": "−", "deg": "°", "permil": "‰",
        "infin": "∞", "radic": "√", "sum": "∑", "copy": "©", "reg": "®", "trade": "™", "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "bdquo": "„", "sbquo": "‚", "bull": "•", "sect": "§", "para": "¶", "dagger": "†", "yen": "¥", "euro": "€", "pound": "£", "cent": "¢",
        "iexcl": "¡", "iquest": "¿", "shy": "\u{ad}", "zwj": "\u{200d}", "zwnj": "\u{200c}", "acute": "´", "uml": "¨", "macr": "¯",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³", "micro": "µ",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "pi": "π", "sigma": "σ", "mu": "μ", "lambda": "λ", "Delta": "Δ", "Omega": "Ω",
        "check": "✓", "hearts": "♥", "star": "☆",
    ]

    public static func attribute(_ tag: String, _ name: String) -> String? { MarkupSource.rawAttribute(tag, name).map(decodeEntities) }

    public static func validate(_ storage: String) throws {
        _ = try StorageDocument(storage, strict: true)
    }
}

extension MarkupSource {
    public func text(_ range: Range<Int>) -> String {
        var out = ""
        for i in range {
            let token = tokens[i]
            if token.kind == .text { out += WikiStorage.decodeEntities(tag(i)) }
            else if token.kind == .empty && token.name == "br" { out += " " }
        }
        return WikiStorage.collapseWhitespace(out)
    }
    public func attribute(_ i: Int, _ name: String) -> String? { WikiStorage.attribute(tag(i), name) }
    public func child(_ i: Int, _ name: String) -> Int? { children(i).first { tokens[$0].name == name && [.start, .empty].contains(tokens[$0].kind) } }
    public func parameter(_ i: Int, _ name: String) -> String? {
        children(i).first { tokens[$0].name == "ac:parameter" && tokens[$0].kind == .start && attribute($0, "ac:name") == name }.map { text(children($0)) }
    }
}
