import Foundation
import Testing
import NWZCore
import NWZWiki

@Suite struct WikiIndexSyncTests {
    func client(_ t: OfflineTransport) -> WikiClient { WikiClient(rest: RESTClient(baseURL: "https://wiki.example.com", token: "test-token", http: HTTPClient(transport: t))) }
    let batch = #"{"totalSize":1,"results":[{"id":"1","title":"页面","type":"page","version":{"number":1,"when":"2026-10-22T10:00:00.000+08:00"},"body":{"storage":{"value":"<p>正文</p>"}}}]}"#
    @Test func shrinksBatchAndUsesIncrementalCursor() async throws {
        let t = OfflineTransport([.response(500, "{}"), .response(500, "{}"), .response(200, batch), .response(200, #"{"totalSize":1,"results":[{"id":"1"}]}"#), .response(200, #"{"totalSize":0,"results":[]}"#)])
        let index = try WikiIndex(), wiki = client(t), scope = WikiScope()
        #expect(try await index.sync(client: wiki, scope: scope, pause: .zero) == 1)
        #expect(try await index.sync(client: wiki, scope: scope, pause: .zero) == 0)
        let requests = await t.requests
        let queries = requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems! }
        #expect(queries.prefix(3).compactMap { $0.first { $0.name == "limit" }?.value } == ["50", "10", "1"])
        #expect(queries.last?.first { $0.name == "cql" }?.value?.contains("lastmodified >= now(\"-") == true)
        #expect(requests.count == 5)
        #expect(try await index.stats().count == 1)
    }
    @Test func doesNotRetryAuthorizationFailure() async throws {
        let t = OfflineTransport([.response(401, "{}")]), index = try WikiIndex()
        await #expect(throws: NWZError.self) { try await index.sync(client: client(t), scope: WikiScope(), pause: .zero) }
        #expect(await t.requests.count == 1)
    }
    @Test func incompleteIDListNeverPrunes() async throws {
        let t = OfflineTransport([.response(200, batch), .response(200, #"{"totalSize":1,"results":[]}"#)]), index = try WikiIndex()
        await #expect(throws: NWZError.self) { try await index.sync(client: client(t), scope: WikiScope(), pause: .zero) }
        #expect(try await index.stats().count == 1)
    }
    @Test func skipsAnUnparseablePageAndContinues() async throws {
        let first = batch.replacingOccurrences(of: #""totalSize":1"#, with: #""totalSize":3"#)
        let last = first.replacingOccurrences(of: #""id":"1""#, with: #""id":"3""#)
        let t = OfflineTransport([.response(200, first), .response(500, "{}"), .response(500, "{}"), .response(500, "{}"), .response(200, last), .response(200, #"{"totalSize":3,"results":[{"id":"1"},{"id":"2"},{"id":"3"}]}"#)])
        let index = try WikiIndex()
        #expect(try await index.sync(client: client(t), scope: WikiScope(), pause: .zero) == 2)
        #expect(try await index.stats().count == 2)
    }
}
