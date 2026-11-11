import AppKit
import SwiftUI

/// 页面顶部的按钮栏：页面的按钮和标题。
///
/// 窗口不用系统工具栏，按钮栏画在页面自己的视图里（占原来工具栏的位置）。
/// 之前各页面的按钮都放在窗口的系统工具栏中，保留的页面（见 KeptPages）切换时要隐藏一批、显示一批：
/// 系统要逐个重新排布、播放玻璃变形动画，页面内容出来之后主线程还要忙一百多毫秒，切换一次多花几百毫秒处理器时间。
/// 按钮栏在页面的宿主视图里，跟着页面一起隐藏、显示，切换时没有任何东西要更新。
///
/// 用法：页面里任何一层视图用 `.pageBar { BarItem { … } }` 声明按钮（经偏好值传到页面顶部，按视图树的顺序排列，外层在前）；
/// 页面的根视图用 `.pageBarRoot()` 画出按钮栏。空的系统工具栏也会吞掉点击，所以不能把按钮栏叠在系统工具栏下面，
/// 窗口用 `.windowBarChrome()` 把系统工具栏隐藏（见 TitlebarFix）。

// MARK: - 声明

/// 按钮在栏中的位置：左边、右边、最右边（主要操作）。
enum BarPlacement: Int {
    case leading, trailing, primary
}

/// 按钮栏中的一项（已经擦除类型，放进偏好值）。
struct BarEntry: Identifiable {
    enum Kind { case item, spacer }
    var id: String
    var placement: BarPlacement
    var kind: Kind
    /// 醒目的着色玻璃（保存、合并等主要操作可用时）
    var prominent = false
    var view: AnyView
}

/// 按钮栏中的一块玻璃：里面可以是一个或几个按钮（图标按钮默认只显示图标，要显示文字加 `.labelStyle(.titleAndIcon)`）、
/// 分段控件（BarSegmented）或菜单按钮（BarMenu）。
struct BarItem {
    var entry: BarEntry
    var isHidden = false

    init(_ placement: BarPlacement = .trailing, prominent: Bool = false, @ViewBuilder content: () -> some View) {
        entry = BarEntry(id: "", placement: placement, kind: .item, prominent: prominent, view: AnyView(content()))
    }

    /// 不显示这一项（不改变其余各项的标识）。
    func hidden(_ hidden: Bool) -> BarItem {
        var copy = self
        copy.isHidden = hidden
        return copy
    }
}

/// 两块玻璃之间加宽的间隔，把不同用途的按钮分开。
struct BarSpacer {
    var placement: BarPlacement
    init(_ placement: BarPlacement = .trailing) { self.placement = placement }
}

@resultBuilder
enum BarBuilder {
    static func buildExpression(_ item: BarItem) -> [BarEntry] { item.isHidden ? [] : [item.entry] }
    static func buildExpression(_ spacer: BarSpacer) -> [BarEntry] {
        [BarEntry(id: "", placement: spacer.placement, kind: .spacer, view: AnyView(EmptyView()))]
    }
    static func buildExpression(_ entries: [BarEntry]) -> [BarEntry] { entries }
    /// 各项的标识是它在声明中的位置，条件不成立的项不影响别的项
    static func buildBlock(_ parts: [BarEntry]...) -> [BarEntry] {
        parts.enumerated().flatMap { index, part in part.map { prefixed($0, "\(index)") } }
    }
    static func buildOptional(_ part: [BarEntry]?) -> [BarEntry] { part ?? [] }
    static func buildEither(first part: [BarEntry]) -> [BarEntry] { part.map { prefixed($0, "a") } }
    static func buildEither(second part: [BarEntry]) -> [BarEntry] { part.map { prefixed($0, "b") } }

    private static func prefixed(_ entry: BarEntry, _ prefix: String) -> BarEntry {
        var entry = entry
        entry.id = entry.id.isEmpty ? prefix : "\(prefix).\(entry.id)"
        return entry
    }
}

private struct BarEntriesKey: PreferenceKey {
    static var defaultValue: [BarEntry] { [] }
    static func reduce(value: inout [BarEntry], nextValue: () -> [BarEntry]) { value += nextValue() }
}

/// 在修饰器自己的 body 里求值：按钮读到的状态只让这个修饰器更新，不牵连所在的页面。
private struct PageBarItems: ViewModifier {
    let source: String
    let items: () -> [BarEntry]

