import AppKit
import SwiftUI

/// 只读显示富文本（Jira 描述与评论、Wiki 页面、合并请求描述等）。
///
/// - 链接：系统内的地址在应用内打开，附件在应用内预览，其他地址用浏览器打开；
/// - 图片：点击放大查看；
/// - 任务勾选框：`onTask` 提供时可以点击；
/// - Jira 问题：显示实时的概要和状态（自动查询）。
///
/// `scrolls` 为假时高度随内容（放在外层的 ScrollView 中），为真时自己滚动（长页面）。
struct RichView: View {
    var doc: RichDoc
    var service: Service
    var scrolls = false
    var baseSize: CGFloat = 14
    var onTask: ((RichTask) -> Void)? = nil
    var onLink: ((String) -> Bool)? = nil
    var scrollToHeading: Int? = nil
    /// 图片加载后高度变化，需要重新计算大小
    @State private var version = 0

    var body: some View {
        RichTextView(doc: doc, service: service, scrolls: scrolls, baseSize: baseSize, onTask: onTask, onLink: onLink, scrollToHeading: scrollToHeading, version: version) {
            version += 1
        }
    }
}

struct RichTextView: NSViewRepresentable {
    var doc: RichDoc
    var service: Service
    var scrolls = false
    var baseSize: CGFloat = 14
    var onTask: ((RichTask) -> Void)? = nil
    /// 点击链接；返回 true 表示已处理
    var onLink: ((String) -> Bool)? = nil
    /// 滚动到第几个标题（目录）
    var scrollToHeading: Int? = nil
    var version = 0
    var onRelayout: (() -> Void)? = nil
    @Environment(AppModel.self) private var model

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let textView = RichNSTextView(usingTextLayoutManager: false)
        textView.textContainer?.widthTracksTextView = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = scrolls
        textView.isIncrementalSearchingEnabled = scrolls
        context.coordinator.textView = textView
        textView.service = service
        textView.onEndLiveResize = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.measureAfterResize else { return }
            coordinator.measureAfterResize = false
            coordinator.parent.onRelayout?()
        }
        if scrolls {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.documentView = textView
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = NSSize(width: 28, height: 20)
            textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
            return scroll
        }
        // 容器宽度由 RichNSTextView 跟随视图宽度（视图还没有宽度时不跟随，见 setFrameSize）
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.parent = self
        (c.textView as? RichNSTextView)?.service = service
        // 内容没变时比较几乎不花时间（数组共用存储时直接判定相等）；不要对整篇文档求哈希
        if c.renderedDoc != doc || c.renderedSession != model.sessionVersion || c.renderedBaseSize != baseSize {
            c.renderedDoc = doc
            c.renderedSession = model.sessionVersion
            c.renderedBaseSize = baseSize
            // 已查过的问题直接带上，免得查到后整篇再排一次
            if model.isReady(.jira) { c.issues.merge(IssueLookup.cached(doc.issueKeys(jiraBase: model.baseUrl(.jira)))) { _, b in b } }
            c.render()
            c.lookupIssues(doc)
        }
        if let h = scrollToHeading, c.scrolledHeading != h {
            c.scrolledHeading = h
            c.scroll(toHeading: h)
        } else if scrollToHeading == nil {
            // 目标清除后再次指向同一个标题时也要滚动
            c.scrolledHeading = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard !scrolls, let textView = context.coordinator.textView, let container = textView.textContainer, let layout = textView.layoutManager else { return nil }
        let c = context.coordinator
        let frameWidth = textView.frame.width
        // 没有建议宽度或建议无限宽（求理想大小）时按当前宽度排版
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = (proposed ?? (frameWidth >= RichNSTextView.minLayoutWidth ? frameWidth : 600)).rounded()
        if let cached = c.heights[width] { return CGSize(width: width, height: cached) }
        // 长文（例如几千段的周报页）按新宽度完整排版一次要将近一秒，拖动窗口边框时每帧都排会卡住：
        // 拖动期间先按最接近宽度的高度按比例估计，松开后再按最终宽度精确计算（见 RichNSTextView.viewDidEndLiveResize）。
        // 不要在后台线程排版副本：NSAttributedString 的副本和原文共用同一个 NSTextTable，表格在里面缓存排版结果，
        // 两个线程同时用会损坏它，绘制时崩溃。也不要打开 allowsNonContiguousLayout：表格在这种模式下后半部分画不出来
        if textView.inLiveResize, (textView.textStorage?.length ?? 0) > RichNSTextView.longText,
           let near = c.heights.min(by: { abs($0.key - width) < abs($1.key - width) }) {
            c.measureAfterResize = true
            return CGSize(width: width, height: ceil(near.value * near.key / width))
        }
        // 求最小尺寸时 SwiftUI 会用 0 之类的宽度询问：按这种宽度排版长文要几秒（每个字一行），直接用已知的高度回答
        if width < RichNSTextView.minLayoutWidth { return CGSize(width: width, height: c.heights.values.max() ?? 0) }
        // 按建议的宽度排版求高度，结果按宽度缓存（SwiftUI 会用不同宽度多次询问）
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
        c.heights[width] = height
        // 之后显示时按实际宽度排版（实际宽度还不可用时保持刚才的宽度，避免再排一遍）
        if frameWidth >= RichNSTextView.minLayoutWidth { container.containerSize = NSSize(width: frameWidth, height: .greatestFiniteMagnitude) }
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextView!
        weak var textView: NSTextView?
        var renderedDoc: RichDoc?
        var renderedSession = -1
        var renderedBaseSize: CGFloat = 0
        var scrolledHeading: Int?
        var issues: [String: IssueSummary] = [:]
        /// 各宽度下的高度（内容变化后清空）
        var heights: [CGFloat: CGFloat] = [:]
        /// 缩放窗口期间用了估计的高度，松开后要重新计算
        var measureAfterResize = false
        private var relayout: Task<Void, Never>?

        func render() {
            guard let textView else { return }
            var renderer = RichRenderer(service: parent.service, issues: issues, baseSize: parent.baseSize) { [weak self] in self?.imageLoaded() }
            #if DEBUG
            let t0 = Date()
            defer { debugLog("RICH rendered \(parent.doc.blocks.count) blocks in \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
            #endif
            let text = renderer.render(parent.doc)
            heights = [:]
            textView.textStorage?.setAttributedString(text)
            textView.invalidateIntrinsicContentSize()
            // SwiftUI 可能在换上新内容之前就量过高度：换好后再量一次
            if !parent.scrolls {
                DispatchQueue.main.async { [weak self] in self?.parent.onRelayout?() }
            }
        }

        /// 图片加载完成：稍后统一重新排版（大量图片时不必每张都排一次）。
        private func imageLoaded() {
            relayout?.cancel()
            relayout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let tv = self?.textView, let lm = tv.layoutManager, let storage = tv.textStorage else { return }
                lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
                self?.heights = [:]
                tv.invalidateIntrinsicContentSize()
                tv.needsDisplay = true
                // 让 SwiftUI 重新计算高度
                if self?.parent.scrolls == false { self?.parent.onRelayout?() }
            }
        }

        /// 查询文档中 Jira 问题的概要和状态。
        func lookupIssues(_ doc: RichDoc) {
            guard AppModel.shared.isReady(.jira) else { return }
            let keys = doc.issueKeys(jiraBase: AppModel.shared.baseUrl(.jira)).filter { issues[$0] == nil }
            guard !keys.isEmpty else { return }
            Task {
                let found = await IssueLookup.fetch(keys)
                guard !found.isEmpty else { return }
                issues.merge(found) { _, b in b }
                render()
            }
        }

        func scroll(toHeading index: Int) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            var target: NSRange?
            storage.enumerateAttribute(.nwzHeading, in: NSRange(location: 0, length: storage.length)) { v, range, stop in
                if (v as? Int) == index { target = range; stop.pointee = true }
            }
            guard let target, let lm = tv.layoutManager, let container = tv.textContainer else { return }
            let glyphs = lm.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
            if parent.scrolls {
                tv.scroll(NSPoint(x: 0, y: max(rect.minY + tv.textContainerInset.height - 8, 0)))
            } else if let clip = tv.enclosingScrollView?.contentView {
                // 放在外层的滚动视图中：把标题滚到可见区域顶部
                let target = tv.convert(NSRect(x: 0, y: rect.minY + tv.textContainerInset.height - 12, width: 1, height: clip.bounds.height), to: clip.documentView)
                clip.scroll(to: NSPoint(x: 0, y: max(0, min(target.minY, (clip.documentView?.frame.height ?? 0) - clip.bounds.height))))
                tv.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let href = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
            if parent.onLink?(href) == true { return true }
            RichLinks.open(href, service: parent.service)
            return true
        }

        func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
            guard let attachment = cell.attachment else { return }
            if let task = attachment as? TaskAttachment, let onTask = parent.onTask {
                onTask(task.task)
            } else if let image = attachment as? RemoteImageAttachment {
                ImageViewer.show(src: parent.renderer.absolute(image.info.full ?? image.info.src), service: parent.service, alt: image.info.alt ?? "")
            }
        }
    }

    var renderer: RichRenderer { RichRenderer(service: service) }
}

