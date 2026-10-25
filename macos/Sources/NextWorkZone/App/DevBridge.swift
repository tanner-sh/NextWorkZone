#if DEBUG
import AppKit
import Network
import NWZCore
import NWZServices

/// 本机测试通道（只在开发构建中启动），用于自动化验证界面：切换页面、打开目标、读取当前状态。
///
/// 只监听 127.0.0.1:17891，请求需携带令牌（启动时写入缓存目录下的 `devbridge-swift.token`）：
///
/// ```sh
/// curl -s -H "x-token: $(cat ~/Library/Caches/NextWorkZone-dev/devbridge-swift.token)" \
///      'http://127.0.0.1:17891/nav?page=jira&issueKey=ABC-1'
/// ```
///
/// - `/nav?page=<页面>&<NavTarget 字段>=<值>`：跳转；
/// - `/state`：当前页面和窗口编号（截图用）；
/// - `/palette`、`/quick-todo`、`/capture`、`/clipboard`：打开对应的浮层或窗口；
/// - `/theme?mode=dark|light|system`：切换外观；
/// - `/key?chars=<文字>`：向主窗口发送按键（测试键盘操作）。
@MainActor
enum DevBridge {
    static func findEditor(_ view: NSView?) -> EditorTextView? {
        guard let view else { return nil }
        if let tv = view as? EditorTextView { return tv }
        for sub in view.subviews { if let tv = findEditor(sub) { return tv } }
        return nil
    }

    private static var listener: NWListener?

