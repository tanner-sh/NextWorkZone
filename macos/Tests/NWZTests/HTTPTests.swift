import Foundation
import Testing
@testable import NWZCore

actor OfflineTransport: HTTPTransport {
    enum Reply: Sendable { case response(Int, String), failure(URLError.Code) }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw NWZError.other("离线响应不足") }
        switch replies.removeFirst() {
        case .failure(let code): throw URLError(code)
        case .response(let status, let text): return HTTPResponse(data: Data(text.utf8), status: status, url: request.url!)
        }
    }
}

struct HTTPTests {
    private func request(_ method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.com/api")!)
        request.httpMethod = method
        return request
    }
    @Test func retriesOnlyGETTransportFailures() async throws {
        let transport = OfflineTransport([.failure(.networkConnectionLost), .failure(.timedOut), .response(200, "ok")])
        let client = HTTPClient(transport: transport)
        #expect(try await client.send(request("GET")).data == Data("ok".utf8))
        #expect(await transport.requests.count == 3)
        for method in ["POST", "PUT", "DELETE", "PATCH"] {
            let transport = OfflineTransport([.failure(.networkConnectionLost), .response(200, "ok")])
            await #expect(throws: URLError.self) { try await HTTPClient(transport: transport).send(request(method)) }
            #expect(await transport.requests.count == 1)
        }
    }
    @Test func doesNotRetryServerErrorsOrCancellation() async throws {
        let transport = OfflineTransport([.response(500, #"{"message":"失败"}"#)])
        await #expect(throws: NWZError.http(500, "失败")) { try await HTTPClient(transport: transport).send(request("GET")) }
        #expect(await transport.requests.count == 1)
        let cancelled = OfflineTransport([.failure(.cancelled)])
        await #expect(throws: URLError.self) { try await HTTPClient(transport: cancelled).send(request("GET")) }
        #expect(await cancelled.requests.count == 1)
    }
    @Test func reportsStructuredErrors() {
        #expect(httpErrorText(#"{"errorMessages":["无效"],"errors":{"summary":"不能为空"}}"#) == "无效；summary：不能为空")
        #expect(httpErrorText(#"{"message":"无权限"}"#) == "无权限")
        #expect(httpErrorText(String(repeating: "字", count: 400)).count == 301)
    }
    @Test func supportsSystemAndExplicitProxies() throws {
        #expect(try SessionTransport.configuration(proxy: nil).proxyConfigurations.isEmpty)
        for proxy in ["http://127.0.0.1:7890", "https://proxy.example.com", "socks5://127.0.0.1:1080", "socks5h://user:pass@proxy.example.com"] {
            #expect(try SessionTransport.configuration(proxy: proxy).proxyConfigurations.count == 1)
        }
        for proxy in ["bad", "ftp://example.com", "http://example.com:99999", "http://example.com/path"] {
            #expect(throws: NWZError.self) { try SessionTransport.configuration(proxy: proxy) }
        }
    }
    @Test func encodesMultipartWithoutChangingBinaryData() throws {
        var body = MultipartBody()
        try body.append(name: "file", filename: "说明.txt", contentType: "text/plain", data: Data([0, 255, 1]))
        #expect(body.data.range(of: Data([0, 255, 1])) != nil)
        #expect(body.data.suffix(Data("--\(body.boundary)--\r\n".utf8).count) == Data("--\(body.boundary)--\r\n".utf8))
        #expect(throws: NWZError.self) { try body.append(name: "bad\r\nheader", data: Data()) }
    }
}
