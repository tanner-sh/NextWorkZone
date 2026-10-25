import Foundation
import NWZRich

public struct Reference: Hashable, Sendable {
    public var system: String
    public var key: String
    public init(system: String, key: String) { self.system = system; self.key = key }
}

public enum References {
    public static func extract(_ text: String) -> [Reference] {
        var result: [Reference] = []
        func add(_ system: String, _ key: Substring) {
            let reference = Reference(system: system, key: String(key))
            if !result.contains(reference) { result.append(reference) }
        }
        var remaining = text[...]
        while let match = remaining.firstMatch(of: /(?:^|[^A-Za-z0-9_\-])([A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,6})(?:$|[^A-Za-z0-9_])/) {
            add("jira", match.1)
            remaining = remaining[match.1.endIndex...]
        }
        for match in text.matches(of: /ws:\/\/doc\/([A-Za-z0-9\-]+)/) { add("doc", match.1) }
        for match in text.matches(of: /pageId=([0-9]+)/) { add("wiki", match.1) }
        return result
    }

    public static func plainText(_ text: String) -> String {
        Markdown.parse(text).plainText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func snippet(_ body: String, query: String) -> String {
        let start = body.range(of: query, options: .caseInsensitive)?.lowerBound ?? body.startIndex
        let offset = max(0, body.distance(from: body.startIndex, to: start) - 30)
        let excerpt = body.dropFirst(offset).prefix(120).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (offset > 0 ? "…" : "") + excerpt
    }
}
