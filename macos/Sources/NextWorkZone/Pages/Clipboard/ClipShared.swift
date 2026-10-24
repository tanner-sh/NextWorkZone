import AppKit
import SwiftUI

// 剪贴板条目的显示与识别：类型、颜色、时间，以及从内容中识别出的问题、JSON、时间戳、颜色等，用于卡片和“智能操作”。

enum ClipKinds {
    struct Meta {
        var label: String
        var icon: String
        var color: String
    }

    static let all = ["text", "link", "code", "color", "image", "file"]
    static let meta: [String: Meta] = [
        "text": Meta(label: "文本", icon: "text.alignleft", color: "#6b7280"),
        "link": Meta(label: "链接", icon: "link", color: "#2563eb"),
        "code": Meta(label: "代码", icon: "chevron.left.forwardslash.chevron.right", color: "#7c3aed"),
        "color": Meta(label: "颜色", icon: "paintpalette", color: "#db2777"),
        "image": Meta(label: "图片", icon: "photo", color: "#059669"),
        "file": Meta(label: "文件", icon: "doc", color: "#d97706"),
    ]

    static func of(_ kind: String) -> Meta { meta[kind] ?? meta["text"]! }

    /// 置顶板可选的颜色。
    static let boardColors = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6", "#3b82f6", "#8b5cf6", "#ec4899", "#6b7280"]
}

extension ClipItem {
    var textual: Bool { kind != "image" && kind != "file" }
    /// 列表中的文字只有开头一部分
    var truncated: Bool { textLength > text.count }
}

enum ClipFmt {
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard let m = hex.trimmingCharacters(in: .whitespaces).wholeMatch(of: /#?([0-9a-fA-F]{3,8})/) else { return nil }
        var h = String(m.1)
        if h.count == 3 || h.count == 4 { h = String(h.prefix(3)).map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8 else { return nil }
        let v = h.prefix(6).map { $0 }
        func byte(_ i: Int) -> Double { Double(Int(String(v[i ... i + 1]), radix: 16) ?? 0) }
        return (byte(0), byte(2), byte(4))
    }

    static func color(_ hex: String) -> Color {
        guard let (r, g, b) = rgb(hex) else { return .gray }
        return Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// 背景色上的文字用白色还是深色。
    static func readable(on hex: String) -> Color {
        guard let (r, g, b) = rgb(hex) else { return .white }
        let lin = [r, g, b].map { v -> Double in
            let c = v / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2] > 0.45 ? Color(white: 0.1) : .white
    }

    /// 卡片标题栏的颜色：来源应用图标的主色，没有时用类型的颜色。
    static func head(_ item: ClipItem) -> String { item.appColor ?? ClipKinds.of(item.kind).color }

    static func time(_ ms: Int64) -> String { Fmt.time(ms: ms) }

    static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    static func host(_ url: String) -> String? {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: t.hasPrefix("www.") ? "https://\(t)" : t)?.host()
    }

    /// 卡片底部的一行说明：字符数、尺寸、文件数等。
    static func meta(_ item: ClipItem) -> String {
        switch item.kind {
        case "image":
            return item.image.map { "\($0.width) × \($0.height) · \(Fmt.size($0.bytes))" } ?? "图片"
        case "file":
            return item.files.count == 1 ? fileName(item.files[0]) : "\(item.files.count) 个文件"
        case "link":
            return host(item.text) ?? "\(item.textLength) 个字符"
        case "color":
            return item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(item.textLength.formatted()) 个字符\(lines > 1 ? " · \(lines)\(item.truncated ? "+" : "") 行" : "")"
        }
    }

    /// 文字中出现的问题 key（最多 3 个，去重）。
    static func issueKeys(_ text: String) -> [String] {
        var seen: [String] = []
        for m in text.matches(of: /\b[A-Z][A-Z0-9_]{1,15}-\d{1,7}\b/) where !seen.contains(String(m.output)) {
            seen.append(String(m.output))
            if seen.count == 3 { break }
        }
        return seen
    }

    /// 内容是 JSON 时返回格式化和压缩后的文字。
    static func json(_ text: String) -> (pretty: String, compact: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]")),
              let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let compact = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        else { return nil }
        // 与网页版相同的两格缩进
        let p = String(decoding: pretty, as: UTF8.self).replacing(/(?m)^( +)/) { String(repeating: " ", count: $0.1.count / 2) }
        return (p, String(decoding: compact, as: UTF8.self))
    }