    func body(content: Content) -> some View {
        let entries = items().map { entry -> BarEntry in
            var entry = entry
            entry.id = "\(source)/\(entry.id)"
            return entry
        }
        // 外层视图的按钮排在里层的前面
        content.transformPreference(BarEntriesKey.self) { $0.insert(contentsOf: entries, at: 0) }
    }
}

extension View {
    /// 页面的按钮：显示在页面顶部的按钮栏中。
    func pageBar(file: String = #fileID, line: Int = #line, @BarBuilder _ items: @escaping () -> [BarEntry]) -> some View {
        modifier(PageBarItems(source: "\(file):\(line)", items: items))
    }

    /// 画出页面的按钮栏（页面的根视图上用一次）。`title` 不为空时在最左边显示标题，`subtitle` 显示在标题下方。
    func pageBarRoot(title: String = "", subtitle: String = "") -> some View {
        modifier(PageBarRoot(title: title, subtitle: subtitle))
    }

    /// 页面的副标题：显示在标题下方，空字符串表示不显示。
    func pageSubtitle(_ page: PageID, _ text: String) -> some View {
        onChange(of: text, initial: true) { _, t in
            if PageTitles.shared.subtitles[page] != t { PageTitles.shared.subtitles[page] = t }
        }
    }
}

/// 各页面的副标题（例如周报的小节），显示在标题下方。
@MainActor @Observable
final class PageTitles {
    static let shared = PageTitles()
    var subtitles: [PageID: String] = [:]
}

// MARK: - 按钮栏

enum PageBarMetrics {
    /// 和系统的统一工具栏一样高
    static let height: CGFloat = 52
    /// 一块玻璃的高度
    static let itemHeight: CGFloat = 36
    /// 左边要让开红绿灯时的缩进
    static let trafficLights: CGFloat = 92
}

private struct PageBarRoot: ViewModifier {
    var title: String
    var subtitle: String

    func body(content: Content) -> some View {
        content
            // 滚动的内容从栏下面穿过时模糊、压暗（和系统工具栏一样）
            .scrollEdgeEffectStyle(.hard, for: .top)
            // 这一条只占位置（并带来滚动边缘效果），按钮画在上面的一层里：偏好值只能在外层读到
            .safeAreaBar(edge: .top, spacing: 0) { Color.gray.opacity(0.002).frame(height: PageBarMetrics.height) }
            .overlayPreferenceValue(BarEntriesKey.self, alignment: .top) { entries in
                PageBarRow(entries: entries, title: title, subtitle: subtitle)
            }
    }
}

private struct PageBarRow: View {
    var entries: [BarEntry]
    var title: String
    var subtitle: String
    @Environment(\.windowChrome) private var chrome
    @Environment(\.page) private var pageState

    var body: some View {
        // 放不下时分段控件收成一个菜单按钮
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .frame(height: PageBarMetrics.height)
        .frame(maxWidth: .infinity)
        // 空白处拖动窗口、双击缩放
        .background {
            Color.clear.contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded { TitlebarFix.titlebarDoubleClick() })
                .allowsWindowActivationEvents(true)
        }
        // 保留的页面隐藏后按钮上的快捷键（例如保存 ⌘S）不应再响应
        .disabled(!pageState.active)
    }

    private func row(compact: Bool) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if chrome.showsSidebarButton {
                    BarGlass { Button("显示边栏", systemImage: "sidebar.leading") { chrome.toggleSidebar() }.help("显示边栏") }
                }
                if !title.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .padding(.horizontal, 6)
                    .allowsHitTesting(false)
                }
                group(.leading)
                Spacer(minLength: 8)
                group(.trailing)
                group(.primary)
            }
            .environment(\.barCompact, compact)
        }
        .padding(.leading, chrome.leadingInset)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func group(_ placement: BarPlacement) -> some View {
        ForEach(Self.trimmed(entries.filter { $0.placement == placement })) { entry in
            switch entry.kind {
            case .spacer: Color.clear.frame(width: 4, height: 1)
            case .item: BarGlass(prominent: entry.prominent) { entry.view }
            }
        }
    }

    /// 去掉开头、结尾和连续的间隔（旁边的项没有显示时）。
    private static func trimmed(_ entries: [BarEntry]) -> [BarEntry] {
        var out: [BarEntry] = []
        for e in entries {
            if e.kind == .spacer, out.last.map({ $0.kind == .spacer }) ?? true { continue }
            out.append(e)
        }
        if out.last?.kind == .spacer { out.removeLast() }
        return out
    }
}

