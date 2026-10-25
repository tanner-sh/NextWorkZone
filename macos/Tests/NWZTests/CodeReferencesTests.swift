import Foundation
import Testing
import NWZCore
import NWZGitLab

actor CodeTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request); let (status, text) = handler(request)
        return HTTPResponse(data: Data(text.utf8), status: status, url: request.url!)
    }
}
@Suite struct CodeReferencesTests {
    func client(_ t: CodeTransport) -> GitLabClient { GitLabClient(rest: RESTClient(baseURL: "https://git.example.com", token: "test-token", authorizationHeader: "PRIVATE-TOKEN", http: HTTPClient(transport: t))) }
    @Test func mergesMRLinkAndSearchEvidenceAndLoadsProjectOnce() async throws {
        let mr = #"{"id":1,"iid":42,"project_id":7,"title":"修复 ABC-1","source_branch":"feature/ABC-1","author":{"name":"张三"},"web_url":"https://git.example.com/group/sub/app/-/merge_requests/42","head_pipeline":{"status":"success"}}"#
        let t = CodeTransport { request in
            let url = request.url!.absoluteString.removingPercentEncoding!
            if url.contains("/projects/group/sub/app") { return (200, #"{"id":7,"name":"项目","path_with_namespace":"group/sub/app"}"#) }
            if url.contains("/projects/7/search") { return (200, "[]") }
            if url.contains("/projects/7/merge_requests/42") { return (200, mr) }
            return (200, "[" + mr + "]")
        }
        let link = "https://git.example.com/group/sub/app/-/merge_requests/42"
        let refs = await CodeReferences.issue("ABC-1", texts: [IssueText(source: "description", html: link), IssueText(source: "comment", commentId: "1", html: link)], client: client(t))
        #expect(refs.count == 1)
        #expect(refs[0].pipeline == "success" && refs[0].projectName == "项目")
        #expect(refs[0].sources.map(\.kind) == ["description", "comment", "mrSearch"])
        #expect(await t.requests.filter { $0.url!.absoluteString.removingPercentEncoding!.contains("/projects/group/sub/app") }.count == 1)
        #expect(await t.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func resolvesSlashedBranchAndPrioritizesIssueAndAuthorCommits() async throws {
        let t = CodeTransport { request in
            let url = request.url!.absoluteString.removingPercentEncoding!
            if url.contains("/projects/group/app") { return (200, #"{"id":7,"name":"项目","path_with_namespace":"group/app"}"#) }
            if url.contains("/branches/") {
                if url.hasSuffix("feature/ABC-1") { return (200, #"{"name":"feature/ABC-1","commit":{"title":"最近提交"}}"#) }
                return (404, "{}")
            }
            if url.contains("/repository/commits?") { return (200, #"[{"id":"other","title":"其他改动","author_name":"李四"},{"id":"author","title":"修复","author_name":"张三"},{"id":"key","message":"修复 ABC-1","author_name":"李四"},{"id":"merge","title":"Merge branch main"}]"#) }
            return (200, "[]")
        }
        let refs = await CodeReferences.issue("ABC-1", texts: [IssueText(source: "comment", author: "张三", at: "2026-10-22T12:00:00+0800", html: "https://git.example.com/group/app/-/tree/feature/ABC-1/src/main.swift")], client: client(t))
        #expect(refs.first?.branch == "feature/ABC-1")
        #expect(refs.first?.commits.map(\.id) == ["key", "author", "other"])
    }
    @Test func keepsUnavailableAndExternalLinksReadable() async throws {
        let t = CodeTransport { _ in (404, "{}") }
        let refs = await CodeReferences.issue("ABC-1", texts: [IssueText(source: "description", html: "https://git.example.com/group/app/-/commit/abcdef1 https://other.example.com/group/app/-/tree/main")], client: client(t))
        #expect(refs.count == 2 && refs[0].sha == "abcdef1")
        #expect(refs[0].unavailable == "无法访问这个项目（没有权限或已删除）")
        #expect(refs[1].kind == "external")
        #expect(GitLabLinks.sameCommit("abcdef1", "abcdef123456"))
        #expect(!GitLabLinks.sameCommit("abc", "abcdef123456"))
    }
}