    /// 10 位（秒）或 13 位（毫秒）的时间戳，限定在 2000–2100 年之间。
    static func timestamp(_ text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.wholeMatch(of: /\d{10}(\d{3})?/) != nil, let n = Double(t) else { return nil }
        let date = Date(timeIntervalSince1970: t.count == 10 ? n : n / 1000)
        let year = Calendar.current.component(.year, from: date)
        return (2000...2100).contains(year) ? date : nil
    }

    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// 颜色的几种写法（HEX、RGB、HSL），用于“粘贴为…”。
    static func colorFormats(_ text: String) -> [(String, String)]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var rgb = self.rgb(t)
        var alpha = 1.0
        if rgb == nil, let m = t.wholeMatch(of: /(?i)rgba?\(\s*([\d.]+)\s*[, ]\s*([\d.]+)\s*[, ]\s*([\d.]+)\s*(?:[,\/]\s*([\d.]+%?)\s*)?\)/) {
            rgb = (Double(m.1) ?? 0, Double(m.2) ?? 0, Double(m.3) ?? 0)
            if let a = m.4 { alpha = a.hasSuffix("%") ? (Double(a.dropLast()) ?? 100) / 100 : Double(a) ?? 1 }
        }
        guard let (rr, gg, bb) = rgb else { return nil }
        let (r, g, b) = (clamp(rr), clamp(gg), clamp(bb))
        let hex = String(format: "#%02x%02x%02x", r, g, b)
        let (h, s, l) = hsl(r, g, b)
        let alphaText = alpha.formatted(.number.precision(.fractionLength(0...2)))
        return [
            ("HEX", hex),
            ("RGB", alpha < 1 ? "rgba(\(r), \(g), \(b), \(alphaText))" : "rgb(\(r), \(g), \(b))"),
            ("HSL", "hsl(\(h) \(s)% \(l)%\(alpha < 1 ? " / \(alphaText)" : ""))"),
        ]
    }

    private static func clamp(_ v: Double) -> Int { max(0, min(255, Int(v.rounded()))) }

    private static func hsl(_ r: Int, _ g: Int, _ b: Int) -> (Int, Int, Int) {
        let (rn, gn, bn) = (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        let mx = max(rn, gn, bn), mn = min(rn, gn, bn)
        let l = (mx + mn) / 2
        if mx == mn { return (0, 0, Int((l * 100).rounded())) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        let h = mx == rn ? (gn - bn) / d + (gn < bn ? 6 : 0) : mx == gn ? (bn - rn) / d + 2 : (rn - gn) / d + 4
        return (Int((h * 60).rounded()), Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    /// 链接指向的应用内页面的说明，例如“Jira 问题 PROJ-1”；不是已配置系统的地址时返回 nil。
    @MainActor static func inAppLabel(_ url: String) -> String? {
        switch Links.route(url, baseUrl: { AppModel.shared.baseUrl($0) }) {
        case nil: return nil
        case .wiki: return "Wiki 页面"
        case .target(let t):
            switch t.page {
            case .wiki: return "Wiki 页面"
            case .jira: return "Jira 问题 \(t.issueKey ?? "")"
            default: return t.mrIid.map { "合并请求 !\($0)" } ?? "代码项目 \(t.projectPath ?? "")"
            }
        }
    }

    /// 条目中识别出的问题 key（文字中出现的，或 Jira 链接中的）。
    @MainActor static func itemIssueKeys(_ item: ClipItem) -> [String] {
        guard AppModel.shared.isReady(.jira) else { return [] }
        if item.kind == "link" {
            if case .target(let t) = Links.route(item.text, baseUrl: { AppModel.shared.baseUrl($0) }), t.page == .jira, let key = t.issueKey { return [key] }
            return []
        }
        return item.kind == "text" || item.kind == "code" ? issueKeys(item.text) : []
    }
}

// MARK: - 问题信息（来自本机问题库）

/// 卡片中显示的问题信息，同一轮的查询合并为一次。
@MainActor @Observable
final class ClipIssues {
    static let shared = ClipIssues()
    private(set) var cache: [String: IssueHit?] = [:]
    // 排队用的状态不参与界面观察：hits() 在视图的 body 中调用，
    // 在 body 中改动被观察的状态会让视图立刻重新计算，形成死循环（主线程卡住，查询任务也永远轮不到执行）
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var scheduled = false

    /// 在视图的 body 中调用：只读缓存，缺的问题排队查询，查到后缓存变化再刷新视图。
    func hits(_ keys: [String]) -> [IssueHit] {
        let missing = keys.filter { cache[$0] == nil }
        if !missing.isEmpty { request(missing) }
        return keys.compactMap { cache[$0] ?? nil }
    }

    private func request(_ keys: [String]) {
        pending.formUnion(keys)
        guard !scheduled else { return }
        scheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            scheduled = false
            let batch = Array(pending)
            pending.removeAll()
            // 先占位，避免重复查询
            for key in batch where cache[key] == nil { cache[key] = .some(nil) }
            let hits = (try? await API.shared.clipIssues(batch)) ?? []
            for key in batch { cache[key] = .some(hits.first { $0.key == key }) }
        }
    }
}

// MARK: - 智能操作

struct ClipAction: Identifiable {
    var id: String
    var label: String
    var icon: String
    var run: @MainActor () async throws -> Void
}

struct ClipActionEnv {
    /// 粘贴（面板中）或复制（应用内页面中、不能自动粘贴时）一段转换后的文字
    var emitText: @MainActor (String) async throws -> Void
    /// emitText 的动作名称：“粘贴”或“复制”
    var verb: String
    /// 在主窗口中打开地址
    var openInApp: @MainActor (String) -> Void
    /// 操作完成后的提示
    var done: @MainActor (String) -> Void
}

@MainActor
enum ClipActions {
    /// 追加一行到今天的日记（与快速记录相同的格式）。
    static func appendToDaily(_ text: String) async throws {
        let today = Fmt.today()
        let doc = try await API.shared.wsDaily(today)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let line = "- \(f.string(from: Date())) \(text.replacing(/\s*\n\s*/, with: " "))"
        let trimmed = doc.content.replacing(/\s+$/, with: "")
        var input = DocActions.input(doc)
        input.content = doc.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(line)\n" : "\(trimmed)\n\(line)\n"
        input.kind = "daily"
        if input.title.isEmpty { input.title = today }
        _ = try await API.shared.wsSaveDoc(input)
        Events.workspaceChanged()
    }

    /// `text` 是条目的完整文字（列表中的可能只有开头）。
    static func smart(_ item: ClipItem, text: String, issues: [IssueHit], env: ClipActionEnv) -> [ClipAction] {
        var actions: [ClipAction] = []
        let jira = AppModel.shared.baseUrl(.jira)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let verb = env.verb

        if item.kind == "link" {
            if let label = ClipFmt.inAppLabel(trimmed) {
                actions.append(ClipAction(id: "open-app", label: "在应用中打开\(label)", icon: "macwindow") { env.openInApp(trimmed) })
            }
            actions.append(ClipAction(id: "open-browser", label: "在浏览器中打开", icon: "safari") { Links.openInBrowser(trimmed.hasPrefix("www.") ? "https://\(trimmed)" : trimmed) })
        }

        for key in ClipFmt.itemIssueKeys(item) {
            let issue = issues.first { $0.key == key }
            if item.kind != "link" { actions.append(ClipAction(id: "issue-\(key)", label: "打开问题 \(key)", icon: "smallcircle.filled.circle") { env.openInApp("\(jira)/browse/\(key)") }) }
            if let issue { actions.append(ClipAction(id: "issue-title-\(key)", label: "\(verb)为“\(key) \(issue.summary)”", icon: "smallcircle.filled.circle") { try await env.emitText("\(key) \(issue.summary)") }) }
            if item.kind != "link" { actions.append(ClipAction(id: "issue-url-\(key)", label: "\(verb)问题链接", icon: "smallcircle.filled.circle") { try await env.emitText("\(jira)/browse/\(key)") }) }
        }

        if item.kind == "code", let json = ClipFmt.json(text) {
            if json.pretty != text { actions.append(ClipAction(id: "json-pretty", label: "格式化 JSON 后\(verb)", icon: "curlybraces") { try await env.emitText(json.pretty) }) }
            if json.compact != text { actions.append(ClipAction(id: "json-compact", label: "压缩 JSON 后\(verb)", icon: "curlybraces") { try await env.emitText(json.compact) }) }
        }

        if item.kind == "text", let time = ClipFmt.timestamp(text) {
            let value = ClipFmt.dateTime(time)
            actions.append(ClipAction(id: "timestamp", label: "\(verb)为 \(value)", icon: "calendar.badge.clock") { try await env.emitText(value) })
        }

        if item.kind == "color" {
            for (name, value) in ClipFmt.colorFormats(text) ?? [] where value.lowercased() != trimmed.lowercased() {
                actions.append(ClipAction(id: "color-\(name)", label: "\(verb)为 \(value)", icon: "paintpalette") { try await env.emitText(value) })
            }
        }

        if (item.kind == "text" || item.kind == "code") && trimmed.contains("\n") {
            actions.append(ClipAction(id: "one-line", label: "合并为一行后\(verb)", icon: "text.justify") { try await env.emitText(trimmed.replacing(/\s*\n\s*/, with: " ")) })
        }

        if item.kind == "file" {
            actions.append(ClipAction(id: "reveal", label: "在文件夹中显示", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting(item.files.map { URL(fileURLWithPath: $0) }) })
            actions.append(ClipAction(id: "paths", label: "\(verb)为文件路径", icon: "text.justify") { try await env.emitText(item.files.joined(separator: "\n")) })
        }

        if item.kind == "text" || item.kind == "link" || item.kind == "code" {
            let lines = trimmed.components(separatedBy: "\n")
            let title = String((item.title.isEmpty ? lines[0] : item.title).trimmingCharacters(in: .whitespaces).prefix(200))
            // 起了名字的条目以名字作标题，原文全部放进备注（链接不会丢）
            let notes = (item.title.isEmpty ? lines.dropFirst().joined(separator: "\n") : trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
            actions.append(ClipAction(id: "todo", label: "加入待办", icon: "checkmark.square") {
                _ = try await API.shared.wsSaveTodo(TodoInput(title: title, notes: notes, due: .some(nil)))
                Events.workspaceChanged()
                env.done("已加入待办")
            })
            actions.append(ClipAction(id: "daily", label: "追加到今天的日记", icon: "note.text") {
                try await appendToDaily(trimmed)
                env.done("已写入今天的日记")
            })
        }
        return actions
    }
}

// MARK: - 视图

/// 来源应用的图标；没有图标时显示名称首字。
struct ClipAppIcon: View {
    var appId: String?
    var appName: String?
    var hasIcon: Bool
    var appColor: String?
    var size: CGFloat = 28

    init(item: ClipItem, size: CGFloat = 28) {
        self.init(appId: item.appId, appName: item.appName, hasIcon: item.appIcon, appColor: item.appColor, size: size)
    }

    init(appId: String?, appName: String?, hasIcon: Bool, appColor: String?, size: CGFloat = 28) {
        self.appId = appId
        self.appName = appName
        self.hasIcon = hasIcon
        self.appColor = appColor
        self.size = size
    }

    var body: some View {
        if hasIcon, let appId {
            AssetImage(path: "clip/icon/\(appId)").frame(width: size, height: size)
        } else {
            Text(String((appName ?? "?").prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(appColor.map(ClipFmt.color) ?? Color.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: size * 0.22))
        }
    }
}

struct ClipIssueLine: View {
    var issue: IssueHit

    var body: some View {
        HStack(spacing: 6) {
            Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
            StatusPill(status: issue.status)
            Text(issue.summary).font(.caption).lineLimit(1)
        }
    }
}

struct ClipFileList: View {
    var files: [String]
    var limit: Int?
    var full = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(limit.map { Array(files.prefix($0)) } ?? files, id: \.self) { f in
                let name = ClipFmt.fileName(f)
                Label {
                    Text(full ? f : name).lineLimit(full ? nil : 1).truncationMode(.middle).textSelection(.enabled)
                } icon: {
                    Image(systemName: name.contains(".") ? "doc" : "folder")
                }
                .font(.callout)
                .help(f)
            }
            if let limit, files.count > limit { Text("还有 \(files.count - limit) 个…").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// 完整内容的预览（面板的预览层、应用内页面的详情）。`text` 是完整文字。
struct ClipPreviewBody: View {
    var item: ClipItem
    var text: String
    var issues: [IssueHit]

    var body: some View {
        switch item.kind {
        case "image":
            AssetImage(path: "clip/image/\(item.id)").frame(maxWidth: .infinity, maxHeight: .infinity)
        case "color":
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 12).fill(ClipFmt.color(ClipFmt.colorFormats(text)?.first?.1 ?? "#000")).frame(width: 120, height: 120)
                Grid(alignment: .leading, verticalSpacing: 6) {
                    ForEach(ClipFmt.colorFormats(text) ?? [], id: \.0) { k, v in
                        GridRow {
                            Text(k).foregroundStyle(.secondary)
                            Text(v).monospaced().textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case "file":
            ScrollView { ClipFileList(files: item.files, full: true).frame(maxWidth: .infinity, alignment: .leading) }
        default:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) { ClipIssueLine(issue: $0) }
                if item.kind == "link", let label = ClipFmt.inAppLabel(text) {
                    Label(label, systemImage: "macwindow").font(.caption).foregroundStyle(.secondary)
                }
                if item.kind == "code" {
                    CodeView(code: text, path: ClipCode.guessPath(text))
                } else {
                    ScrollView {
                        Text(text.count > 200_000 ? String(text.prefix(200_000)) + "…" : text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// 代码的语言猜测（只用于高亮）。
enum ClipCode {
    static func guessPath(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ClipFmt.json(t) != nil { return "x.json" }
        if t.hasPrefix("<") { return "x.xml" }
        if t.range(of: #"(?i)^\s*(select|insert|update|delete|create|alter|with)\s"#, options: .regularExpression) != nil { return "x.sql" }
        if t.contains("fn ") && t.contains("->") || t.contains("let mut ") { return "x.rs" }
        if t.contains("func ") && t.contains("{") && !t.contains(";") { return "x.go" }
        if t.contains("def ") && t.contains(":") && !t.contains("{") { return "x.py" }
        if t.contains("public ") || t.contains("private ") && t.contains(";") { return "x.java" }
        if t.hasPrefix("#!") || t.hasPrefix("$ ") { return "x.sh" }
        return "x.ts"
    }
}

/// 列表行、卡片中的一段文字（高亮搜索词）。
func clipSnippet(_ item: ClipItem, query: String, limit: Int = 160) -> AttributedString {
    let text = String(item.text.replacing(/\s+/, with: " ").prefix(limit))
    return highlighted(text, query)
}

// MARK: - 拖到其他应用

/// 把条目拖到其他应用：文字带上纯文本和格式；图片、文件作为文件拖出（放到访达、聊天、邮件中就是文件）。
@MainActor
enum ClipDrag {
    /// 完整的文字和 HTML。列表中的文字可能只有开头一部分，拖动开始时来不及异步读取，所以按下鼠标时先取好。
    private static var full: [String: ClipText] = [:]

    private static func needsFetch(_ item: ClipItem) -> Bool { (item.textual && item.truncated) || item.hasHtml }

    static func prepare(_ items: [ClipItem]) {
        for item in items where needsFetch(item) && full[item.id] == nil {
            Task { if let t = try? await API.shared.clipText(item.id) { full[item.id] = t } }
        }
    }

    /// 要拖出的内容；内容还没读取完时返回 nil。
    static func writers(_ items: [ClipItem]) throws -> (writers: [NSPasteboardWriting], image: NSImage)? {
        if items.contains(where: { !$0.textual }) {
            let icon = NSWorkspace.shared.icon(for: .data).tiffRepresentation ?? Data()
            let files = try API.shared.core.clipDragFiles(ids: items.filter { !$0.textual }.map(\.id), fallbackIcon: icon)
            let image = NSImage(data: files.preview) ?? NSWorkspace.shared.icon(for: .data)
            return (files.paths.map { URL(fileURLWithPath: $0) as NSURL }, image)
        }
        var texts: [String] = []
        var htmls: [String] = []
        var anyHtml = false
        for item in items {
            if needsFetch(item) {
                guard let t = full[item.id] else {
                    prepare(items)
                    return nil
                }
                texts.append(t.text)
                htmls.append(t.html ?? paragraph(t.text))
                anyHtml = anyHtml || t.html != nil
            } else {
                texts.append(item.text)
                htmls.append(paragraph(item.text))
            }
        }
        let text = texts.joined(separator: "\n")
        let pb = NSPasteboardItem()
        pb.setString(text, forType: .string)
        if anyHtml { pb.setString(htmls.joined(separator: "\n"), forType: .html) }
        if items.count == 1, items[0].kind == "link", let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            pb.setString(url.absoluteString, forType: .URL)
        }
        return ([pb], textImage(text))
    }

    private static func paragraph(_ text: String) -> String {
        "<p>" + text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>") + "</p>"
    }

    /// 拖动时跟随鼠标的文字预览。
    private static func textImage(_ text: String) -> NSImage {
        let line = String(text.replacing(/\s+/, with: " ").prefix(60))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let size = (line as NSString).size(withAttributes: attrs)
        let image = NSImage(size: NSSize(width: min(size.width, 360) + 16, height: size.height + 10))
        image.lockFocus()
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: image.size), xRadius: 6, yRadius: 6).fill()
        (line as NSString).draw(in: NSRect(x: 8, y: 5, width: image.size.width - 16, height: size.height), withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}

/// 卡片、列表行的鼠标操作：单击（带修饰键）、双击、右键菜单，以及拖到其他应用。
/// SwiftUI 的拖放一次只能带一个文件，所以由 AppKit 视图开始拖动。
struct ClipMouse: NSViewRepresentable {
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void = {}
    var menu: () -> [MenuSpec]
    /// 要拖动的条目（多选时按选择顺序）
    var dragItems: () -> [ClipItem]
    var onDragError: (String) -> Void = { toast($0, error: true) }
    /// 设置后右键时调用它（自己弹出菜单），不使用 `menu`
    var onRightClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> MouseView { MouseView() }

    func updateNSView(_ view: MouseView, context: Context) {
        view.owner = self
    }

    final class MouseView: NSView, NSDraggingSource {
        var owner: ClipMouse?
        private var down: NSEvent?
        private var dragging: [ClipItem] = []

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            down = event
            if let items = owner?.dragItems() { ClipDrag.prepare(items) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = down, let owner else { return }
            let a = start.locationInWindow, b = event.locationInWindow
            guard hypot(a.x - b.x, a.y - b.y) >= 5 else { return }
            down = nil
            let items = owner.dragItems()
            do {
                guard let (writers, image) = try ClipDrag.writers(items) else {
                    owner.onDragError("内容较长，正在读取，请再拖一次")
                    return
                }
                dragging = items
                let origin = convert(start.locationInWindow, from: nil)
                let dragItems = writers.enumerated().map { i, w in
                    let item = NSDraggingItem(pasteboardWriter: w)
                    let size = image.size.width > 0 ? image.size : NSSize(width: 64, height: 64)
                    item.setDraggingFrame(NSRect(x: origin.x - size.width / 2 + CGFloat(i) * 6, y: origin.y - size.height / 2 - CGFloat(i) * 6, width: size.width, height: size.height), contents: i == 0 ? image : nil)
                    return item
                }
                beginDraggingSession(with: dragItems, event: start, source: self)
            } catch {
                owner.onDragError(errorMessage(error))
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard down != nil, let owner else { return }
            down = nil
            if event.clickCount == 2 { owner.onDoubleClick() } else { owner.onClick(event.modifierFlags) }
        }

        override func rightMouseDown(with event: NSEvent) {
            if let action = owner?.onRightClick { action() } else { super.rightMouseDown(with: event) }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let owner else { return nil }
            return MenuBuilder.menu(owner.menu())
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // 确实放到了别处时，标记为刚刚使用
            if operation != [] { API.shared.core.clipTouch(ids: dragging.map(\.id)) }
            dragging = []
        }
    }
}

/// 新建或编辑置顶板。
struct BoardSheet: View {
    var board: Pinboard?
    var count: Int
    var onSaved: (Pinboard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(board == nil ? "新建置顶板" : "编辑置顶板").font(.title3.weight(.semibold))
            TextField("名称", text: $name, prompt: Text("例如：常用回复、代码片段")).onSubmit(save)
            HStack(spacing: 8) {
                Text("颜色")
                ForEach(ClipKinds.boardColors, id: \.self) { c in
                    Circle().fill(ClipFmt.color(c)).frame(width: 20, height: 20)
                        .overlay { if c == color { Circle().strokeBorder(.primary, lineWidth: 2).padding(-3) } }
                        .onTapGesture { color = c }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = board?.name ?? ""
            color = board?.color ?? ClipKinds.boardColors[count % ClipKinds.boardColors.count]
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            do {
                onSaved(try await API.shared.clipSavePinboard(id: board?.id, name: name, color: color))
                dismiss()
            } catch { self.error = errorMessage(error) }
        }
    }
}

/// 按条件加载剪贴板历史和置顶板；有新内容或其他窗口修改了条目时自动刷新，滚动到末尾时加载更多。
@MainActor @Observable
final class ClipListModel {
    static let page = 120
    var items: [ClipItem]?
    var boards: [Pinboard] = []
    var hasMore = false
    var error: String?
    var text = ""
    var kind: String?
    var board: String?
    var app: String?
    private var seq = 0
    private var loadingMore = false
    private var observers: [NSObjectProtocol] = []
    private let debounce = Debouncer()

    init() {
        for event in [AppEvent.clipChanged, AppEvent.clipSettings] {
            observers.append(NotificationCenter.default.addObserver(forName: Events.name(event), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(after: .milliseconds(60)) }
            })
        }
    }

    func schedule(after delay: Duration = .zero) {
        debounce.run(after: delay) { [weak self] in await self?.reload() }
    }

    func reload() async {
        seq += 1
        let my = seq
        do {
            async let list = API.shared.clipList(ClipQuery(text: text.isEmpty ? nil : text, kind: kind, pinboard: board, app: app, limit: Self.page))
            async let pinboards = API.shared.clipPinboards()
            let (l, p) = try await (list, pinboards)
            guard my == seq else { return }
            items = l
            boards = p
            // 置顶板中的条目按置顶时间排列，数量不多，一次取完
            hasMore = l.count == Self.page && board == nil
            error = nil
        } catch {
            if my == seq { self.error = errorMessage(error) }
        }
    }

    func loadMore() {
        guard hasMore, let last = items?.last, !loadingMore else { return }
        loadingMore = true
        let my = seq
        Task {
            defer { loadingMore = false }
            guard let more = try? await API.shared.clipList(ClipQuery(text: text.isEmpty ? nil : text, kind: kind, pinboard: board, app: app, before: last.copiedAt, limit: Self.page)), my == seq else { return }
            let ids = Set(items?.map(\.id) ?? [])
            items = (items ?? []) + more.filter { !ids.contains($0.id) }
            hasMore = more.count == Self.page
        }
    }
}
