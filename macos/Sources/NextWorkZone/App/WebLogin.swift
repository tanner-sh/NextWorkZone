import AppKit
import WebKit

/// 网页登录窗口：用户在应用内完成认证（2FA、SSO 等）后，取出会话 Cookie 交给应用层验证并保存。
/// 登录完成后窗口自动关闭，应用层发出会话变化事件。
@MainActor
enum WebLogin {
    private static var windows: [Service: LoginWindow] = [:]

    static func open(_ service: Service) {
        if let existing = windows[service] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        Task {
            do {
                let info = try await API.shared.webLoginInfo(service)
                guard let url = URL(string: info.url), let base = URL(string: info.baseUrl) else {
                    toast("地址无效：\(info.url)", error: true)
                    return
                }
                let login = LoginWindow(service: service, info: info, url: url, base: base)
                windows[service] = login
                login.show()
            } catch {
                toast("无法打开登录窗口：\(errorMessage(error))", error: true)
            }
        }
    }

    fileprivate static func closed(_ service: Service) {
        windows[service] = nil
    }

    fileprivate final class LoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
        let service: Service
        let base: URL
        let window: NSWindow
        let webView: WKWebView
        private var finished = false

        init(service: Service, info: WebLoginInfo, url: URL, base: URL) {
            self.service = service
            self.base = base
            let config = WKWebViewConfiguration()
            // 持久的数据存储：服务器记住的设备（例如 2FA 的“记住此设备”）下次仍然有效
            config.websiteDataStore = .default()
            if let script = info.autofill {
                config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 760), configuration: config)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            super.init()
            window.title = info.title
            window.contentView = webView
            window.isReleasedWhenClosed = false
            window.delegate = self
            webView.navigationDelegate = self
            webView.load(URLRequest(url: url))
        }

        func show() {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, let current = webView.url?.absoluteString else { return }
            let host = base.host()
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let header = cookies
                    .filter { c in
                        let d = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        return host.map { $0 == d || $0.hasSuffix("." + d) } ?? false
                    }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                Task { @MainActor in
                    guard !self.finished else { return }
                    if (try? await API.shared.webLoginFinish(self.service, url: current, cookie: header)) == true {
                        self.finished = true
                        ImageCache.shared.clearFailures()
                        self.window.close()
                    }
                }
            }
        }

        func windowWillClose(_ notification: Notification) {
            webView.stopLoading()
            WebLogin.closed(service)
        }
    }
}
