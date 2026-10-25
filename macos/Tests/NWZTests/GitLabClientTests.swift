import Foundation
import Testing
import NWZCore
import NWZGitLab

private actor GitLabTransport: HTTPTransport {
    var replies: [(String, [String: String])]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [(String, [String: String])]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw NWZError.other("离线响应不足") }
        let (text, headers) = replies.removeFirst()
        return HTTPResponse(data: Data(text.utf8), status: 200, headers: headers, url: request.url!)
    }
}
@Suite struct GitLabClientTests {
    func client(_ transport: any HTTPTransport) -> GitLabClient { GitLabClient(rest: RESTClient(baseURL: "https://git.example.com/team", token: "test-token", authorizationHeader: "PRIVATE-TOKEN", http: HTTPClient(transport: transport))) }
    @Test func paginationUsesCaseInsensitiveHeadersAndStopsRepeatedPage() async throws {
        let transport = GitLabTransport([("[{\"id\":1}]", ["X-Next-Page":"2"]), ("[{\"id\":2}]", ["x-next-page":"2"])])
        let projects = try await client(transport).projects(limit: 3)
        #expect(projects.map(\.id) == [1, 2])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[1].url?.absoluteString.contains("page=2") == true)
        #expect(requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN") == "test-token")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }
    @Test func encodesNestedProjectAndBranchAsIndividualSegments() async throws {
        let t = GitLabTransport([("{}", [:]), ("{}", [:])]), c = client(t)
        _ = try await c.project(path: "group/sub/app")
        _ = try await c.branch(7, name: "feature/ABC-1")
        let urls = await t.requests.compactMap { $0.url?.absoluteString }
        #expect(urls[0] == "https://git.example.com/team/api/v4/projects/group%2Fsub%2Fapp")
        #expect(urls[1].hasSuffix("/branches/feature%2FABC%2D1"))
    }
    @Test func oversizedFileStopsAfterHEADAndChecksGETAgain() async throws {
        let head = GitLabTransport([("", ["X-Gitlab-Size":"3000000"])])
        #expect(try await client(head).file(7, ref: "main", path: "a.bin").tooLarge)
        #expect(await head.requests.map(\.httpMethod) == ["HEAD"])
        let changed = GitLabTransport([("", [:]), (#"{"size":3000000,"content":""}"#, [:])])
        #expect(try await client(changed).file(7, ref: "main", path: "a.bin").tooLarge)
    }
    @Test func decodesTextImageAndBinaryFiles() async throws {
        for (path, data, text, binary, image) in [("a.swift", Data("文字".utf8), true, false, false), ("a.bin", Data([0, 1]), false, true, false), ("a.dat", Data([255]), false, true, false), ("a.PNG", Data([1, 2]), false, false, true)] {
            let raw: JSONValue = ["size": .number(Double(data.count)), "content": .string(data.base64EncodedString())]
            let t = GitLabTransport([("", [:]), (String(decoding: try JSONEncoder().encode(raw), as: UTF8.self), [:])])
            let file = try await client(t).file(7, ref: "main", path: path)
            #expect((file.text != nil) == text && file.binary == binary && (file.imageDataUrl != nil) == image)
        }
    }
    @Test func commentReplyEditResolveAndDeleteStayOffline() async throws {
        let t = OfflineTransport(Array(repeating: .response(200, "{}"), count: 6)), c = client(t)
        _ = try await c.mrAddNote("group/sub/app", iid: 42, body: "普通评论")
        _ = try await c.mrAddNote("group/sub/app", iid: 42, body: "行内评论", position: NotePosition(baseSha: "base", startSha: "start", headSha: "head", oldPath: "old.swift", newPath: "new.swift", newLine: 12))
        _ = try await c.mrReply("7", iid: 42, discussion: "discussion/id", body: "回复")
        _ = try await c.mrEditNote("7", iid: 42, note: 2, body: "修订")
        _ = try await c.mrResolve("7", iid: 42, discussion: "discussion/id", resolved: true)
        try await c.mrDeleteNote("7", iid: 42, note: 2)
        let requests = await t.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "POST", "PUT", "PUT", "DELETE"])
        let body = try JSONDocument(data: #require(requests[1].httpBody))
        #expect(body["position"]["new_line"].int == 12 && body["position"]["old_line"].isNull && body["position"]["position_type"].text == "text")
        #expect(requests[2].url?.absoluteString.contains("discussion%2Fid/notes") == true)
        #expect(requests[4].url?.query == "resolved=true")
    }
    @Test func approvalMergeCreateAndUpdateEncodeOnlySelectedFields() async throws {
        let t = OfflineTransport(Array(repeating: .response(200, "{}"), count: 7)), c = client(t)
        _ = try await c.mrApprove("7", iid: 42, approve: true)
        _ = try await c.mrApprove("7", iid: 42, approve: false)
        _ = try await c.mrMerge("7", iid: 42, options: MergeOptions(squash: true, removeSourceBranch: false, sha: "abcdef1"))
        _ = try await c.mrUpdate("7", iid: 42, update: MrUpdate(description: "", stateEvent: "close", squash: false))
        _ = try await c.mrCreate("7", input: NewMergeRequest(sourceBranch: "feature/ABC-1", targetBranch: "main", title: "修复导出", description: "说明", removeSourceBranch: true, squash: false))
        let requests = await t.requests
        #expect(requests.map(\.httpMethod) == ["POST", "GET", "POST", "GET", "PUT", "PUT", "POST"])
        let merge = try JSONDocument(data: #require(requests[4].httpBody)), update = try JSONDocument(data: #require(requests[5].httpBody)), create = try JSONDocument(data: #require(requests[6].httpBody))
        #expect(merge["sha"].text == "abcdef1" && merge["should_remove_source_branch"].bool == false)
        #expect(Set(update.keys) == ["description", "state_event", "squash"] && update["description"].string == "")
        #expect(create["source_branch"].text == "feature/ABC-1" && create["remove_source_branch"].bool == true)
    }
}
