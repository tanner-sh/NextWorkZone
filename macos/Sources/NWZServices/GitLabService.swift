import Foundation
import NWZCore
import NWZGitLab
import NWZJira

public actor GitLabService {
    public nonisolated let attachments: AttachmentService
    let settings: SettingsService
    let jira: JiraService
    let cache: FileCache
    var projectNames: [String: [Int: String]] = [:]
    var inboxCache: (identity: String, at: Date, items: [InboxItem])?
    public init(settings: SettingsService, jira: JiraService, host: any AppHost, web: any WebResourceSource) {
        self.settings = settings; self.jira = jira
        attachments = AttachmentService(settings: settings, web: web, host: host)
        cache = FileCache(directory: settings.paths.cache.appendingPathComponent("responses", isDirectory: true))
    }
    public func client() async throws -> GitLabClient { try await GitLabClient(rest: settings.restClient(.gitlab)) }
    public func configurationChanged() { inboxCache = nil; projectNames = [:] }
    /// 在应用里改了合并请求：下次汇总需要处理的事时重新查询。
    public func inboxChanged() { inboxCache = nil }
    public func cachedProjects() async throws -> [Project]? { await cache.get(try client().rest.cacheIdentity + ":gitlab:projects", as: [Project].self) }
    public func projects(search: String? = nil) async throws -> [Project] {
        let client = try await client(), projects = try await client.projects(search: search)
        if search?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true { await cache.put(client.rest.cacheIdentity + ":gitlab:projects", value: projects) }
        return projects
    }
    public func issueCodeRefs(_ key: String, texts: [IssueText]) async -> [CodeRef] { await CodeReferences.issue(key, texts: texts, client: try? await client()) }
    public func relatedIssues(_ target: CodeTarget) async throws -> [IssueHit] {
        var out: [IssueHit] = []
        let keys = GitLabLinks.issueKeys(target.text)
        if !keys.isEmpty {
            let hits = (try? await jira.index.byKeys(keys)) ?? []
            out = hits.map { var hit = $0; hit.via = "key"; return hit }
            let missing = keys.filter { key in !hits.contains { $0.key == key } }.prefix(5)
            if !missing.isEmpty, let client = try? await jira.client() {
                for key in missing {
                    if let result = try? await client.search("key = " + key, maxResults: 1) {
                        out += result.issues.map { var hit = IssueHit(issue: $0, resolved: nil, commentCount: 0, snippet: nil, lastComments: []); hit.via = "key"; return hit }
                    }
                }
            }
            out.sort { (keys.firstIndex(of: $0.key) ?? Int.max) < (keys.firstIndex(of: $1.key) ?? Int.max) }
        }
        if let client = try? await client() {
            let path = target.projectPath.lowercased(), needles: [String]
            if let iid = target.iid { needles = ["\(path)/-/merge_requests/\(iid)", "\(path)/merge_requests/\(iid)"] }
            else if let sha = target.sha, sha.count >= 7 { let short = sha.prefix(7).lowercased(); needles = ["\(path)/-/commit/\(short)", "\(path)/commit/\(short)"] }
            else if let branch = target.branch { let b = branch.lowercased(); needles = ["\(path)/-/tree/\(b)", "\(path)/tree/\(b)", "\(path)/-/commits/\(b)", "\(path)/commits/\(b)"] }
            else { needles = [] }
            if !needles.isEmpty {
                let base = client.baseURL
                let found = try? await jira.index.mentioning(needles, accept: { text in
                    GitLabLinks.urls(text).compactMap { GitLabLinks.parse(base: base, url: $0) }.contains { link in
                        guard link.projectPath.lowercased() == path else { return false }
                        switch link.target {
                        case .mergeRequest(let iid): return target.iid == iid
                        case .commit(let sha): return target.iid == nil && GitLabLinks.sameCommit(sha, target.sha?.lowercased())
                        case .branch(let rest): return target.iid == nil && target.sha == nil && target.branch.map { GitLabLinks.branchCandidates(rest, limit: 6).contains($0) } == true
                        }
                    }
                }, limit: 20)
                for var hit in found ?? [] where !out.contains(where: { $0.key == hit.key }) { hit.via = "link"; out.append(hit) }
            }
        }
        return Array(out.prefix(20))
    }
    public func readOnly(_ command: String, arguments: [String: JSONValue]) async throws -> Data {
        switch command {
        case "gl_cached_projects": return try await JSONEncoder().encode(cachedProjects())
        case "gl_projects": return try await JSONEncoder().encode(projects(search: arguments["search"]?.string))
        case "issue_code_refs": return try await JSONEncoder().encode(issueCodeRefs(arguments["key"]?.string ?? "", texts: arguments["texts"]?.decode([IssueText].self) ?? []))
        case "code_related_issues":
            guard let target = arguments["target"]?.decode(CodeTarget.self) else { throw NWZError.other("缺少代码对象") }
            return try await JSONEncoder().encode(relatedIssues(target))
        default: return try await GitLabDebug.run(command, arguments: arguments, client: client())
        }
    }
}