    static func start() {
        let token = String(UInt64.random(in: 0...UInt64.max), radix: 16)
        let dir = API.shared.settings.paths.cache
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? PrivateFile.write(Data(token.utf8), to: dir.appendingPathComponent("devbridge-swift.token"))
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 17891)
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            receive(conn, Data(), token: token)
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// 读完整个请求（请求头和 Content-Length 指定的正文）后处理。
    private nonisolated static func receive(_ conn: NWConnection, _ buffer: Data, token: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, _ in
            var all = buffer
            if let data { all.append(data) }
            let text = String(decoding: all, as: UTF8.self)
            if let headerEnd = text.range(of: "\r\n\r\n") {
                let head = String(text[..<headerEnd.lowerBound])
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let bodyStart = all.count - text[headerEnd.upperBound...].utf8.count
                if all.count - bodyStart >= length || done {
                    let body = all.count > bodyStart ? String(decoding: all[bodyStart...], as: UTF8.self) : ""
                    DispatchQueue.main.async { MainActor.assumeIsolated { respond(conn, head: head, body: body, token: token) } }
                    return
                }
            }
            if done { conn.cancel(); return }
            receive(conn, all, token: token)
        }
    }

    private static func respond(_ conn: NWConnection, head: String, body: String, token: String) {
        let send = { (body: String) in
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
        let line = head.components(separatedBy: "\r\n").first ?? ""
        // /call?cmd=<命令>&args=<JSON>，或 POST /call 正文 {"cmd":…,"args":{…}}：直接调用应用层命令（只读测试用）
        if head.components(separatedBy: "\r\n").contains(where: { $0.lowercased() == "x-token: \(token)" }), line.contains(" /call") {
            let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            var q = Dictionary((URLComponents(string: "http://x" + target)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
            if line.hasPrefix("POST"), let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
                q["cmd"] = obj["cmd"] as? String
                q["args"] = (obj["args"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            }
            Task { @MainActor in
                do {
                    let command = q["cmd"] ?? ""
                    guard ReadOnlyCommands.names.contains(command) else { throw APIError(message: "调试通道只允许只读命令") }
                    let args = try JSONDecoder().decode([String: JSONValue].self, from: Data((q["args"] ?? "{}").utf8))
                    send(String(decoding: try await API.shared.raw(command, args), as: UTF8.self))
                } catch {
                    send("{\"error\":\(String(reflecting: errorMessage(error)))}")
                }
            }
            return
        }
        send(handle(head, token: token))
    }

    private static func handle(_ request: String, token: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        guard lines.contains(where: { $0.lowercased() == "x-token: \(token)" }) else { return #"{"error":"token"}"# }
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let comps = URLComponents(string: "http://x" + target)
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let model = AppModel.shared
        switch comps?.path ?? "" {
        case "/nav":
            guard let page = query["page"].flatMap(PageID.init) else { return #"{"error":"page"}"# }
            var t = NavTarget(page)
            t.issueKey = query["issueKey"]
            t.projectId = query["projectId"].flatMap(Int.init)
            t.docId = query["docId"]
            t.todoId = query["todoId"]
            t.jql = query["jql"]
            t.wikiPage = query["wikiPage"]
            t.wikiSearch = query["wikiSearch"]
            t.projectPath = query["projectPath"]
            t.mrIid = query["mrIid"].flatMap(Int.init)
            t.gitRef = query["gitRef"]
            t.commitSha = query["commitSha"]
            t.tool = query["tool"]
            t.toolTab = query["toolTab"]
            t.searchQuery = query["searchQuery"]
            model.navigate(t)
        case "/palette": model.paletteOpen.toggle()
        case "/quick-todo": model.quickTodoOpen.toggle()
        case "/capture": CaptureWindow.shared.toggle()
        case "/clipboard": ClipboardPanel.shared.toggle()
        case "/theme":
            switch query["mode"] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        case "/wiki-edit":
            if let page = query["page"] {
                model.navigate(NavTarget(.wiki))
                NotificationCenter.default.post(name: Notification.Name("nwz.debug.wikiEdit"), object: page)
            }
        case "/wiki-roundtrip":
            // Wiki 编辑往返检查（只读）：结果写到 path
            if let page = query["page"], let path = query["path"] {
                let edit = query["edit"] == "1"
                Task { @MainActor in
                    let out: String
                    do {
                        let p = try await WikiPageEditor.debugRoundTrip(page: page, edit: edit)
                        let lines = p.diff.split(separator: "\n").filter { ($0.hasPrefix("+") || $0.hasPrefix("-")) && !$0.hasPrefix("+++") && !$0.hasPrefix("---") }.count
                        out = "{\"changed\":\(p.changed),\"diffLines\":\(lines),\"storageLength\":\(p.storage.count)}"
                    } catch {
                        out = "{\"error\":\(String(reflecting: errorMessage(error)))}"
                    }
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        case "/snapshot":
            // 把窗口内容画到图片（屏幕休眠时也能检查界面）：path=输出文件，title=窗口标题
            let title = query["title"] ?? "NextWorkZone"
            guard let path = query["path"], let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) ?? MainWindow.window,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "{\"error\":\"snapshot\"}" }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        case "/editor":
            // 编辑器测试：focus / type&chars= / key&code=&mods=cmd,shift / op&name= / dump
            guard let window = NSApp.keyWindow ?? MainWindow.window, let tv = findEditor(window.contentView) else { return "{\"error\":\"no editor\"}" }
            switch query["do"] {
            case "focus":
                window.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            case "type":
                tv.insertText(query["chars"] ?? "", replacementRange: tv.selectedRange())
            case "key":
                var flags: NSEvent.ModifierFlags = []
                let mods = query["mods"] ?? ""
                if mods.contains("cmd") { flags.insert(.command) }
                if mods.contains("shift") { flags.insert(.shift) }
                let code = UInt16(query["code"] ?? "0") ?? 0
                let chars = query["chars"] ?? ""
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    if !window.performKeyEquivalent(with: e) { tv.keyDown(with: e) }
                }
            case "op":
                tv.debugOp(query["name"] ?? "")
            case "dump":
                let doc = RichFlat.build(RichFlat.parse(tv.textStorage!).paras)
                let data = (try? JSONEncoder().encode(doc)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            default: break
            }
        case "/key":
            if let chars = query["chars"], let window = MainWindow.window {
                for ch in chars {
                    let s = String(ch)
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                            window.sendEvent(e)
                        }
                    }
                }
            }
        default: break
        }
        let windows = NSApp.windows.filter(\.isVisible).map { "{\"title\":\"\($0.title)\",\"number\":\($0.windowNumber)}" }.joined(separator: ",")
        return "{\"page\":\"\(model.current.page.rawValue)\",\"windows\":[\(windows)]}"
    }
}
#endif
