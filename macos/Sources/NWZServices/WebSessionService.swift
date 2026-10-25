import Foundation
import NWZCore

/// 访问附件、图片等网页路径的方式。
public enum WebAccess: String, Codable, Hashable, Sendable {
    /// Token 即可访问网页路径，无需网页登录。
    case token
    /// 已有有效的网页会话。
    case session
    /// 需要网页登录。
    case loginRequired
}

/// 打开登录窗口所需的信息：登录页地址，以及配置了网页登录账号时的自动填写脚本。
public struct WebLoginInfo: Codable, Hashable, Sendable {
    public var url: String
    /// 系统的地址，登录窗口离开登录页后到这个地址下取 Cookie。
    public var baseUrl: String
    public var title: String
    /// 在每个页面开始加载时注入的脚本。
    public var autofill: String?
}

/// 网页登录：附件、图片等网页路径不走 REST API，部分部署（例如启用了 2FA / SSO 插件）不接受 Token。
/// 这种情况下在应用内打开登录窗口，用户照常完成认证后，取出会话 Cookie 供下载附件、图片使用。
///
/// - 先用 Token 探测网页路径；能访问的部署不需要网页登录。
/// - 配置了网页登录账号时，登录窗口会自动填写账号密码并提交，用户只需完成额外的验证步骤。
/// - 后台定期用会话访问一次受保护页面（[`start`]），让会话保持活跃，并跟上轮换的 Cookie。
///
/// 会话 Cookie 保存在数据目录的 `web-sessions.json`（0600），与账号凭据分开：它会频繁轮换，
/// 放进钥匙串会反复写入。
public actor WebSessionService: WebResourceSource {
    /// 网页会话状态变化（登录成功、会话失效）时发出，载荷为服务名。
    public static let sessionEvent = "web-session"
    /// 会话保活的间隔。
    static let keepAliveInterval = Duration.seconds(10 * 60)
    /// 支持网页登录的系统（Atlassian 系的标准登录页）。
    public static let services: [Service] = [.jira, .confluence]

    private let settings: SettingsService
    private let host: any AppHost
    private let file: URL
    private var sessions: [String: String]
    /// 保存会话时各系统的地址；地址改了，旧会话就不再适用。
    private var bases: [Service: String] = [:]
    private var keepAlive: Task<Void, Never>?

    public init(settings: SettingsService, host: any AppHost) {
        self.settings = settings; self.host = host
        file = settings.paths.data.appendingPathComponent("web-sessions.json")
        sessions = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
        let config = settings.configuration.snapshot()
        for service in Self.services { bases[service] = try? config.baseURL(for: service) }
    }

    private static func key(_ service: Service) -> String { service.rawValue + "-session" }

    private func session(_ service: Service) -> String? { sessions[Self.key(service)] }

    private func setSession(_ service: Service, _ cookie: String?) {
        sessions[Self.key(service)] = cookie
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(sessions) { try? PrivateFile.write(data, to: file) }
    }

    private func emit(_ service: Service) { host.emit(ServiceEvent(Self.sessionEvent, payload: .string(service.rawValue))) }

    /// 登录页地址。
    static func loginPath(_ service: Service) throws -> String {
        switch service {
        case .jira: "/login.jsp?os_destination=%2Fsecure%2FViewProfile.jspa"
        case .confluence: "/login.action?os_destination=%2Fusers%2Fviewmyprofile.action"
        case .gitlab: throw NWZError.other("GitLab 不需要网页登录")
        }
    }

    /// 需要登录才能访问的网页（不是 REST API），用于判断凭据能否访问网页路径。
    static func probePath(_ service: Service) -> String { service == .confluence ? "/users/viewmyprofile.action" : "/secure/ViewProfile.jspa" }

    // MARK: 后台保活

    public func start() {
        guard keepAlive == nil else { return }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.keepAliveInterval) } catch { return }
                await self?.refreshSessions()
            }
        }
    }

    public func stop() { keepAlive?.cancel(); keepAlive = nil }

    /// 会话已失效时清除它并通知界面；网络错误则等下一轮再试。
    private func refreshSessions() async {
        for service in Self.services {
            guard let cookie = session(service) else { continue }
            switch await probe(service, cookie: cookie) {
            case .valid(let updated): if updated != cookie { setSession(service, updated) }
            case .invalid: setSession(service, nil); emit(service)
            case .unknown: break
            }
        }
    }

    /// 系统地址变化时丢掉对应的会话。
    public func configurationChanged() {
        let config = settings.configuration.snapshot()
        for service in Self.services {
            let base = try? config.baseURL(for: service)
            if base != bases[service], session(service) != nil { setSession(service, nil); emit(service) }
            bases[service] = base
        }
    }

    // MARK: 状态与登录

    /// 各系统访问附件、图片等网页路径的方式。
    public func accessStatus() async -> [String: WebAccess] {
        var result: [String: WebAccess] = [:]
        for service in Self.services {
            result[service.rawValue] = session(service) != nil ? .session : await tokenReachesWeb(service) ? .token : .loginRequired
        }
        return result
    }

    /// 用 Token 访问一次受保护网页，看是否被重定向到登录页。未配置或网络失败时视为不可访问。
    private func tokenReachesWeb(_ service: Service) async -> Bool {
        guard let rest = try? await settings.restClient(service) else { return false }
        return (try? await send(rest, service, path: Self.probePath(service), cookie: nil)) != nil
    }

    public func logout(_ service: Service) {
        setSession(service, nil)
        emit(service)
    }

    public func loginInfo(_ service: Service) async throws -> WebLoginInfo {
        let login = try Self.loginPath(service)
        let base = try settings.configuration.snapshot().baseURL(for: service)
        var autofill: String?
        if let username = await settings.secret(.webUsername, for: service), let password = await settings.secret(.webPassword, for: service) {
            autofill = Self.autofillScript(base: base, username: username, password: password)
        }
        return WebLoginInfo(url: base + login, baseUrl: base, title: "登录 \(service.label)（完成认证后窗口会自动关闭）", autofill: autofill)
    }

    /// 登录窗口中的页面加载完成（`url` 为当前地址）：还停在登录页时返回 false；
    /// 否则用窗口中的 Cookie（`cookie` 为 `name=value; ...`）访问受保护页面，有效时保存会话并通知界面，返回 true（可以关闭窗口）。
    public func loginFinish(_ service: Service, url: String, cookie: String) async throws -> Bool {
        let base = try settings.configuration.snapshot().baseURL(for: service)
        guard let current = URL(string: url), !isLoginRedirect(current, base: base), !cookie.isEmpty else { return false }
        guard case .valid(let updated) = await probe(service, cookie: cookie) else { return false }
        setSession(service, updated)
        bases[service] = base
        emit(service)
        return true
    }

    /// 登录页的自动填写脚本：填入账号密码、勾选“记住我”后提交。
    ///
    /// 只在本系统的页面上生效；每个登录窗口只自动提交一次，密码错误时停在登录页由用户处理，
    /// 避免反复提交导致账号被锁。
    static func autofillScript(base: String, username: String, password: String) -> String {
        let origin = URL(string: base).flatMap { url -> String? in
            guard let scheme = url.scheme, let host = url.host else { return nil }
            return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        } ?? ""
        func quote(_ text: String) -> String {
            String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        }
        return """
        (function () {
          if (window.location.origin !== \(quote(origin))) return;
          function fill() {
            var user = document.querySelector('input[name="os_username"]');
            var pass = document.querySelector('input[name="os_password"]');
            if (!user || !pass) return;
            var set = function (input, value) {
              input.value = value;
              input.dispatchEvent(new Event('input', { bubbles: true }));
              input.dispatchEvent(new Event('change', { bubbles: true }));
            };
            set(user, \(quote(username)));
            set(pass, \(quote(password)));
            var remember = document.querySelector('input[name="os_cookie"]');
            if (remember) remember.checked = true;
            var key = 'nextworkzone-autofill-submitted';
            if (window.sessionStorage.getItem(key)) return;
            window.sessionStorage.setItem(key, '1');
            var form = pass.form;
            var submit = form && form.querySelector('[type="submit"]');
            if (submit) submit.click(); else if (form) form.submit();
          }
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fill);
          else fill();
        })();
        """
    }

    // MARK: 取回网页资源

    private enum Probe { case valid(String), invalid, unknown }

    /// 用会话访问受保护页面：有效时返回（合并了新 Cookie 的）会话；网络错误时无法判断。
    private func probe(_ service: Service, cookie: String) async -> Probe {
        guard let rest = try? await settings.restClient(service) else { return .unknown }
        do {
            let response = try await send(rest, service, path: Self.probePath(service), cookie: cookie)
            return .valid(Self.mergedCookie(cookie, response: response) ?? cookie)
        } catch NWZError.sessionRequired {
            return .invalid
        } catch {
            return .unknown
        }
    }

    /// 发出请求：有 `cookie` 时只带 Cookie，否则带 Token。
    /// 凭据不会随跨站重定向发出（见 [`SessionTransport`]），被重定向到其他主机（单点登录页）时按需要网页登录处理。
    private func send(_ rest: RESTClient, _ service: Service, path: String, cookie: String?) async throws -> HTTPResponse {
        var request = try rest.request("GET", path)
        if let cookie {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let response: HTTPResponse
        do {
            response = try await rest.http.send(request)
        } catch NWZError.http(let status, _) where (300..<400).contains(status) {
            throw NWZError.sessionRequired(service)
        }
        if service != .gitlab, isLoginRedirect(response.url, base: rest.baseURL) { throw NWZError.sessionRequired(service) }
        return response
    }

    private static func mergedCookie(_ cookie: String, response: HTTPResponse) -> String? {
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: response.headers, for: response.url)
        return mergeSetCookies(cookie, setCookies: cookies.map { "\($0.name)=\($0.value)" })
    }

    /// 下载系统内的网页资源（附件、图片）。
    ///
    /// 有网页会话时使用会话 Cookie，否则先用 Token 尝试（很多部署下 Token 就能访问网页路径）；
    /// 会话失效（被重定向到登录页）时清除会话并抛出 [`NWZError.sessionRequired`]。
    /// GitLab 没有这一限制，直接使用 Token。
    public func fetch(service: Service, url: String) async throws -> (Data, String?) {
        let rest = try await settings.restClient(service)
        let cookie = service == .gitlab ? nil : session(service)
        let response: HTTPResponse
        do {
            response = try await send(rest, service, path: url, cookie: cookie)
        } catch NWZError.sessionRequired where cookie != nil {
            setSession(service, nil); emit(service)
            throw NWZError.sessionRequired(service)
        }
        if let cookie, let updated = Self.mergedCookie(cookie, response: response) { setSession(service, updated) }
        return (response.data, response.contentType)
    }
}
