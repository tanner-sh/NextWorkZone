import Foundation
import Testing
import NWZCore
import NWZWiki

@Suite struct WikiClientTests {
    func client(_ t: OfflineTransport) -> WikiClient { WikiClient(rest: RESTClient(baseURL: "https://wiki.example.com/context", token: "test-token", http: HTTPClient(transport: t))) }
    func raw(_ s: String) throws -> JSONDocument { try JSONDocument(data: Data(s.utf8)) }

    @Test func workKinds() throws {
        func page(_ creator: String, _ version: Int, _ by: String, _ message: String) -> JSONDocument {
            JSONDocument(value: ["id":"9", "title":"设计", "history":["createdBy":["userKey":.string(creator)]], "version":["number":.number(Double(version)), "by":["userKey":.string(by)], "message":.string(message)]])
        }
        let a = WikiBrowse.work(page("me", 1, "me", ""), me: "me")
        #expect(a.kind == "create" && a.detail == "")
        #expect(WikiBrowse.work(page("other", 5, "me", "补充接口"), me: "me").detail == "第 5 版：补充接口")
        #expect(WikiBrowse.work(page("me", 3, "other", ""), me: "me").detail == "参与编辑")
    }
    @Test func tinyLinks() {
        #expect(WikiBrowse.decodeTiny("ew") == "123")
        #expect(WikiBrowse.decodeTiny("") == nil)
        #expect(WikiBrowse.decodeTiny("!!!") == nil)
    }
    @Test func decodesPathsAndNotificationKinds() {
        #expect(WikiBrowse.percentDecode("%E5%91%A8%E6%8A%A5+A") == "周报+A")
        #expect(WikiBrowse.percentDecode("abc%") == "abc%")
        #expect(WikiBrowse.stripHTML("<p>a&nbsp;<b>b</b></p>") == "a b")
        #expect(WikiBrowse.normalizeAction("", title: "张三 评论了 页面") == "comment")
    }
    @Test func paginatesAndResolvesTitles() async throws {
        let t = OfflineTransport([
            .response(200, #"{"results":[{"key":"B","name":"B","homepage":{"id":"2"}}],"_links":{"next":"next"}}"#),
            .response(200, #"{"results":[{"key":"A","name":"A"}]}"#),
            .response(200, #"{"results":[]}"#), .response(200, #"{"results":[{"id":"3"}]}"#),
        ]), wiki = client(t)
        #expect(try await wiki.spaces().map(\.key) == ["A", "B"])
        #expect(try await wiki.resolvePage("https://wiki.example.com/context/display/DEMO/周报+A") == "3")
        #expect(try await wiki.resolvePage("https://wiki.example.com/context/x/ew") == "123")
        let requests = await t.requests
        let queries = requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems! }
        #expect(queries[1].contains(URLQueryItem(name: "start", value: "1")))
        #expect(queries[2].contains(URLQueryItem(name: "title", value: "周报 A")))
        #expect(queries[3].contains(URLQueryItem(name: "type", value: "blogpost")))
    }
    @Test func saveRejectsStaleVersionWithoutWriting() async throws {
        let t = OfflineTransport([.response(200, #"{"id":"1","title":"页面","space":{"key":"DEMO"},"version":{"number":3,"by":{"displayName":"李四"}}}"#)])
        await #expect(throws: NWZError.self) { try await client(t).savePage("1", title: "页面", storage: "<p>新</p>", baseVersion: 2, minorEdit: true, message: "") }
        #expect(await t.requests.map(\.httpMethod) == ["GET"])
    }
    @Test func savesAndRejectsConcurrentConflictsOffline() async throws {
        let page = #"{"id":"1","title":"页面","space":{"key":"DEMO"},"version":{"number":2}}"#
        let t = OfflineTransport([.response(200, page), .response(200, "{}"), .response(200, page), .response(409, "{}")]), wiki = client(t)
        #expect(try await wiki.savePage("1", title: "新标题", storage: "<p>内容</p>", baseVersion: 2, minorEdit: false, message: "说明") == 3)
        await #expect(throws: NWZError.self) { try await wiki.savePage("1", title: "新标题", storage: "<p>内容</p>", baseVersion: 2, minorEdit: true, message: "") }
        let requests = await t.requests
        let body = try raw(String(decoding: #require(requests[1].httpBody), as: UTF8.self))
        #expect(body["version"]["number"].int == 3 && body["space"]["key"].text == "DEMO")
        #expect(body["version"]["minorEdit"].bool == false && body["title"].text == "新标题")
        #expect(body["body"]["storage"]["value"].text == "<p>内容</p>")
        #expect(requests.count == 4)
    }
    @Test func createsCommentsTasksAndAttachmentsOffline() async throws {
        let t = OfflineTransport([.response(200, #"{"id":"2"}"#), .response(200, #"{"id":"3"}"#), .response(200, "{}"), .response(200, "{}")]), wiki = client(t)
        #expect(try await wiki.createIn(space: "DEMO", parent: "1", title: "页面", storage: "<p>内容</p>") == "2")
        #expect(try await wiki.addComment("2", parent: "9", storage: "<p>评论</p>") == "3")
        try await wiki.setTaskStatus("2", task: "4", done: true)
        try await wiki.attach("2", filename: "图.png", mime: "image/png", data: Data([1, 2, 3]))
        let requests = await t.requests
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        let a = try raw(String(decoding: #require(requests[0].httpBody), as: UTF8.self))
        let b = try raw(String(decoding: #require(requests[1].httpBody), as: UTF8.self))
        #expect(a["ancestors"][0]["id"].text == "1" && b["ancestors"][0]["id"].text == "9")
        #expect(requests[2].url?.path.hasSuffix("/task/2/4") == true)
        #expect(requests[2].value(forHTTPHeaderField: "X-Atlassian-Token") == "no-check")
        #expect(requests[3].httpBody?.range(of: Data("图.png".utf8)) != nil)
    }
    @Test func searchEscapesUserInput() async throws {
        let t = OfflineTransport([.response(200, #"{"totalSize":1,"results":[{"content":{"id":"1","type":"page","title":"页"},"excerpt":"@@@hl@@@命中@@@endhl@@@"}]}"#)])
        let result = try await client(t).cqlSearch(WikiQuery(text: #"a"b\c"#, space: "DEMO", mine: true, days: 7, limit: 500), me: "me")
        #expect(result.total == 1 && result.hits.first?.snippet == "命中")
        let request = try #require(await t.requests.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.contains(URLQueryItem(name: "limit", value: "100")))
        #expect(items.first { $0.name == "cql" }?.value?.contains(#"siteSearch ~ "a\"b\\c""#) == true)
    }
}
