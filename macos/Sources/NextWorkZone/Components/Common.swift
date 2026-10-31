import AppKit
import NWZCore
import SwiftUI

// MARK: - 图片

/// 系统内的图片（图标、头像、附件缩略图等）：需要认证时经由 `API.asset` 带上凭据取回，结果缓存在内存中。
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private var failed: Set<String> = []
    private var loading: [String: Task<NSImage?, Never>] = [:]

    func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }
    func hasFailed(_ path: String) -> Bool { failed.contains(path) }

    /// 网页登录状态变化后，之前失败的图片可以再试。
    func clearFailures() { failed.removeAll() }

    func load(_ path: String) async -> NSImage? {
        if let image = cached(path) { return image }
        if failed.contains(path) { return nil }
        if let task = loading[path] { return await task.value }
        let task = Task<NSImage?, Never> {
            do {
                let (data, type) = try await API.shared.asset(path)
                let image = NSImage(data: data)
                #if DEBUG
                if image == nil { debugLog("图片无法解码：\(path) \(type ?? "") \(data.count) 字节") }
                #endif
                return image
            } catch {
                #if DEBUG
                debugLog("图片加载失败：\(path) \(errorMessage(error))")
                #endif
                return nil
            }
        }
        loading[path] = task
        let image = await task.value
        loading[path] = nil
        if let image { cache.setObject(image, forKey: path as NSString) } else { failed.insert(path) }
        return image
    }

    /// 资源路径：系统地址（相对路径或完整地址）属于已配置的系统时经由应用层，否则为 `nil`（直接按网址加载）。
    static func path(service: Service, src: String) -> String? {
        let base = AppModel.shared.baseUrl(service)
        let isSystem = (src.hasPrefix("/") && !src.hasPrefix("//")) || (!base.isEmpty && (src == base || src.hasPrefix(base + "/")))
        guard isSystem else { return nil }
        return "\(service.rawValue)/\(src.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? src)"
    }
}

/// 显示来自某个系统的图片；加载成功前不占位，失败（例如需要网页登录）时不显示。
struct SysImage: View {
    var service: Service
    var src: String?
    var size: CGFloat? = nil
    /// 图标读不到（如未网页登录）时显示的 SF Symbol，免得留下一块空位、旁边的文字看起来没对齐
    var fallback: String? = nil
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        // 加载前用透明占位（空视图不会执行 task）
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if failed, let fallback {
                Image(systemName: fallback).resizable().aspectRatio(contentMode: .fit).foregroundStyle(.tertiary).padding(1)
            } else {
                Color.clear
            }
        }
        .frame(width: image == nil ? (size ?? 1) : size, height: image == nil ? (size ?? 1) : size)
        // 问题类型、优先级等系统图标只是装饰，旁边有文字，读屏时跳过
        .accessibilityHidden(true)
        .task(id: "\(src ?? "")|\(model.sessionVersion)") { await load() }
    }

    private func load() async {
        guard let src, !src.isEmpty else { image = nil; failed = true; return }
        if let path = ImageCache.path(service: service, src: src) {
            image = await ImageCache.shared.load(path)
        } else if let url = URL(string: src), let (data, _) = try? await URLSession.shared.data(from: url) {
            image = NSImage(data: data)
        }
        if Task.isCancelled { return }
        failed = image == nil
    }
}

/// 本机资源（工作空间图片、剪贴板图片）。
struct AssetImage: View {
    var path: String
    var contentMode: ContentMode = .fit
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .task(id: path) { image = await ImageCache.shared.load(path) }
    }
}

// MARK: - 人名、状态

/// 人名头像：中文名取最后两个字，其他取首字母。
struct Avatar: View {
    var name: String?
    var size: CGFloat = 24

