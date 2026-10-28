import Foundation
import Network

public struct HTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
    public let url: URL
    public init(data: Data, status: Int, headers: [String: String] = [:], url: URL) {
        self.data = data; self.status = status; self.headers = headers; self.url = url
    }
    public func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    public var contentType: String? { header("content-type") }
}

/// 上传进度。在 `UploadProgress.$report.withValue { … }` 中发出的带请求体的请求会报告已发送的比例
/// （0...1，大约每 1% 一次，回调可能来自任意线程）。
public enum UploadProgress {
    @TaskLocal public static var report: (@Sendable (Double) -> Void)?

    /// 依次上传多个部分（例如多个文件）：按各部分的大小把每次请求的进度换算成总进度。
    public static func sequence<T>(_ sizes: [Int64], isolation: isolated (any Actor)? = #isolation, _ body: (Int) async throws -> T) async throws -> [T] {
        let outer = report, total = Double(max(1, sizes.reduce(0, +)))
        var done: Int64 = 0, result: [T] = []
        for (index, size) in sizes.enumerated() {
            let base = Double(done), part = Double(size)
            var inner: (@Sendable (Double) -> Void)?
            if let outer { inner = { fraction in outer((base + fraction * part) / total) } }
            let value = try await $report.withValue(inner, operation: { try await body(index) }, isolation: isolation)
            result.append(value)
            done += size
        }
        return result
    }

    public static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// 传输可注入，以离线响应验证所有写入路径。
public struct HTTPClient: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport) { self.transport = transport }
    public init(proxy: String? = nil) throws { transport = try SessionTransport(proxy: proxy) }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        for attempt in 0...2 {
            try Task.checkCancellation()
            do {
                let response = try await transport.send(request)
                guard (200..<300).contains(response.status) else {
                    if response.status == 401 { throw NWZError.unauthorized(response.status) }
                    let message = httpErrorText(String(decoding: response.data, as: UTF8.self))
                    if response.status == 403 { throw NWZError.forbidden(message) }
                    throw NWZError.http(response.status, message)
                }
                return response
            } catch let error as URLError {
                let transient: Set<URLError.Code> = [.networkConnectionLost, .cannotConnectToHost, .timedOut, .cannotFindHost, .dnsLookupFailed]
                guard request.httpMethod == "GET", attempt < 2, transient.contains(error.code) else { throw error }
                try await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
            }
        }
        throw NWZError.other("请求未完成")
    }

    public func json<T: Decodable & Sendable>(_ request: URLRequest, as type: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(type, from: await send(request).data)
    }

    public func fetchBytes(_ request: URLRequest) async throws -> (Data, String?) {
        let response = try await send(request)
        return (response.data, response.contentType)
    }
}

public actor SessionTransport: HTTPTransport {
    private let proxy: String?
    private var session: URLSession
    /// 上传大文件用：整个请求的时限放宽到一小时
    private var uploadSession: URLSession?
    private var activeRequests = 0
    private var lastFinished = ContinuousClock.now
    private let redirectDelegate = RequestDelegate(progress: nil)

    public init(proxy: String?) throws {
        self.proxy = proxy
        session = URLSession(configuration: try Self.configuration(proxy: proxy))
    }

    deinit { session.invalidateAndCancel(); uploadSession?.invalidateAndCancel() }

    public static func configuration(proxy: String?) throws -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "NextWorkZone/0.1"]
        if let text = proxy?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard let url = URLComponents(string: text), let host = url.host, !host.isEmpty,
                  ["http", "https", "socks5", "socks5h"].contains(url.scheme ?? ""),
                  url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
                  let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : 1080)) ?? 0), port.rawValue > 0 else {
                throw NWZError.other("无效的代理地址，请使用 HTTP、HTTPS 或 SOCKS5 地址")
            }
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: port)
            let configuration = url.scheme?.hasPrefix("socks") == true
                ? ProxyConfiguration(socksv5Proxy: endpoint)
                : ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: url.scheme == "https" ? NWProtocolTLS.Options() : nil)
            if let username = url.user { configuration.applyCredential(username: username.removingPercentEncoding ?? username, password: url.password?.removingPercentEncoding ?? "") }
            config.proxyConfigurations = [configuration]
        }
        return config
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        // URLSession 没有公开的连接池空闲期限；空闲 15 秒后换会话，避免复用已被代理断开的连接。
        if activeRequests == 0 && lastFinished.duration(to: .now) >= .seconds(15) {
            session.finishTasksAndInvalidate()
            session = URLSession(configuration: try Self.configuration(proxy: proxy))
        }
        let current = session
        activeRequests += 1
        defer { activeRequests -= 1; lastFinished = .now }
        let data: Data, response: URLResponse
        if let progress = UploadProgress.report, let body = request.httpBody {
            if uploadSession == nil {
                let config = try Self.configuration(proxy: proxy)
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 3600
                uploadSession = URLSession(configuration: config)
            }
            var upload = request
            upload.httpBody = nil
            (data, response) = try await uploadSession!.upload(for: upload, from: body, delegate: RequestDelegate(progress: progress))
        } else {
            (data, response) = try await current.data(for: request, delegate: redirectDelegate)
        }
        guard let response = response as? HTTPURLResponse, let url = response.url else { throw NWZError.other("服务器响应不是 HTTP") }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let name = item.key as? String { result[name] = String(describing: item.value) }
        }
        return HTTPResponse(data: data, status: response.statusCode, headers: headers, url: url)
    }
}

