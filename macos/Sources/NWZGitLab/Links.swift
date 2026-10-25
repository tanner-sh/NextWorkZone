import Foundation

public enum GitLabLinkTarget: Hashable, Sendable {
    case branch(rest: String)
    case commit(sha: String)
    case mergeRequest(iid: Int)
}
public struct GitLabLink: Hashable, Sendable {
    public var projectPath: String
    public var target: GitLabLinkTarget
    public init(projectPath: String, target: GitLabLinkTarget) { self.projectPath = projectPath; self.target = target }
}
public enum GitLabLinks {
    static let reserved: Set<String> = ["users", "dashboard", "explore", "help", "admin", "profile", "search", "-", "api", "assets", "uploads"]
    static let pages: Set<String> = ["tree", "blob", "commits", "commit", "merge_requests", "issues", "branches", "tags", "compare", "raw", "blame", "pipelines", "jobs", "wikis"]
    public static func urls(_ text: String) -> [String] {
        var out: [String] = []
        for match in text.matches(of: #/https?://[^\s"'<>\]|)（），。、；]+/#) {
            var url = String(match.output).replacingOccurrences(of: "&amp;", with: "&")
            while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
            if !out.contains(url) { out.append(url) }
        }
        return out
    }
    public static func issueKeys(_ text: String) -> [String] {
        var out: [String] = [], remaining = text[...]
        while let match = remaining.firstMatch(of: /(?:^|[^A-Za-z0-9_\-])([A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,6})(?:$|[^A-Za-z0-9_])/) {
            let key = String(match.1); if !out.contains(key) { out.append(key) }
            remaining = remaining[match.1.endIndex...]
        }
        return out
    }
    public static func mentions(_ text: String, key: String) -> Bool { issueKeys(text).contains(key) }
    public static func parse(base: String, url: String) -> GitLabLink? {
        let base = String(base.reversed().drop(while: { $0 == "/" }).reversed())
        guard !base.isEmpty, url.hasPrefix(base + "/") else { return nil }
        return parsePath(String(url.dropFirst(base.count)))
    }
    public static func looksLikeGitLab(_ url: String) -> Bool {
        guard let scheme = url.range(of: "://"), let slash = url[scheme.upperBound...].firstIndex(of: "/") else { return false }
        let path = String(url[slash...]); return path.contains("/-/") && parsePath(path) != nil
    }
    static func parsePath(_ path: String) -> GitLabLink? {
        let path = path.prefix(while: { $0 != "?" && $0 != "#" })
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 3, !reserved.contains(parts[0]) else { return nil }
        let projectEnd: Int, page: Int
        if let dash = parts.firstIndex(of: "-") { guard dash >= 2 else { return nil }; projectEnd = dash; page = dash + 1 }
        else { guard let index = parts.indices.first(where: { $0 >= 2 && pages.contains(parts[$0]) }) else { return nil }; projectEnd = index; page = index }
        guard parts.indices.contains(page + 1) else { return nil }
        let args = Array(parts[(page + 1)...]), target: GitLabLinkTarget
        switch parts[page] {
        case "tree", "commits", "blob": target = .branch(rest: args.joined(separator: "/"))
        case "commit":
            guard args[0].utf8.count >= 7, args[0].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
            target = .commit(sha: args[0].lowercased())
        case "merge_requests": guard let iid = Int(args[0]), iid > 0 else { return nil }; target = .mergeRequest(iid: iid)
        default: return nil
        }
        return GitLabLink(projectPath: parts[..<projectEnd].joined(separator: "/"), target: target)
    }
    public static func branchCandidates(_ rest: String, limit: Int) -> [String] {
        let parts = rest.split(separator: "/")
        return (1..<(parts.count + 1)).reversed().prefix(max(0, limit)).map { parts.prefix($0).joined(separator: "/") }
    }
    public static func sameCommit(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, a.count >= 7, b.count >= 7 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }
}
