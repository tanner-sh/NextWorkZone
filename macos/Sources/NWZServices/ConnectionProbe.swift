import Foundation
import NWZCore

public enum ConnectionProbe {
    /// 三个系统都只查询当前用户与版本，命令行和设置页共用这一条只读路径。
    public static func check(_ service: Service, base: String, token: String, client: HTTPClient) async throws -> ConnectionInfo {
        func request(_ path: String) throws -> URLRequest {
            guard let url = URL(string: base + path), ["http", "https"].contains(url.scheme) else { throw NWZError.invalidURL(base) }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if service == .gitlab { request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN") }
            else { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
        let userPath: String = switch service { case .jira: "/rest/api/2/myself"; case .confluence: "/rest/api/user/current"; case .gitlab: "/api/v4/user" }
        let user = try await client.json(request(userPath), as: JSONValue.self)
        if service == .confluence && user["type"]?.string == "anonymous" { throw NWZError.unauthorized(401) }
        guard let username = user[service == .jira ? "name" : "username"]?.string,
              let displayName = user[service == .gitlab ? "name" : "displayName"]?.string else { throw NWZError.other("服务器未返回有效的账号信息") }
        let version: String?
        if service == .confluence {
            if let response = try? await client.send(request("/rest/applinks/1.0/manifest")),
               let xml = String(data: response.data, encoding: .utf8),
               let start = xml.range(of: "<version>"), let end = xml.range(of: "</version>", range: start.upperBound..<xml.endIndex) {
                version = String(xml[start.upperBound..<end.lowerBound])
            } else { version = nil }
            try Task.checkCancellation()
        } else {
            let info = try await client.json(request(service == .jira ? "/rest/api/2/serverInfo" : "/api/v4/version"), as: JSONValue.self)
            version = info["version"]?.string
            guard version != nil else { throw NWZError.other("服务器未返回有效的版本信息") }
        }
        return ConnectionInfo(service: service, username: username, displayName: displayName, serverVersion: version)
    }
}
