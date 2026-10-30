import Foundation
import NWZCore

private enum PendingCode: Sendable {
    case link(GitLabLink, String, [CodeRefSource])
    case mr(MergeRequest, [CodeRefSource])
    case commit(Project, Commit, [CodeRefSource])
}

public enum CodeReferences {
    public static func issue(_ key: String, texts: [IssueText], client: GitLabClient?) async -> [CodeRef] {
        let base = client?.baseURL ?? ""
        var pending: [PendingCode] = [], external: [CodeRef] = [], seen: [GitLabLink: Int] = [:]
        for text in texts {
            let source = CodeRefSource(kind: text.source == "description" ? "description" : "comment", author: text.author, at: text.at, commentId: text.commentId)
            for url in GitLabLinks.urls(text.html) {
                if let link = GitLabLinks.parse(base: base, url: url) {
                    let identity = GitLabLink(projectPath: link.projectPath.lowercased(), target: link.target)
                    if let i = seen[identity], case .link(let old, let url, let sources) = pending[i] { pending[i] = .link(old, url, sources + [source]) }
                    else if seen.count < 20 { seen[identity] = pending.count; pending.append(.link(link, url, [source])) }
                } else if GitLabLinks.looksLikeGitLab(url) {
                    if let i = external.firstIndex(where: { $0.url == url }) { external[i].sources.append(source) }
                    else {
                        let path = url.components(separatedBy: "://").dropFirst().joined(separator: "://").components(separatedBy: "/-/")[0]
                        external.append(reference("external", url: url, path: path, sources: [source]))
                    }
                }
            }
        }
        guard let client else { return external }
        let mrs = (try? await client.searchMergeRequests(key, limit: 20)) ?? []
        for mr in mrs where GitLabLinks.mentions(mr.title + " " + mr.sourceBranch + " " + mr.description, key: key) {
            pending.append(.mr(mr, [CodeRefSource(kind: "mrSearch", author: mr.author.name, at: mr.createdAt)]))
        }
        let paths = pending.compactMap { item -> String? in
            switch item { case .link(let link, _, _): return link.projectPath; case .mr(let mr, _): return GitLabLinks.parse(base: base, url: mr.webUrl)?.projectPath; case .commit: return nil }
        }
        var unique: [String] = [], seenPaths: Set<String> = []
        for path in paths where seenPaths.insert(path.lowercased()).inserted { unique.append(path) }
        let loaded = await map(unique) { path in (path.lowercased(), try? await client.project(path: path)) }
        let projects = Dictionary(uniqueKeysWithValues: loaded.compactMap { key, project in project.map { (key, $0) } })
        var search: [Project] = []
        for path in paths {
            if let project = projects[path.lowercased()], search.count < 5, !search.contains(where: { $0.id == project.id }) { search.append(project) }
        }
        let commits = await map(search) { project in (project, (try? await client.searchCommits(project.id, text: key, limit: 20)) ?? []) }
        for (project, commits) in commits {
            for commit in commits where GitLabLinks.mentions(commit.message, key: key) || GitLabLinks.mentions(commit.title, key: key) {
                pending.append(.commit(project, commit, [CodeRefSource(kind: "commitSearch", author: commit.authorName, at: commit.authoredDate)]))
            }
        }
        let resolved = await map(pending) { item in await resolve(item, projects: projects, client: client, key: key) }
        var refs: [CodeRef] = []
        for ref in resolved {
            if let i = refs.firstIndex(where: { identity($0) == identity(ref) || ($0.kind == "commit" && ref.kind == "commit" && $0.projectId == ref.projectId && GitLabLinks.sameCommit($0.sha, ref.sha)) }) {
                let sources = refs[i].sources + ref.sources
                if refs[i].unavailable != nil && ref.unavailable == nil { refs[i] = ref }
                refs[i].sources = sources
            } else { refs.append(ref) }
        }
        let order = ["mr": 0, "branch": 1]
        refs = refs.enumerated().sorted {
            let a = order[$0.element.kind] ?? 2, b = order[$1.element.kind] ?? 2
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        return refs + external
    }
    static func reference(_ kind: String, url: String, path: String, sources: [CodeRefSource]) -> CodeRef {
        CodeRef(kind: kind, url: url, projectPath: path, projectName: path.components(separatedBy: "/").last ?? "", sources: sources)
    }
    static func identity(_ ref: CodeRef) -> String {
        let project = ref.projectId.map(String.init) ?? ref.projectPath.lowercased()
        switch ref.kind {
        case "mr": return "mr:\(project)!\(ref.iid ?? 0)"
        case "branch": return "branch:\(project):\(ref.branch ?? "")"
        case "commit": return "commit:\(project)@\((ref.sha ?? "").prefix(12))"
        default: return "url:" + ref.url
        }
    }
    static func withProject(_ ref: CodeRef, _ project: Project) -> CodeRef {
        var ref = ref; ref.projectId = project.id; ref.projectPath = project.pathWithNamespace; ref.projectName = project.name; return ref
    }
    static func fill(_ ref: inout CodeRef, mr: MergeRequest) {
        ref.iid = mr.iid; ref.title = mr.title; ref.state = mr.state; ref.pipeline = mr.headPipeline?.status
        ref.author = mr.author.name; ref.at = mr.mergedAt ?? mr.updatedAt; ref.branch = mr.sourceBranch; ref.url = mr.webUrl
    }
    static func fill(_ ref: inout CodeRef, commit: Commit) { ref.sha = commit.id; ref.title = commit.title; ref.author = commit.authorName; ref.at = commit.authoredDate }
    private static func resolve(_ item: PendingCode, projects: [String: Project], client: GitLabClient, key: String) async -> CodeRef {
        switch item {
        case .mr(let mr, let sources):
            let path = GitLabLinks.parse(base: client.baseURL, url: mr.webUrl)?.projectPath ?? "", project = projects[path.lowercased()]
            var ref = reference("mr", url: mr.webUrl, path: project?.pathWithNamespace ?? "", sources: sources)
            if let project { ref = withProject(ref, project) }; ref.projectId = mr.projectId
            let detail = (try? await client.mergeRequest(String(mr.projectId), iid: mr.iid)) ?? mr
            fill(&ref, mr: detail); return ref
        case .commit(let project, let commit, let sources):
            var ref = withProject(reference("commit", url: commit.webUrl ?? project.webUrl + "/-/commit/" + commit.id, path: "", sources: sources), project)
            fill(&ref, commit: commit); return ref
        case .link(let link, let url, let sources):
            let kind: String
            switch link.target { case .branch: kind = "branch"; case .commit: kind = "commit"; case .mergeRequest: kind = "mr" }
            var ref = reference(kind, url: url, path: link.projectPath, sources: sources)
            switch link.target { case .branch(let rest): ref.branch = rest; case .commit(let sha): ref.sha = sha; case .mergeRequest(let iid): ref.iid = iid }
            guard let project = projects[link.projectPath.lowercased()] else { ref.unavailable = "无法访问这个项目（没有权限或已删除）"; return ref }
            ref = withProject(ref, project)
            switch link.target {
            case .mergeRequest(let iid):
                if let mr = try? await client.mergeRequest(String(project.id), iid: iid) { fill(&ref, mr: mr) }
                else { ref.unavailable = "无法读取这个合并请求" }
            case .commit(let sha):
                if let commit = try? await client.commitInfo(project.id, sha: sha) { fill(&ref, commit: commit) }
                else { ref.state = "missing" }
            case .branch(let rest): ref = await branch(ref, project: project, rest: rest, key: key, client: client)
            }
            return ref
        }
    }
    private static func branch(_ original: CodeRef, project: Project, rest: String, key: String, client: GitLabClient) async -> CodeRef {
        var ref = original, found: Branch?
        let candidates = GitLabLinks.branchCandidates(rest, limit: 6)
        for name in candidates {
            if let branch = try? await client.branch(project.id, name: name) { found = branch; break }
        }
        guard let branch = found else { ref.branch = candidates.last ?? rest; ref.state = "missing"; return ref }
        ref.branch = branch.name; if branch.merged { ref.state = "merged" }
        ref.title = branch.commit.title; ref.author = branch.commit.authorName; ref.at = branch.commit.authoredDate
        let times = ref.sources.compactMap { $0.at.flatMap(time) }
        guard let first = times.min(), let last = times.max() else { return ref }
        let since = first.addingTimeInterval(-3 * 86400).ISO8601Format(), until = last.addingTimeInterval(86400).ISO8601Format()
        let commits = ((try? await client.commitsBetween(project.id, ref: branch.name, since: since, until: until, limit: 30)) ?? []).filter { !$0.title.hasPrefix("Merge branch ") && !$0.title.hasPrefix("Merge remote-tracking branch ") }
        let authors = Set(ref.sources.compactMap(\.author))
        ref.commits = commits.enumerated().sorted {
            let a = (GitLabLinks.mentions($0.element.message, key: key) ? 0 : 2) + (authors.contains($0.element.authorName) ? 0 : 1)
            let b = (GitLabLinks.mentions($1.element.message, key: key) ? 0 : 2) + (authors.contains($1.element.authorName) ? 0 : 1)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        return ref
    }
    static func time(_ value: String) -> Date? { ServerTime.parse(value) }
    /// 限制同时在途的请求，并按输入顺序输出，让多来源结果稳定。
    static func map<Input: Sendable, Output: Sendable>(_ input: [Input], transform: @escaping @Sendable (Input) async -> Output) async -> [Output] {
        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0, output: [(Int, Output)] = []
            for i in input.indices.prefix(4) { group.addTask { (i, await transform(input[i])) }; next += 1 }
            while let result = await group.next() {
                output.append(result)
                if next < input.count, !Task.isCancelled { let i = next; group.addTask { (i, await transform(input[i])) }; next += 1 }
            }
            return output.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