/// 只读的富文本视图。
///
/// 文字容器的宽度跟随视图宽度，但视图还没有宽度（刚创建、隐藏时为 0）时不跟随：
/// 按 0 宽度排版长文要几秒（每个字一行），之后还要按实际宽度再排一遍。
final class RichNSTextView: NSTextView {
    /// 小于这个宽度时不排版
    static let minLayoutWidth: CGFloat = 50
    /// 超过这个字数算长文：拖动窗口边框时不逐帧完整排版
    static let longText = 20_000
    /// 内容所属的系统（右键菜单中打开链接、图片时使用）
    var service: Service = .jira
    /// 窗口缩放结束
    var onEndLiveResize: (() -> Void)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let specs = RichContextMenu.specs(self, at: convert(event.locationInWindow, from: nil), service: service)
        return specs.isEmpty ? super.menu(for: event) : MenuBuilder.menu(specs)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width >= Self.minLayoutWidth, let container = textContainer else { return }
        let width = newSize.width - textContainerInset.width * 2
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }
}

/// 富文本中链接的处理。
@MainActor
enum RichLinks {
    /// 附件下载地址（Jira、Wiki）：在应用内预览。
    static func isAttachment(_ url: String) -> Bool {
        url.firstMatch(of: /\/(secure\/attachment|download\/attachments|download\/thumbnails)\//) != nil
    }

    static func open(_ href: String, service: Service) {
        if href.hasPrefix("nwz-issue:") {
            AppModel.shared.navigate(NavTarget(.jira, issueKey: String(href.dropFirst(10))))
        } else if href.hasPrefix("nwz-image:") {
            ImageViewer.show(src: String(href.dropFirst(10)), service: service, alt: "")
        } else if href.hasPrefix("nwz-mention:") {
            // 提及：暂不处理
        } else if href.hasPrefix("ws://doc/") {
            let id = String(href.dropFirst(9))
            Task {
                if let doc = try? await API.shared.wsDoc(id) { AppModel.shared.navigate(NavTarget(doc.kind == "page" ? .kb : .notes, docId: doc.id)) } else { toast("文档已被删除", error: true) }
            }
        } else if href.hasPrefix("#") {
            // 页面内锚点：暂不处理
        } else if href.hasPrefix("mailto:") {
            Links.openInBrowser(href)
        } else if let path = ImageCache.path(service: service, src: href), isAttachment(href) {
            let name = (href.components(separatedBy: "?")[0].components(separatedBy: "/").last ?? "附件").removingPercentEncoding ?? "附件"
            AttachmentViewer.show(Attachment(id: path, filename: name, size: 0, mimeType: AttachmentViewer.guessMime(name), contentUrl: href, thumbnailUrl: nil, author: "", created: ""), service: service)
        } else {
            Links.open(href)
        }
    }
}

/// 批量查询问题的概要和状态（Jira 未配置或查询失败时为空）。
enum IssueLookup {
    nonisolated(unsafe) private static var cache: [String: IssueSummary] = [:]

