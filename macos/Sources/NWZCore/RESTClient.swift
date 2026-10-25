import Foundation
import CryptoKit

public struct RESTClient: Sendable {
    public let baseURL: String
    private let token: String
    private let authorizationHeader: String
    public let http: HTTPClient
    public var cacheIdentity: String { SHA256.hash(data: Data((baseURL + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined() }
    public init(baseURL: String, token: String, authorizationHeader: String = "Authorization", http: HTTPClient) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")); self.token = token; self.authorizationHeader = authorizationHeader; self.http = http
    }
    public func request(_ method: String = "GET", _ path: String, query: [(String, String)] = [], body: JSONValue? = nil) throws -> URLRequest {
        let target = path.hasPrefix("https://") || path.hasPrefix("http://") ? path : baseURL + (path.hasPrefix("/") ? path : "/" + path)
        guard let base = URL(string: baseURL), var components = URLComponents(string: target), let url = components.url,
              url.scheme == base.scheme, url.host?.lowercased() == base.host?.lowercased(), url.port == base.port,
              ["https", "http"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { throw NWZError.invalidURL(target) }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let finalURL = components.url else { throw NWZError.invalidURL(target) }
        var request = URLRequest(url: finalURL); request.httpMethod = method
        request.setValue(authorizationHeader == "Authorization" ? "Bearer " + token : token, forHTTPHeaderField: authorizationHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    public func response(_ method: String = "GET", _ path: String, query: [(String, String)] = [], body: JSONValue? = nil) async throws -> HTTPResponse {
        try await http.send(request(method, path, query: query, body: body))
    }
    public func json(_ method: String = "GET", _ path: String, query: [(String, String)] = [], body: JSONValue? = nil) async throws -> JSONDocument {
        let response = try await response(method, path, query: query, body: body)
        return response.data.isEmpty ? .null : try JSONDocument(data: response.data)
    }
    public static func component(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}
