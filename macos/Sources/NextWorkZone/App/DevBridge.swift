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
/// - `/state`：当前页面、窗口编号（截图用）和上一次 /nav 后新页面排好版（layoutMs）、提交到屏幕（commitMs）的毫秒数；
/// - `/palette`、`/quick-todo`、`/capture`、`/clipboard`：打开对应的浮层或窗口；
/// - `/theme?mode=dark|light|system`：切换外观；
/// - `/key?chars=<文字>`：向主窗口发送按键（测试键盘操作）。
/// - `/hit?x=&y=`：主窗口中某点（窗口坐标，左上角为原点）所在的视图及其各级上层（排查绘制问题）。
/// - `/menu[?path=菜单/项目]`：列出菜单栏项目，或执行某项（按标题前缀匹配）。
/// - `/click?x=&y=[&button=right][&count=2][&move=1]`、`/type?text=`、`/press?key=&mods=`：点击、输入文字、按键（屏幕锁定时也能操作窗口）。
/// - `/day[?set=yyyy-MM-dd]`：模拟过了零点（换掉应用的“今天”）。
/// - `/toast[?tap=1]`：当前的提示，或点提示中的按钮（例如“撤销”）。
/// - `/undo[?do=undo|redo]`：主窗口撤销记录中的操作名，或执行一步。
/// - `/responder`：键盘焦点所在的视图及其各级上层；`/focus-at?x=&y=`：让某点所在的列表等视图获得焦点。
@MainActor
enum DevBridge {
    static func findEditor(_ view: NSView?) -> EditorTextView? {
        guard let view else { return nil }
        if let tv = view as? EditorTextView { return tv }
        for sub in view.subviews { if let tv = findEditor(sub) { return tv } }
        return nil
    }

    /// 视图及其下层的悬停提示和读屏标签（SwiftUI 工具栏项目没有 label，按这些找）
    static func helpTexts(_ view: NSView) -> [String] {
        var list = [view.toolTip, view.accessibilityLabel()].compactMap { $0 }.filter { !$0.isEmpty }
        for sub in view.subviews { list += helpTexts(sub) }
        return list
    }

    private static var listener: NWListener?
    private static var lastCommitMs: Double = 0
    private static var lastLayoutMs: Double = 0
    private static var navStart: CFTimeInterval?

    /// 保留的页面显示出来后第一次排版完成（见 KeptPages.PageHost.layout）。
    static func pageLaidOut() {
        guard let start = navStart, lastLayoutMs < 0 else { return }
        lastLayoutMs = (CACurrentMediaTime() - start) * 1000
    }

    /// 主窗口出现后开始记录：窗口每次绘制后检查，新页面排好版后的第一次绘制就是切换后看到的第一帧（同一次刷新随即提交到屏幕）。
    /// 窗口由 SwiftUI 创建，不能用子类：给窗口所属的类补上 displayIfNeeded 的改写（只在开发构建中）。
    /// 不能给窗口换成运行时创建的子类，SwiftUI 之后对窗口做键值观察时会崩溃。
    static func windowReady(_ window: NSWindow) {
        guard !hooked, let cls = NSClassFromString(window.className) else { return }
        hooked = true
        let sel = #selector(NSWindow.displayIfNeeded)
        typealias Display = @convention(c) (NSWindow, Selector) -> Void
        let original = unsafeBitCast(class_getMethodImplementation(cls, sel), to: Display.self)
        let block: @convention(block) (NSWindow) -> Void = { window in
            original(window, sel)
            MainActor.assumeIsolated { displayed() }
        }
        let imp = imp_implementationWithBlock(block)
        let method = class_getInstanceMethod(cls, sel)!
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
    }

    private static var hooked = false