    /// 已经查过的问题（不发请求）。
    @MainActor
    static func cached(_ keys: [String]) -> [String: IssueSummary] {
        var map: [String: IssueSummary] = [:]
        for k in keys { if let hit = cache[k] { map[k] = hit } }
        return map
    }

    @MainActor
    static func fetch(_ keys: [String]) async -> [String: IssueSummary] {
        var map: [String: IssueSummary] = [:]
        let missing = keys.filter { k in
            if let hit = cache[k] { map[k] = hit; return false }
            return true
        }
        var i = 0
        while i < missing.count {
            let chunk = Array(missing[i..<min(i + 100, missing.count)])
            i += 100
            if let r = try? await API.shared.jiraSearch("key in (\(chunk.joined(separator: ",")))", startAt: 0, maxResults: chunk.count) {
                for issue in r.issues { map[issue.key] = issue; cache[issue.key] = issue }
            } else {
                // 某个问题不存在或没有权限时整批会失败，逐个再试
                for key in chunk {
                    if let r = try? await API.shared.jiraSearch("key = \(key)", startAt: 0, maxResults: 1), let issue = r.issues.first {
                        map[key] = issue
                        cache[key] = issue
                    }
                }
            }
        }
        return map
    }
}

/// 把 HTML 转为文档模型后显示（转换在后台完成）。
struct RichHTML: View {
    var html: String
    var service: Service
    var scrolls = false
    var baseSize: CGFloat = 14
    var onTask: ((RichTask) -> Void)? = nil
    @State private var doc: RichDoc?

    var body: some View {
        Group {
            if let doc {
                RichView(doc: doc, service: service, scrolls: scrolls, baseSize: baseSize, onTask: onTask)
            } else {
                Color.clear.frame(height: 16)
            }
        }
        .task(id: html) { doc = try? await Rich.fromHTML(html) }
    }
}