private final class RequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var lastReported = -1.0

    init(progress: (@Sendable (Double) -> Void)?) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let progress, totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let report = lock.withLock {
            guard fraction - lastReported >= 0.01 || (fraction >= 1 && lastReported < 1) else { return false }
            lastReported = fraction
            return true
        }
        if report { progress(fraction) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // PRIVATE-TOKEN 等自定义头不会由系统自动保护，禁止带着它们跨站重定向。
        guard let source = task.originalRequest?.url, let destination = request.url,
              source.scheme == destination.scheme, source.host == destination.host, source.port == destination.port else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public func httpErrorText(_ body: String) -> String {
    let fallback = { let text = body.trimmingCharacters(in: .whitespacesAndNewlines); return String(text.prefix(300)) + (text.count > 300 ? "…" : "") }
    guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return fallback() }
    var messages = json["errorMessages"] as? [String] ?? []
    if let errors = json["errors"] as? [String: Any] {
        messages += errors.keys.sorted().map { "\($0)：\(errors[$0] as? String ?? "")" }
    }
    for key in ["message", "error"] {
        if let value = json[key] as? String { messages.append(value) }
        else if let value = json[key], !(value is NSNull), let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
            messages.append(String(decoding: data, as: UTF8.self))
        }
    }
    return messages.isEmpty ? fallback() : messages.joined(separator: "；")
}

public func isLoginRedirect(_ url: URL, base: String) -> Bool {
    let otherHost = URL(string: base).map { $0.host != url.host } ?? false
    return otherHost || ["login", "signin", "sign_in", "/sso", "/saml", "/cas/", "/oauth"].contains { url.path.lowercased().contains($0) }
}

public func mergeSetCookies(_ header: String, setCookies: [String]) -> String? {
    func pair(_ text: String) -> (String, String)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
    }
    var cookies = header.split(separator: ";").compactMap { pair(String($0)) }
    var changed = false
    for cookie in setCookies {
        guard let first = cookie.split(separator: ";").first, let (key, value) = pair(String(first)) else { continue }
        if let index = cookies.firstIndex(where: { $0.0 == key }) {
            if cookies[index].1 != value { cookies[index].1 = value; changed = true }
        } else { cookies.append((key, value)); changed = true }
    }
    return changed ? cookies.map { "\($0.0)=\($0.1)" }.joined(separator: "; ") : nil
}

public struct MultipartBody: Sendable {
    public let boundary: String
    private var parts = Data()
    public init() { boundary = "NWZ-" + UUID().uuidString }
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    public var data: Data { parts + Data("--\(boundary)--\r\n".utf8) }
    public mutating func append(name: String, filename: String? = nil, contentType: String? = nil, data: Data) throws {
        guard [name, filename, contentType].compactMap({ $0 }).allSatisfy({ !$0.utf8.contains(13) && !$0.utf8.contains(10) }) else { throw NWZError.other("上传字段不能包含换行") }
        func quote(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quote(name))\""
        if let filename { header += "; filename=\"\(quote(filename))\"" }
        header += "\r\n"
        if let contentType { header += "Content-Type: \(contentType)\r\n" }
        parts.append(Data((header + "\r\n").utf8)); parts.append(data); parts.append(Data("\r\n".utf8))
    }
}
