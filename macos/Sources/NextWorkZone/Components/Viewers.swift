import AppKit
import AVKit
import PDFKit
import Quartz
import SwiftUI

/// 预览窗口：图片、附件在单独的窗口中查看，Esc 关闭，← → 切换附件。
@MainActor
final class PreviewWindow: NSObject, NSWindowDelegate {
    static let shared = PreviewWindow()
    private var window: NSWindow?

    func show<V: View>(title: String, _ content: V) {
        let host = NSHostingController(rootView: content.environment(AppModel.shared))
        if window == nil {
            let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.delegate = self
            w.setFrameAutosaveName("NextWorkZonePreview")
            if !w.setFrameUsingName("NextWorkZonePreview") { w.center() }
            window = w
        }
        window?.contentViewController = host
        window?.title = title
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() { window?.orderOut(nil) }

    /// Esc 关闭。
    private final class KeyWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    }
}

/// 放大查看图片（可缩放）。
@MainActor
enum ImageViewer {
    static func show(src: String, service: Service, alt: String) {
        PreviewWindow.shared.show(title: alt.isEmpty ? "图片" : alt, ImageViewerView(src: src, service: service))
    }
}

private struct ImageViewerView: View {
    var src: String
    var service: Service
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
            } else if failed {
                ContentUnavailableView("无法加载图片", systemImage: "photo", description: Text("可能需要先网页登录"))
            } else {
                LoadingView()
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .task {
            if let path = ImageCache.path(service: service, src: src) {
                image = await ImageCache.shared.load(path)
            } else if src.hasPrefix("ws://asset/") {
                image = await ImageCache.shared.load("ws/\(src.dropFirst(11))")
            } else if let url = URL(string: src), let (data, _) = try? await URLSession.shared.data(from: url) {
                image = NSImage(data: data)
            }
            failed = image == nil
        }
    }
}