    private static func displayed() {
        guard let start = navStart, lastLayoutMs >= 0 else { return }
        navStart = nil
        lastCommitMs = (CACurrentMediaTime() - start) * 1000
    }

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
            // 从跳转到新页面第一次排好版的时间（/state 的 commitMs，随后同一次刷新就提交到屏幕）：衡量切换页面时看到新内容要等多久
            lastCommitMs = -1
            lastLayoutMs = -1
            navStart = CACurrentMediaTime()
            model.navigate(t)
        case "/palette": model.paletteOpen.toggle()
        // /image?src=<地址>&service=jira：打开图片查看器
        case "/image": if let src = query["src"] { ImageViewer.show(src: src, service: Service(rawValue: query["service"] ?? "") ?? .jira, alt: "") }
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
            // 把窗口内容画到图片（屏幕休眠时也能检查界面）：path=输出文件，title=窗口标题（默认主窗口）
            // 不指定标题时为主窗口（主窗口的标题随页面变化）
            let window = query["title"].flatMap { title in NSApp.windows.first { $0.title == title && $0.isVisible } } ?? MainWindow.window
            guard let path = query["path"], let window,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "{\"error\":\"snapshot\"}" }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        case "/scroll":
            // 滚动主窗口中某点（窗口坐标，左上角为原点）所在的滚动区：dy 为向下滚动的点数
            guard let window = MainWindow.window, let root = window.contentView,
                  let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init) else { return #"{"error":"scroll"}"# }
            let point = NSPoint(x: x, y: root.bounds.height - y)
            guard let scroll = root.hitTest(point)?.enclosingScrollView else { return #"{"error":"no scroll view"}"# }
            let clip = scroll.contentView
            var origin = clip.bounds.origin
            origin.y += CGFloat(Double(query["dy"] ?? "200") ?? 200) * (clip.isFlipped ? 1 : -1)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        case "/wheel":
            // 模拟鼠标滚轮在横向滚动区上纵向滚动（合成的滚轮事件送不进应用）：x、y 为屏幕坐标（左上角为原点），dy 为点数
            let point = NSPoint(x: Double(query["x"] ?? "") ?? 0, y: (NSScreen.screens.first?.frame.height ?? 0) - (Double(query["y"] ?? "") ?? 0))
            guard let window = NSApp.windows.filter({ $0.isVisible && $0.frame.contains(point) }).max(by: { $0.level.rawValue < $1.level.rawValue }) else { return #"{"error":"no window"}"# }
            let done = VerticalWheelScrollsHorizontally.scroll(in: window, at: window.convertPoint(fromScreen: point), dy: CGFloat(Double(query["dy"] ?? "-90") ?? -90))
            return "{\"scrolled\":\(done)}"
        case "/hit":
            guard let window = MainWindow.window, let root = window.contentView?.superview,
                  let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init) else { return "{}" }
            var v = root.hitTest(NSPoint(x: x, y: root.bounds.height - y))
            var chain: [String] = []
            while let cur = v { chain.append("\(type(of: cur)) \(cur.frame)"); v = cur.superview }
            return String(data: (try? JSONSerialization.data(withJSONObject: chain)) ?? Data(), encoding: .utf8) ?? "[]"
        case "/toolbar":
            // 主窗口工具栏当前的项目（检查切换页面后工具栏是否跟着变化）；press=<标题> 点击显示着的那一项
            if let label = query["press"], let window = MainWindow.window,
               let item = window.toolbar?.items.first(where: { !$0.isHidden && ($0.label == label || $0.itemIdentifier.rawValue == label || $0.view.map { Self.helpTexts($0) }?.contains(label) == true) }), let view = item.view {
                let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(e)
                    }
                }
            }
            let items = MainWindow.window?.toolbar?.items.map { item in
                ["id": item.itemIdentifier.rawValue, "label": item.label, "hidden": item.isHidden ? "1" : "0", "help": item.view.map { Self.helpTexts($0).joined(separator: "|") } ?? "", "frame": item.view.map { "\($0.convert($0.bounds, to: nil))" } ?? ""]
            } ?? []
            let title = MainWindow.window.map { ["title": $0.title, "subtitle": $0.subtitle] } ?? [:]
            return String(data: (try? JSONSerialization.data(withJSONObject: ["items": items, "window": title])) ?? Data(), encoding: .utf8) ?? "{}"
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
            case "responder":
                // 键盘焦点和“粘贴”菜单命令的去向
                let target = NSApp.target(forAction: #selector(NSText.paste(_:)), to: nil, from: nil)
                var info: [String: String] = ["editorWindow": String(window.windowNumber)]
                info["keyWindow"] = NSApp.keyWindow.map { String(describing: type(of: $0)) + " " + String($0.windowNumber) } ?? "nil"
                info["firstResponder"] = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                info["pasteTarget"] = target.map { String(describing: type(of: $0)) } ?? "nil"
                info["dragTypes"] = tv.registeredDraggedTypes.map(\.rawValue).joined(separator: ",")
                info["frame"] = "\(tv.convert(tv.bounds, to: nil))"
                return String(data: (try? JSONSerialization.data(withJSONObject: info)) ?? Data(), encoding: .utf8) ?? "{}"
            case "dump":
                let doc = RichFlat.build(RichFlat.parse(tv.textStorage!).paras)
                let data = (try? JSONEncoder().encode(doc)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            default: break
            }
        case "/click":
            // 在主窗口中点击（窗口坐标，左上角为原点；/snapshot 的像素除以缩放倍数）：button=right 右键，count=2 双击，move=1 只移动鼠标（悬停）
            guard let window = MainWindow.window, let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init) else { return "{}" }
            // 应用在后台时窗口不是主窗口，点击不会让输入框获得焦点
            if !window.isKeyWindow { NSApp.activate(); window.makeKeyAndOrderFront(nil) }
            let point = NSPoint(x: x, y: window.frame.height - y)
            let right = query["button"] == "right"
            func post(_ type: NSEvent.EventType, _ count: Int) {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                    NSApp.sendEvent(e)
                }
            }
            if query["move"] != nil {
                post(.mouseMoved, 0)
            } else {
                for i in 1...(Int(query["count"] ?? "1") ?? 1) {
                    post(right ? .rightMouseDown : .leftMouseDown, i)
                    post(right ? .rightMouseUp : .leftMouseUp, i)
                }
            }
            return "{\"width\":\(window.frame.width),\"height\":\(window.frame.height)}"
        case "/type":
            // 向键盘焦点输入文字（含中文）
            if let text = query["text"], let responder = (NSApp.keyWindow ?? MainWindow.window?.attachedSheet ?? MainWindow.window)?.firstResponder as? NSTextInputClient {
                responder.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case "/press":
            // 按键：key=return|delete|escape|tab|up|down 或单个字符，mods=cmd,shift,option,ctrl（菜单快捷键也经过这里）
            guard let key = query["key"] else { return "{}" }
            let codes: [String: (UInt16, String)] = ["return": (36, "\r"), "delete": (51, "\u{7f}"), "escape": (53, "\u{1b}"), "tab": (48, "\t"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}")]
            let (code, chars) = codes[key] ?? (0, key)
            var flags: NSEvent.ModifierFlags = []
            for m in (query["mods"] ?? "").split(separator: ",") {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "option": flags.insert(.option); case "ctrl": flags.insert(.control); default: break }
            }
            let window = NSApp.keyWindow ?? MainWindow.window?.attachedSheet ?? MainWindow.window
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(e)
                }
            }
        case "/undo":
            // 主窗口的撤销记录：do=undo|redo 执行一步；返回当前可撤销、可重做的操作名
            let manager = MainWindow.window?.undoManager
            switch query["do"] {
            case "undo": if manager?.canUndo == true { manager?.undo() }
            case "redo": if manager?.canRedo == true { manager?.redo() }
            default: break
            }
            let info = ["undo": manager?.canUndo == true ? manager!.undoActionName : "", "redo": manager?.canRedo == true ? manager!.redoActionName : ""]
            return String(data: (try? JSONSerialization.data(withJSONObject: info)) ?? Data(), encoding: .utf8) ?? "{}"
        case "/day":
            // 模拟日期变化（过了零点）：set=yyyy-MM-dd 把应用的“今天”换成这一天，不带参数恢复
            model.today = query["set"] ?? Fmt.today()
        case "/toast":
            // 当前的提示（窗口不在前台时不显示，在这里读）；tap=1 点最后一条提示中的按钮
            if query["tap"] != nil, let item = Toasts.shared.items.last(where: { $0.action != nil }) {
                Toasts.shared.dismiss(item.id)
                item.action?.run()
            }
            let list = Toasts.shared.items.map { ["message": $0.message, "action": $0.action?.label ?? ""] }
            return String(data: (try? JSONSerialization.data(withJSONObject: list)) ?? Data(), encoding: .utf8) ?? "[]"
        case "/responder":
            // 键盘焦点：主窗口的第一响应者及其各级上层
            var chain: [String] = []
            var r: NSResponder? = NSApp.keyWindow?.firstResponder
            while let cur = r, chain.count < 12 { chain.append(String(describing: type(of: cur))); r = cur.nextResponder }
            return String(data: (try? JSONSerialization.data(withJSONObject: chain)) ?? Data(), encoding: .utf8) ?? "[]"
        case "/focus-at":
            // 某点所在视图向上第一个能获得焦点的视图，以及让它成为第一响应者的结果
            guard let window = MainWindow.window, let root = window.contentView?.superview,
                  let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init) else { return "{}" }
            var v = root.hitTest(NSPoint(x: x, y: root.bounds.height - y))
            var info: [String] = []
            while let cur = v {
                if cur is NSTableView || cur.acceptsFirstResponder {
                    info.append("\(type(of: cur)) accepts=\(cur.acceptsFirstResponder) make=\(window.makeFirstResponder(cur))")
                    break
                }
                v = cur.superview
            }
            return String(data: (try? JSONSerialization.data(withJSONObject: info)) ?? Data(), encoding: .utf8) ?? "[]"
        case "/menu":
            // 菜单栏：列出各菜单的项目（标题、快捷键、是否可用）；path=菜单/项目 时执行该项目
            NSApp.mainMenu?.update()
            if let path = query["path"]?.components(separatedBy: "/"), path.count == 2,
               let menu = NSApp.mainMenu?.items.first(where: { $0.title == path[0] })?.submenu,
               case _ = menu.delegate?.menuNeedsUpdate?(menu),
               let index = menu.items.firstIndex(where: { $0.title == path[1] }) ?? menu.items.firstIndex(where: { $0.title.hasPrefix(path[1]) }) {
                menu.performActionForItem(at: index)
                return "{\"performed\":true}"
            }
            func list(_ menu: NSMenu) -> [Any] {
                // SwiftUI 在菜单打开前才更新菜单内容
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                return menu.items.map { item -> Any in
                    if item.isSeparatorItem { return "—" }
                    var key = item.keyEquivalent
                    if !key.isEmpty {
                        let m = item.keyEquivalentModifierMask
                        key = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + key
                    }
                    let label = item.title + (key.isEmpty ? "" : " [\(key)]") + (item.isEnabled ? "" : " (不可用)") + (item.state == .on ? " ✓" : "")
                    if let sub = item.submenu, query["deep"] == "1" || menu === NSApp.mainMenu { return [label: list(sub)] }
                    return label
                }
            }
            return String(data: (try? JSONSerialization.data(withJSONObject: NSApp.mainMenu.map(list) ?? [], options: [.prettyPrinted])) ?? Data(), encoding: .utf8) ?? "[]"
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
        return "{\"page\":\"\(model.current.page.rawValue)\",\"layoutMs\":\(Int(lastLayoutMs)),\"commitMs\":\(Int(lastCommitMs)),\"windows\":[\(windows)]}"
    }
}
#endif