    private static let colors: [Color] = [
        Color(red: 0.39, green: 0.40, blue: 0.95), Color(red: 0.05, green: 0.65, blue: 0.91), Color(red: 0.08, green: 0.72, blue: 0.65),
        Color(red: 0.13, green: 0.77, blue: 0.37), Color(red: 0.96, green: 0.62, blue: 0.04), Color(red: 0.94, green: 0.27, blue: 0.27),
        Color(red: 0.93, green: 0.28, blue: 0.60), Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.39, green: 0.45, blue: 0.55),
    ]

    var body: some View {
        let text = (name ?? "").trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let cjk = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let initials = cjk ? String(text.suffix(2)) : String(text.split(separator: " ").compactMap(\.first).prefix(2)).uppercased()
            let hash = text.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31 &+ $1.value) }
            Text(initials)
                .font(.system(size: size * (cjk ? 0.36 : 0.42), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Self.colors[Int(hash % UInt32(Self.colors.count))], in: Circle())
                .help(text)
                // 读出完整的名字，而不是头像上的两个字
                .accessibilityLabel(text)
        }
    }
}

/// Jira 状态：彩色圆点加文字。
struct StatusPill: View {
    var status: JiraStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Self.color(status.category)).frame(width: 7, height: 7)
            Text(status.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("状态：\(status.name)")
    }

    static func color(_ category: String) -> Color {
        switch category {
        case "done": .green
        case "indeterminate": .blue
        default: .gray
        }
    }
}

// MARK: - 状态提示

struct ErrorBox: View {
    var message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("重试", systemImage: "arrow.clockwise", action: retry)
            }
        }
        .padding(10)
        .noticeBackground(.red)
    }
}

struct Notice: View {
    var systemImage = "info.circle"
    var text: String
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(10)
        .noticeBackground(tint)
    }
}

/// 某个系统尚未配置时的占位提示。
struct NotConfigured: View {
    var label: String
    /// 设置窗口中打开哪一页
    var settingsTab = "connection"

    var body: some View {
        ContentUnavailableView {
            Label("尚未配置 \(label)", systemImage: "powerplug")
        } actions: {
            Button("前往设置") { AppModel.shared.navigate(NavTarget(.settings, toolTab: settingsTab)) }.buttonStyle(.borderedProminent)
        }
    }
}

/// 网页路径（附件、图片）需要网页登录时显示提示。只放在确实有附件或图片的内容上方；
/// 点“稍后”后本次运行中不再显示，侧栏底部的入口（SidebarLoginStatus）一直都在。
struct WebLoginHint: View {
    var service: Service
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.access(service) == .loginRequired && !model.loginHintDismissed.contains(service) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.orange)
                Text("\(service.label) 的附件和图片需要网页登录后才能显示")
                Spacer()
                Button("稍后") { withAnimation { _ = model.loginHintDismissed.insert(service) } }
                    .buttonStyle(.borderless)
                    .help("本次运行中不再提示，可以随时从侧栏底部登录")
                Button("网页登录") { WebLogin.open(service) }
            }
            .font(.callout)
            .padding(10)
            .noticeBackground(.orange)
        }
    }
}

/// 鼠标是否在这一块上，用于只在悬停时显示的按钮。
struct HoverReveal<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hover = false

    var body: some View {
        content(hover).onHover { hover = $0 }
    }
}