/// 可缩放、拖动的图片（NSScrollView 的放大功能）。
struct ZoomableImage: NSViewRepresentable {
    var image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = .windowBackgroundColor
        let view = NSImageView(image: image)
        view.imageScaling = .scaleNone
        view.frame = CGRect(origin: .zero, size: image.size)
        scroll.documentView = view
        DispatchQueue.main.async {
            let fit = min(scroll.bounds.width / max(image.size.width, 1), scroll.bounds.height / max(image.size.height, 1), 1)
            scroll.magnification = fit
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

/// 附件预览：图片、PDF、音视频、Office 文档由系统的快速查看显示；文本、表格、压缩包由应用层转换后显示（能识别 GBK 等编码）。
@MainActor
enum AttachmentViewer {
    static func show(_ attachment: Attachment, service: Service) {
        show([attachment], index: 0, service: service)
    }

    static func show(_ attachments: [Attachment], index: Int, service: Service) {
        PreviewWindow.shared.show(title: attachments[index].filename, AttachmentViewerView(attachments: attachments, index: index, service: service))
    }

    /// 按扩展名推测文件类型，用于预览只有地址的附件链接。
    static func guessMime(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg"].contains(ext) { return ext == "jpg" ? "image/jpeg" : ext == "svg" ? "image/svg+xml" : "image/\(ext)" }
        if ext == "pdf" { return "application/pdf" }
        if ["mp4", "mov", "webm"].contains(ext) { return ext == "mov" ? "video/quicktime" : "video/\(ext)" }
        return "application/octet-stream"
    }

    /// 由 NWZPreview 转换后预览的文件类型。
    static let converted: Set<String> = Set("csv tsv zip jar war txt log out err trace md json xml yaml yml sql ini conf cfg properties java js ts tsx jsx py rs go c h cpp cs kt sh bat cmd ps1 css vue toml gradle jsp".split(separator: " ").map(String.init))
    /// 超过这个大小的文件不在应用内预览（需要先整个下载）。
    static let maxPreviewBytes = 30 * 1024 * 1024

    static func menu(_ a: Attachment, preview: @escaping @MainActor () -> Void, service: Service) -> [MenuSpec] {
        [
            .action("预览", icon: "eye", preview),
            .action("用系统应用打开", icon: "arrow.up.forward.app") { openExternal(a, service: service) },
            .separator,
            .action("复制文件名", icon: "doc.on.doc") {
                Pasteboard.copy(a.filename)
                toast("已复制")
            },
        ]
    }

    /// 下载到“下载”文件夹并用系统应用打开。
    static func openExternal(_ a: Attachment, service: Service) {
        guarded {
            let path = try await API.shared.jiraOpenAttachment(url: a.contentUrl, filename: a.filename, service: service)
            toast("已保存到 \(path)")
        }
    }
}

private struct AttachmentViewerView: View {
    var attachments: [Attachment]
    @State var index: Int
    var service: Service

    var body: some View {
        let a = attachments[index]
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if attachments.count > 1 {
                    Button { go(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: []).help("上一个（←）")
                    Text("\(index + 1) / \(attachments.count)").font(.callout.monospacedDigit())
                    Button { go(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: []).help("下一个（→）")
                }
                Text(a.filename).font(.headline).lineLimit(1)
                if a.size > 0 { Text("\(Fmt.size(a.size)) · \(a.author) · \(Fmt.time(a.created))").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("用系统应用打开", systemImage: "arrow.up.forward.app") { AttachmentViewer.openExternal(a, service: service) }
                    .help("下载到“下载”文件夹并用系统应用打开")
            }
            .padding(.horizontal, 16)
            .padding(.top, 30)
            .padding(.bottom, 8)
            Divider()
            AttachmentBody(attachment: a, service: service).id(a.id)
        }
        .frame(minWidth: 600, minHeight: 420)
    }

    private func go(_ step: Int) {
        index = (index + step + attachments.count) % attachments.count
    }
}

private struct AttachmentBody: View {
    var attachment: Attachment
    var service: Service
    @State private var file: URL?
    @State private var preview: AttachmentPreview?
    @State private var error: String?
    @State private var showSource = false

    private var ext: String { (attachment.filename as NSString).pathExtension.lowercased() }
    private var isHTML: Bool { ext == "html" || ext == "htm" || attachment.mimeType == "text/html" }
    private var useConverted: Bool { AttachmentViewer.converted.contains(ext) || (attachment.mimeType.hasPrefix("text/") && ext != "html" && ext != "htm") }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("无法预览", systemImage: "doc.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("用系统应用打开") { AttachmentViewer.openExternal(attachment, service: service) }
                }
            } else if let preview {
                ConvertedPreview(preview: preview, filename: attachment.filename)
            } else if let file {
                if isHTML {
                    // 网页附件：默认显示渲染后的页面，可以切换为源码
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button(showSource ? "显示网页" : "查看源码", systemImage: showSource ? "globe" : "chevron.left.forwardslash.chevron.right") { showSource.toggle() }
                        }
                        .padding(8)
                        if showSource {
                            TextPreview(text: (try? String(contentsOf: file, encoding: .utf8)) ?? "", filename: attachment.filename)
                        } else {
                            QuickLookView(url: file)
                        }
                    }
                } else {
                    QuickLookView(url: file)
                }
            } else {
                LoadingView(label: "正在下载…")
            }
        }
        .task { await load() }
    }

    private func load() async {
        if attachment.size > AttachmentViewer.maxPreviewBytes {
            error = "文件较大（\(Fmt.size(attachment.size))），请用系统应用打开。"
            return
        }
        do {
            if useConverted {
                preview = try await API.shared.jiraPreviewAttachment(url: attachment.contentUrl, filename: attachment.filename, mime: attachment.mimeType, service: service)
                return
            }
            guard let path = ImageCache.path(service: service, src: attachment.contentUrl) ?? (attachment.contentUrl.hasPrefix("/") ? nil : nil) else {
                error = "附件地址不属于已配置的系统"
                return
            }
            let (data, _) = try await API.shared.asset(path)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NextWorkZone/preview/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(attachment.filename.replacingOccurrences(of: "/", with: "_"))
            try data.write(to: url)
            file = url
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// 系统的快速查看（图片、PDF、音视频、Office 文档、网页等）。
struct QuickLookView: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

/// 应用层转换后的预览：文本、表格、文档段落、压缩包内容。
struct ConvertedPreview: View {
    var preview: AttachmentPreview
    var filename: String
    @State private var sheet = 0

    var body: some View {
        switch preview {
        case .text(let text, let truncated, let encoding):
            let note = [truncated ? "文件较大，只显示了开头的一部分" : nil, encoding.lowercased() != "utf-8" ? "编码：\(encoding)" : nil].compactMap { $0 }.joined(separator: " · ")
            TextPreview(text: text, filename: filename, note: note.isEmpty ? nil : note)
        case .sheet(let sheets):
            VStack(alignment: .leading, spacing: 0) {
                if sheets.count > 1 {
                    Picker("", selection: $sheet) {
                        ForEach(sheets.indices, id: \.self) { i in Text(sheets[i].name).tag(i) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                }
                if sheets.indices.contains(sheet) {
                    let s = sheets[sheet]
                    if s.totalRows > s.rows.count || s.totalCols > (s.rows.first?.count ?? 0) {
                        Text("共 \(s.totalRows) 行 \(s.totalCols) 列，只显示了一部分").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(s.rows.indices, id: \.self) { r in
                                GridRow {
                                    ForEach(s.rows[r].indices, id: \.self) { c in
                                        Text(s.rows[r][c])
                                            .font(.system(size: 12))
                                            .fontWeight(r == 0 ? .semibold : .regular)
                                            .lineLimit(3)
                                            .frame(minWidth: 60, maxWidth: 280, alignment: .leading)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .border(Color.secondary.opacity(0.2), width: 0.5)
                                    }
                                }
                            }
                        }
                        .textSelection(.enabled)
                        .padding(8)
                    }
                }
            }
        case .document(let paragraphs, let truncated):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(paragraphs.indices, id: \.self) { i in Text(paragraphs[i]) }
                    if truncated { Text("只显示了开头的一部分").font(.caption).foregroundStyle(.secondary) }
                }
                .textSelection(.enabled)
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
            }
        case .archive(let entries, let truncated):
            List {
                ForEach(entries.indices, id: \.self) { i in
                    let e = entries[i]
                    HStack {
                        Image(systemName: e.dir ? "folder" : "doc")
                        Text(e.name)
                        Spacer()
                        if !e.dir { Text(Fmt.size(e.size)).foregroundStyle(.secondary) }
                    }
                }
                if truncated { Text("只列出了一部分").foregroundStyle(.secondary) }
            }
        case .unsupported(let reason):
            ContentUnavailableView("无法预览", systemImage: "doc.questionmark", description: Text(reason))
        }
    }
}

/// 文本附件：等宽显示、带行号，可以只看包含某段文字的行（查日志时常用）。
/// 用 NSTextView 显示：几 MB 的文字放在 SwiftUI 的 Text 中排版要好几秒。
struct TextPreview: View {
    var text: String
    var filename: String
    var note: String? = nil
    @State private var filter = ""
    @State private var shown: (text: String, matches: Int)?

    /// 只看匹配的行时最多显示的行数。
    nonisolated static let maxLines = 5000

    var body: some View {
        let query = filter.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("只看包含这段文字的行，例如 ERROR、Exception", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                if !query.isEmpty, let shown {
                    Text(shown.matches > Self.maxLines ? "\(shown.matches) 行匹配，只显示前 \(Self.maxLines) 行" : "\(shown.matches) 行匹配").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(8)
            CodeView(code: query.isEmpty ? text : shown?.text ?? "", path: filename)
        }
        .task(id: query) {
            guard !query.isEmpty else { shown = nil; return }
            // 输入时稍等再筛选，长文件逐行比较放到后台
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let source = text
            let result = await Task.detached(priority: .userInitiated) { () -> (String, Int) in
                let lines = source.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(query) }
                return (lines.prefix(Self.maxLines).joined(separator: "\n"), lines.count)
            }.value
            if !Task.isCancelled { shown = result }
        }
    }
}
