import Foundation
import NWZCore

public struct IndexedIssue: Codable, Sendable {
    public var issue: IssueSummary
    public var resolved: String?
    public var description: String
    public var comments: [BriefComment]
    public init(raw: JSONDocument) {
        issue = IssueSummary(raw: raw); resolved = raw["fields"]["resolutiondate"].string
        description = JiraIndexText.plain(raw["fields"]["description"].text)
        comments = raw["fields"]["comment"]["comments"].list.map { BriefComment(author: $0["author"]["displayName"].text, authorName: $0["author"]["name"].text, created: $0["created"].text, body: JiraIndexText.plain($0["body"].text)) }
    }
    public func hit(terms: [String] = [], boilerplate: Set<String>? = nil) -> IssueHit {
        let snippet = terms.lazy.compactMap { JiraIndexText.excerpt(description, term: $0).map { HitSnippet(source: "description", text: $0) } }.first ?? terms.lazy.compactMap { term in comments.reversed().lazy.compactMap { comment in JiraIndexText.excerpt(comment.body, term: term).map { HitSnippet(source: "comment", author: comment.author, text: $0) } }.first }.first
        let last: [BriefComment]
        if let boilerplate { last = comments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !boilerplate.contains(String($0.body.unicodeScalars.prefix(20))) }.suffix(2).map { var comment = $0; comment.body = JiraIndexText.truncate(comment.body, limit: 300); return comment } }
        else { last = [] }
        return IssueHit(issue: issue, resolved: resolved, commentCount: comments.count, snippet: snippet, lastComments: last)
    }
}

public enum JiraIndexText {
    public static func project(_ key: String) -> String { key.lastIndex(of: "-").map { String(key[..<$0]) } ?? key }
    public static func fold(_ text: String) -> String { TextFold.fold(text) }
    static func terms(_ text: String) -> [String] {
        var result: [String] = []
        for term in text.split(whereSeparator: \.isWhitespace).map({ fold(String($0)) }) where !result.contains(term) && result.count < 8 { result.append(term) }
        return result
    }
    static func excerpt(_ text: String, term: String) -> String? {
        // 每个搜索结果都要在描述和全部评论中找一遍，大多找不到：逐字比较，不复制子串
        let characters = Array(text.unicodeScalars), needle = Array(term.unicodeScalars)
        guard let first = needle.first, needle.count <= characters.count else { return nil }
        let lower = characters.map(TextFold.fold)
        guard let index = (0...(lower.count - needle.count)).first(where: { start in lower[start] == first && lower[start..<(start + needle.count)].elementsEqual(needle) }) else { return nil }
        let from = max(0, index - 30), to = min(characters.count, index + needle.count + 90)
        let snippet = String(String.UnicodeScalarView(characters[from..<to])).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (from > 0 ? "…" : "") + snippet + (to < characters.count ? "…" : "")
    }
    static func truncate(_ text: String, limit: Int) -> String {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(text.prefix(limit)) + (text.count > limit ? "…" : "")
    }
    public static func stripOrder(_ jql: String) -> String {
        let text = jql.replacingOccurrences(of: #"(?is)\s+ORDER\s+BY\s+.*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "created is not EMPTY" : text
    }
    static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)<br\s*/?>|</p>|</li>|</tr>"#, "\n"),
        (#"(?i)<a\s[^>\n]*?href="(https?://[^"]+)"[^>\n]*>"#, " $1 "),
        (#"<[^>\n]{1,500}>"#, " "), (#"\{[a-zA-Z]+(?::[^}]*)?\}"#, " "),
        (#"![^!\s][^!\n]*!"#, " "), (#"\[~([^\]]+)\]"#, "@$1"),
        (#"\[([^|\]]+)\|(https?://[^\]]+)\]"#, "$1 $2"), (#"\[([^|\]]+)\|[^\]]+\]"#, "$1"),
        (#"\[([^\]]+)\]"#, "$1"), (#"(?m)^\s*h[1-6]\.\s*"#, ""),
        (#"(?m)^\s*(?:[*#-]+|bq\.)\s+"#, ""), (#"\|\|?"#, " "),
        (#"(^|[\s(])[*_+](\S[^*_+\n]*?)[*_+]"#, "$1$2"),
        (#"[ \t\x{3000}]+"#, " "), (#"\s*\n[\s\n]*"#, "\n")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    public static func plain(_ markup: String) -> String {
        var text = markup.replacingOccurrences(of: "\r\n", with: "\n")
        for (regex, replacement) in rules { text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement) }
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: value) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension IssueHit {
    public init(issue: IssueSummary, resolved: String?, commentCount: Int, snippet: HitSnippet?, lastComments: [BriefComment]) {
        self.init(key: issue.key, summary: issue.summary, status: issue.status, issueType: issue.issueType, priority: issue.priority, project: issue.project, assignee: issue.assignee, assigneeName: issue.assigneeName, reporter: issue.reporter, reporterName: issue.reporterName, lastViewed: issue.lastViewed, resolution: issue.resolution, created: issue.created, updated: issue.updated, dueDate: issue.dueDate, extra: issue.extra, resolved: resolved, commentCount: commentCount, snippet: snippet, lastComments: lastComments)
    }
}
