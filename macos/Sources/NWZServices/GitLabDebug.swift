import Foundation
import NWZCore
import NWZGitLab

/// 命令行和调试桥共用的只读白名单，写操作只通过类型化服务调用。
public enum GitLabDebug {
    public static let commands: Set<String> = Set("""
        gl_projects gl_project gl_branches gl_tree gl_file gl_commits gl_commit gl_compare gl_me
        gl_merge_requests gl_project_merge_requests gl_merge_request gl_mr_changes gl_mr_commits gl_mr_discussions gl_mr_approvals
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    public static func run(_ command: String, arguments a: [String: JSONValue], client: GitLabClient) async throws -> Data {
        guard commands.contains(command) else { throw NWZError.other("调试通道只允许读取 GitLab 数据") }
        func s(_ key: String) -> String { a[key]?.string ?? "" }
        func n(_ key: String, _ fallback: Int = 0) -> Int { a[key]?.decode(Int.self) ?? fallback }
        func output<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
        let project = s("project"), iid = n("iid"), query = a["query"]?.decode(MrQuery.self) ?? MrQuery()
        switch command {
        case "gl_projects": return try await output(client.projects(search: a["search"]?.string))
        case "gl_project": return try await output(client.project(n("id")))
        case "gl_branches": return try await output(client.branches(n("project")))
        case "gl_tree": return try await output(client.tree(n("project"), ref: s("gitRef"), path: s("path")))
        case "gl_file": return try await output(client.file(n("project"), ref: s("gitRef"), path: s("path")))
        case "gl_commits": return try await output(client.commits(n("project"), ref: s("gitRef"), path: a["path"]?.string, page: n("page", 1)))
        case "gl_commit": return try await output(client.commit(n("project"), sha: s("sha")))
        case "gl_compare": return try await output(client.compare(n("project"), from: s("from"), to: s("to")))
        case "gl_me": return try await output(client.currentUser())
        case "gl_merge_requests":
            guard let scope = MrScope(rawValue: s("scope")) else { throw NWZError.other("无法识别的合并请求范围") }
            return try await output(client.mergeRequests(scope: scope, query: query))
        case "gl_project_merge_requests": return try await output(client.projectMergeRequests(project, query: query))
        case "gl_merge_request": return try await output(client.mergeRequest(project, iid: iid))
        case "gl_mr_changes": return try await output(client.mrChanges(project, iid: iid))
        case "gl_mr_commits": return try await output(client.mrCommits(project, iid: iid))
        case "gl_mr_discussions": return try await output(client.mrDiscussions(project, iid: iid))
        case "gl_mr_approvals": return try await output(client.mrApprovals(project, iid: iid))
        default: throw NWZError.other("未知的只读 GitLab 命令")
        }
    }
}