/// 侧栏底部：有系统需要网页登录时显示一个入口（代替在每篇内容上方重复显示的提示条）。
struct SidebarLoginStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = Service.allCases.filter { $0.supportsWebLogin && model.access($0) == .loginRequired }
        if !pending.isEmpty {
            Menu {
                ForEach(pending, id: \.self) { s in
                    Button("登录 \(s.label)…") { WebLogin.open(s) }
                }
            } label: {
                Label("\(pending.map(\.label).joined(separator: "、")) 需要网页登录", systemImage: "key.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } primaryAction: {
                if pending.count == 1 { WebLogin.open(pending[0]) }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(pending.count > 1 ? .visible : .hidden)
            .help("附件和图片需要网页登录后才能显示，登录一次即可")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// 加载中的占位。
struct LoadingView: View {
    var label = "加载中…"
    /// 已知进度（0...1）时显示进度条和百分比
    var progress: Double?

    var body: some View {
        HStack(spacing: 8) {
            if let progress {
                Text(label).foregroundStyle(.secondary)
                ProgressView(value: progress).frame(width: 160)
                Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text(label).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 提示条

/// 在窗口底部短暂显示一条提示（复制成功、已添加待办等）。
@MainActor @Observable
final class Toasts {
    static let shared = Toasts()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var error: Bool
        /// 进行中的操作（例如上传）的进度；有进度的提示一直显示到操作结束
        var progress: Double?
        /// 提示中的按钮（例如“撤销”）
        var action: (label: String, run: @MainActor () -> Void)?

        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.message == b.message && a.error == b.error && a.progress == b.progress }
    }

    var items: [Item] = []

    /// 开始一项进行中的操作，`progress` 为 nil 时先不显示进度条（还不知道总量）
    func begin(_ message: String, progress: Double? = 0) -> UUID {
        let item = Item(message: message, error: false, progress: progress)
        items = Array(items.suffix(2)) + [item]
        return item.id
    }

    func update(_ id: UUID, progress: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].progress = progress
    }

    func finish(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func show(_ message: String, error: Bool = false, action: (label: String, run: @MainActor () -> Void)? = nil) {
        let item = Item(message: message, error: error, action: action)
        items = Array(items.suffix(2)) + [item]
        Task {
            try? await Task.sleep(for: .seconds(error || action != nil ? 4.4 : 2.2))
            items.removeAll { $0.id == item.id }
        }
    }

    func dismiss(_ id: UUID) { items.removeAll { $0.id == id } }
}

@MainActor func toast(_ message: String, error: Bool = false) {
    Toasts.shared.show(message, error: error)
}

/// 带“撤销”按钮的提示：点击时撤销主窗口撤销记录中名为 `undoName` 的那一步（之后又有别的操作时不撤销）。
@MainActor func toastUndo(_ message: String, undoName: String) {
    Toasts.shared.show(message, action: ("撤销", {
        guard let manager = MainWindow.window?.undoManager, manager.canUndo, manager.undoActionName == undoName else { return }
        manager.undo()
    }))
}

/// 上传文件，期间在窗口底部显示进度；`onProgress` 另外收到进度（0...1）。
@MainActor func withUploadProgress<T>(_ message: String, onProgress: (@MainActor @Sendable (Double) -> Void)? = nil, _ body: () async throws -> T) async rethrows -> T {
    let id = Toasts.shared.begin(message)
    defer { Toasts.shared.finish(id) }
    return try await UploadProgress.$report.withValue(progressReporter(id, onProgress)) { try await body() }
}

/// 下载文件，期间在窗口底部显示进度。`expected` 为已知的文件大小，服务器没有给出长度时据此换算。
@MainActor func withDownloadProgress<T>(_ message: String, expected: Int64 = 0, _ body: () async throws -> T) async rethrows -> T {
    let id = Toasts.shared.begin(message, progress: expected > 0 ? 0 : nil)
    defer { Toasts.shared.finish(id) }
    return try await DownloadProgress.$expected.withValue(expected) {
        try await DownloadProgress.$report.withValue(progressReporter(id, nil)) { try await body() }
    }
}

private func progressReporter(_ id: UUID, _ onProgress: (@MainActor @Sendable (Double) -> Void)?) -> @Sendable (Double) -> Void {
    { fraction in
        Task { @MainActor in
            Toasts.shared.update(id, progress: fraction)
            onProgress?(fraction)
        }
    }
}

/// 执行异步操作，失败时提示错误。
@MainActor func guarded(_ action: @escaping @MainActor () async throws -> Void) {
    Task {
        do { try await action() } catch { toast("操作失败：\(errorMessage(error))", error: true) }
    }
}

struct ToastOverlay: View {
    @State private var toasts = Toasts.shared
    /// 主窗口、单独打开的窗口都有提示层，只在当前窗口中显示
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // 提示出现时玻璃从无到有凝结、消失时消散（materialize）；融合距离为 0，叠在一起的几条不会粘成一块
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(appearsActive ? toasts.items : []) { t in
                    HStack(spacing: 10) {
                        Text(t.message)
                        if let p = t.progress {
                            ProgressView(value: p).frame(width: 120)
                            Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let action = t.action {
                            Button(action.label) {
                                toasts.dismiss(t.id)
                                action.run()
                            }
                            .buttonStyle(.borderless)
                            .fontWeight(.semibold)
                        }
                    }
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(t.error ? .regular.tint(.red.opacity(0.35)) : .regular, in: Capsule())
                        .glassEffectTransition(.materialize)
                        // 只有带按钮的提示接收点击，其余不挡住下面的内容
                        .allowsHitTesting(t.action != nil)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy, value: toasts.items)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - 剪贴板

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// 复制文件（访达、聊天、邮件中粘贴为文件）；`image` 有值时同一项中再放入图像数据。
    static func copyFile(_ url: URL, image: NSImage? = nil) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let image { addImage(image, to: item) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    static func copyImage(_ image: NSImage) {
        let item = NSPasteboardItem()
        addImage(image, to: item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// PNG 和 TIFF 都放：不少应用只认其中一种。
    private static func addImage(_ image: NSImage, to item: NSPasteboardItem) {
        guard let tiff = image.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
        if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
    }
}

// MARK: - 小部件

/// 分组标题。
struct SectionHeader: View {
    var title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if let count { Text("\(count)").foregroundStyle(.secondary) }
        }
    }
}

/// 高亮文字中出现的关键词（按空白拆分，不区分大小写）。
func highlighted(_ text: String, _ query: String) -> AttributedString {
    var result = AttributedString(text)
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    guard !terms.isEmpty else { return result }
    let lower = text.lowercased()
    for term in terms {
        var searchRange = lower.startIndex..<lower.endIndex
        while let r = lower.range(of: term, range: searchRange) {
            let start = lower.distance(from: lower.startIndex, to: r.lowerBound)
            let len = lower.distance(from: r.lowerBound, to: r.upperBound)
            let a = result.index(result.startIndex, offsetByCharacters: start)
            let b = result.index(a, offsetByCharacters: len)
            result[a..<b].backgroundColor = Color.yellow.opacity(0.35)
            searchRange = r.upperBound..<lower.endIndex
        }
    }
    return result
}

extension View {
    /// 列表行的常用外观：可点击整行。
    func rowTap(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture(perform: action)
    }
}

/// 输入停顿后再执行（搜索框）。
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?

    func run(after delay: Duration, _ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancel() { task?.cancel() }
}

/// 横向滚动区中，鼠标滚轮（纵向）也能左右滚动：SwiftUI 的横向 ScrollView 只响应横向滚动，
/// 只有纵向滚轮的鼠标滚不动。鼠标在这个区域内且纵向滚动为主时，直接横向滚动鼠标下方的滚动区。
struct VerticalWheelScrollsHorizontally: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WheelView() }
    func updateNSView(_ view: NSView, context: Context) {}

    /// 横向滚动 `point`（窗口坐标）下方的滚动区；`dy` 为纵向滚动量（点，向下为负）。滚动了返回真。
    @MainActor
    static func scroll(in window: NSWindow, at point: NSPoint, dy: CGFloat) -> Bool {
        guard let root = window.contentView?.superview ?? window.contentView,
              let scroll = root.hitTest(root.convert(point, from: nil))?.enclosingScrollView,
              let document = scroll.documentView, document.frame.width > scroll.contentView.bounds.width + 1 else { return false }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.x -= dy
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }

    final class WheelView: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 离开窗口时（视图移除）取消监听
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor,
                      self.convert(self.bounds, to: nil).contains(event.locationInWindow),
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
                // 鼠标滚轮按行计数，换算成点
                let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 30
                return VerticalWheelScrollsHorizontally.scroll(in: window, at: event.locationInWindow, dy: dy) ? nil : event
            }
        }
    }
}

extension View {
    /// 见 VerticalWheelScrollsHorizontally。
    func verticalWheelScrollsHorizontally() -> some View { background(VerticalWheelScrollsHorizontally()) }
}