/// 一块玻璃：里面的按钮共用。
private struct BarGlass<Content: View>: View {
    var prominent = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .labelStyle(.iconOnly)
            .buttonStyle(BarButtonStyle())
            .environment(\.barProminent, prominent)
            .fixedSize()
            .glassEffect(prominent ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
    }
}

/// 栏中的按钮：没有自己的边框，几个按钮共用外面的一块玻璃。
private struct BarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.barProminent) private var prominent
    @Environment(\.appearsActive) private var appearsActive

    func makeBody(configuration: Configuration) -> some View {
        // 窗口不在前面时着色的玻璃变灰，白字看不清，换回普通的文字颜色
        let prominent = prominent && appearsActive
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .imageScale(.large)
            .lineLimit(1)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 10)
            .frame(minWidth: PageBarMetrics.itemHeight)
            .frame(height: PageBarMetrics.itemHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// 栏中的分段控件：一块玻璃里选中的一段稍亮（和系统工具栏中的分段控件一样）；栏放不下时收成显示当前项的菜单按钮。
struct BarSegmented<Value: Hashable>: View {
    var items: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.barCompact) private var compact
    @Namespace private var ns

    init(_ items: [(Value, String)], selection: Binding<Value>) {
        self.items = items.map { (value: $0.0, label: $0.1) }
        _selection = selection
    }

    var body: some View {
        if compact {
            Button {
                MenuBuilder.popUp(items.map { item in .action(item.label, checked: item.value == selection) { selection = item.value } })
            } label: {
                HStack(spacing: 5) {
                    Text(items.first { $0.value == selection }?.label ?? "")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(items, id: \.value) { item in
                    let on = item.value == selection
                    Button { selection = item.value } label: {
                        Text(item.label)
                            .font(.system(size: 13, weight: on ? .semibold : .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 13)
                            .frame(height: PageBarMetrics.itemHeight - 8)
                            .background { if on { Capsule().fill(.primary.opacity(0.16)).matchedGeometryEffect(id: "selection", in: ns) } }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .animation(.snappy(duration: 0.2), value: selection)
        }
    }
}

/// 栏中显示当前值的菜单按钮（图标、文字加一个向下的箭头），点击后在鼠标处弹出菜单。
struct BarMenu: View {
    var title: String
    var icon: String?
    var menu: () -> [MenuSpec]

    init(_ title: String, icon: String? = nil, menu: @escaping () -> [MenuSpec]) {
        self.title = title
        self.icon = icon
        self.menu = menu
    }

    var body: some View {
        Button { MenuBuilder.popUp(menu()) } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BarCompactKey: EnvironmentKey { static let defaultValue = false }
private struct BarProminentKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 按钮栏放不下，分段控件收成菜单按钮
    fileprivate var barCompact: Bool {
        get { self[BarCompactKey.self] }
        set { self[BarCompactKey.self] = newValue }
    }

    fileprivate var barProminent: Bool {
        get { self[BarProminentKey.self] }
        set { self[BarProminentKey.self] = newValue }
    }
}

// MARK: - 窗口

/// 窗口标题栏的状态：按钮栏据此决定左边是否让开红绿灯、是否自己提供显示侧栏的按钮。
// 只在主线程使用；不标 @MainActor，才能作为环境值的默认值
@Observable
final class WindowChrome {
    /// 窗口有没有侧栏（主窗口）
    var hasSidebar: Bool
    var sidebarHidden = false
    var fullScreen = false

    init(hasSidebar: Bool = false) { self.hasSidebar = hasSidebar }

    /// 主窗口
    nonisolated(unsafe) static let main = WindowChrome(hasSidebar: true)
    nonisolated(unsafe) static let plain = WindowChrome()

    /// 侧栏收起时按钮栏最左边放一个显示侧栏的按钮（展开时这个按钮在侧栏顶部）
    var showsSidebarButton: Bool { hasSidebar && sidebarHidden }

    /// 红绿灯在按钮栏上方时（没有侧栏挡着、不是全屏）让开它们
    var leadingInset: CGFloat {
        if fullScreen || (hasSidebar && !sidebarHidden) { return 12 }
        return PageBarMetrics.trafficLights
    }

    /// 显示或隐藏侧栏（主窗口的根视图提供；不走响应链，窗口不是关键窗口时也能用）
    @ObservationIgnored var toggleSidebar: @MainActor () -> Void = {}
}

private struct WindowChromeKey: EnvironmentKey {
    static var defaultValue: WindowChrome { .plain }
}

extension EnvironmentValues {
    var windowChrome: WindowChrome {
        get { self[WindowChromeKey.self] }
        set { self[WindowChromeKey.self] = newValue }
    }
}

extension View {
    /// 窗口不用系统工具栏（按钮栏由页面自己画），保留红绿灯。
    func windowBarChrome(_ chrome: WindowChrome) -> some View {
        // 留一个看不见的项目：窗口有工具栏时标题栏才是统一工具栏的高度，红绿灯和按钮栏的按钮在同一条线上
        toolbar { ToolbarItem { Color.clear.frame(width: 1, height: 1) } }
            .toolbarVisibility(.hidden, for: .windowToolbar)
            .background(TitlebarFix(chrome: chrome))
            .environment(\.windowChrome, chrome)
    }
}

/// 隐藏系统工具栏后把红绿灯留住。
///
/// SwiftUI 隐藏窗口工具栏时把整个标题栏（连同红绿灯）一起隐藏。这里把标题栏重新显示出来，只隐藏其中红绿灯以外的部分
/// （工具栏的视图即使是空的也会吞掉点击）：标题栏仍是统一工具栏的高度，红绿灯在原来的位置，
/// 其余地方的点击落到下面页面自己的按钮栏上。只按视图的层级关系操作（红绿灯的上一层是标题栏），不依赖系统内部的类名；
/// 层级不是预期的样子时什么都不做，退化为没有红绿灯（菜单和快捷键仍可关闭、最小化窗口）。
/// 全屏时系统把标题栏（和红绿灯）移到另一个盖在内容顶部的窗口里，把那个窗口变成透明的、不接收鼠标。
struct TitlebarFix: NSViewRepresentable {
    var chrome: WindowChrome

    func makeNSView(context: Context) -> NSView { Probe(chrome: chrome) }
    func updateNSView(_ view: NSView, context: Context) {}

    /// 双击按钮栏空白处：按系统设置缩放或最小化窗口（和双击标题栏一样）。
    @MainActor
    static func titlebarDoubleClick() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    private final class Probe: NSView {
        let chrome: WindowChrome
        private var observers: [NSObjectProtocol] = []
        private var hiddenObservation: NSKeyValueObservation?
        private var alphaObservation: NSKeyValueObservation?

        init(chrome: WindowChrome) {
            self.chrome = chrome
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = []
            hiddenObservation = nil
            alphaObservation = nil
            observedBar = nil
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            }
            // 进入全屏的动画一开始就不再让开红绿灯
            observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.chrome.fullScreen = true }
            })
            apply()
        }

        /// 正在观察的标题栏（全屏时红绿灯换到系统的另一个窗口里，标题栏是另一个视图）
        private weak var observedBar: NSView?

        private func apply() {
            guard let window else { return }
            let fullScreen = window.styleMask.contains(.fullScreen)
            if chrome.fullScreen != fullScreen { chrome.fullScreen = fullScreen }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview,
                  buttons.allSatisfy({ $0.superview === bar }) else { return }
            // 全屏时红绿灯在系统的另一个窗口里（见下）
            let overlay = bar.window.flatMap { $0 === window ? nil : $0 }
            if container.isHidden { container.isHidden = false }
            let alpha: CGFloat = overlay == nil ? 1 : 0
            if bar.alphaValue != alpha { bar.alphaValue = alpha }
            for view in bar.subviews where !buttons.contains(where: { $0 === view }) && !view.isHidden { view.isHidden = true }
            // 全屏时系统把标题栏放进另一个窗口，盖在内容顶部并拦住点击：把它变成透明的、不接收鼠标，下面页面的按钮栏才看得见、点得到。
            // 这样全屏时没有红绿灯（鼠标移到屏幕顶部时也不出现），用菜单“显示 > 退出全屏幕”或 ⌃⌘F 退出
            if let overlay {
                if overlay.isOpaque { overlay.isOpaque = false }
                if overlay.backgroundColor != .clear { overlay.backgroundColor = .clear }
                if !overlay.ignoresMouseEvents { overlay.ignoresMouseEvents = true }
                // 标题栏旁边还有不透明的底色
                for view in container.subviews where view !== bar && !view.isHidden { view.isHidden = true }
            }
            // SwiftUI 在窗口显示后才隐藏标题栏，之后更新工具栏时还会再隐藏
            if observedBar !== bar {
                observedBar = bar
                hiddenObservation = container.observe(\.isHidden) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
                alphaObservation = bar.observe(\.alphaValue) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
        }
    }
}
