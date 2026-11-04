import AppKit
import NWZPreview
import SwiftUI
import UniformTypeIdentifiers

/// 工作空间里的附件（待办等记录上的文件，包括图片）：文件内容存为资源，随同步一起传到其他设备。
@MainActor
enum WorkspaceFiles {
    /// 单个附件的大小上限：内容存在本机库中，并随同步复制到同步文件夹
    static let maxBytes = 100 * 1024 * 1024

    /// 把本地文件存为附件；文件夹、过大的文件跳过并提示。
    static func add(_ urls: [URL]) async throws -> [FileAttachment] {
        var result: [FileAttachment] = []
        var skipped: [String] = []
        for url in urls where url.isFileURL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true || (values?.fileSize ?? 0) > maxBytes {
                skipped.append(url.lastPathComponent)
                continue
            }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            result.append(try await add(data: data, name: url.lastPathComponent))
        }
        if !skipped.isEmpty { toast("没有添加 \(skipped.joined(separator: "、"))：不支持文件夹和超过 \(Fmt.size(maxBytes)) 的文件", error: true) }
        return result
    }

    static func add(data: Data, name: String, mime: String? = nil) async throws -> FileAttachment {
        let asset = try await API.shared.wsSaveAsset(data: data, mime: mime ?? self.mime(for: name))
        return FileAttachment(id: asset.id, name: name, mime: asset.mime, size: data.count, createdAt: asset.createdAt)
    }

    static func mime(for name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// 写到临时文件夹（保持原文件名），用于预览、复制、交给其他应用。
    static func temporaryFile(_ a: FileAttachment) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NextWorkZone/files/\(a.id)")
        let url = dir.appendingPathComponent(safeName(a.name))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await API.shared.wsAssetData(a.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    static func safeName(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return n.isEmpty || n == "." || n == ".." ? "附件" : n
    }

    /// 复制文件本身，可以粘贴到访达、聊天、邮件中；图片同时放入图像数据。
    static func copy(_ a: FileAttachment) {
        guarded {
            let url = try await temporaryFile(a)
            Pasteboard.copyFile(url, image: a.isImage ? NSImage(contentsOf: url) : nil)
            toast("已复制 \(a.name)")
        }
    }

    /// 保存到“下载”文件夹并用系统应用打开。
    static func openExternal(_ a: FileAttachment) {
        guarded {
            let path = try await API.shared.saveDownload(data: try await API.shared.wsAssetData(a.id), filename: a.name)
            toast("已保存到 \(path)")
        }
    }

    static func show(_ list: [FileAttachment], index: Int) {
        guard list.indices.contains(index) else { return }
        PreviewContent.shared.show(title: list[index].name, FileViewerView(attachments: list, index: index))
    }

    static func menu(_ list: [FileAttachment], index: Int, onRemove: ((FileAttachment) -> Void)?) -> [MenuSpec] {
        let a = list[index]
        var specs: [MenuSpec] = [
            .action("预览", icon: "eye") { show(list, index: index) },
            .action("复制文件", icon: "doc.on.doc") { copy(a) },
            .action("用系统应用打开", icon: "arrow.up.forward.app") { openExternal(a) },
            .separator,
            .action("复制文件名", icon: "doc.on.doc") {
                Pasteboard.copy(a.name)
                toast("已复制")
            },
        ]
        if let onRemove {
            specs += [.separator, .item("删除", icon: "trash", destructive: true, confirm: removeText(a)) { onRemove(a) }]
        }
        return specs
    }

    static func removeText(_ a: FileAttachment) -> String { "确认删除附件“\(a.name)”？" }

    /// 由 Markdown 中的工作空间图片（`![](ws://asset/<id>)`）得到附件，例如创建 Jira 问题时一并上传。
    static func images(inMarkdown text: String) -> [FileAttachment] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(ws://asset/([0-9a-zA-Z-]+)\)"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let idRange = Range(m.range(at: 2), in: text) else { return nil }
            let id = String(text[idRange])
            guard seen.insert(id).inserted else { return nil }
            return FileAttachment(id: id, name: "image-\(id.prefix(8)).png", mime: "image/png")
        }
    }

    /// 去掉 Markdown 中的工作空间图片（其他系统打不开 `ws://asset/` 地址）。
    static func removingImages(_ text: String) -> String {
        text.replacingOccurrences(of: #"!\[[^\]]*\]\(ws://asset/[0-9a-zA-Z-]+\)\n?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 剪贴板中可以作为附件的内容：复制的文件（访达中复制），或者没有文字的图片（截图、照片）。
@MainActor
enum PastedFiles {
    static func available(_ pb: NSPasteboard = .general) -> Bool {
        hasFiles(pb) || (pb.string(forType: .string) == nil && NSImage.canInit(with: pb))
    }

    private static func imageName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "图片 \(f.string(from: Date())).png"
    }

    private static func hasFiles(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// 存为附件：文件按原样保存，图片存为 PNG（剪贴板中有 PNG 时直接使用）。
    static func read(_ pb: NSPasteboard = .general) async throws -> [FileAttachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // 其他应用文件夹中的文件（例如微信聊天中复制的图片）没有权限读：有图片内容时用图片内容
            // 权限检查（isReadableFile）看不出其他应用文件夹的访问限制，实际打开一下
            let canOpen: (URL) -> Bool = { url in
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
                guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
                try? handle.close()
                return true
            }
            let readable = urls.filter(canOpen)
            let unreadable = urls.filter { !canOpen($0) }
            var added = try await WorkspaceFiles.add(readable)
            if !unreadable.isEmpty {
                if added.isEmpty, let png = EditorTextView.pastedImageData(pb) {
                    let name = unreadable.count == 1 && unreadable[0].pathExtension.lowercased() == "png" ? unreadable[0].lastPathComponent : imageName()
                    added.append(try await WorkspaceFiles.add(data: png, name: name, mime: "image/png"))
                } else {
                    toast("没有权限读取 \(unreadable.map(\.lastPathComponent).joined(separator: "、"))（文件在其他应用的文件夹中）。可以先存到本地再拖进来", error: true)
                }
            }
            return added
        }
        guard let png = EditorTextView.pastedImageData(pb) else { return [] }
        return [try await WorkspaceFiles.add(data: png, name: imageName(), mime: "image/png")]
    }
}

/// 在所在的视图可见时接管 ⌘V：键盘焦点不在富文本编辑器（例如在标题输入框、列表上），而剪贴板中是文件或图片时，交给 `onPaste`。
/// 文本框本来粘贴不了图片，⌘V 会没有反应。
struct PasteFilesMonitor: NSViewRepresentable {
    var onPaste: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onPaste = onPaste }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

    func makeCoordinator() -> Coordinator { Coordinator(onPaste: onPaste) }

    @MainActor
    final class Coordinator {
        var onPaste: () -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(onPaste: @escaping () -> Void) { self.onPaste = onPaste }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // 本地事件监视器在主线程上调用
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handle(event) == true }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v",
                  let view, let window = view.window, event.window === window, !view.isHiddenOrHasHiddenAncestor,
                  !(window.firstResponder is EditorTextView), PastedFiles.available() else { return false }
            onPaste()
            return true
        }
    }
}

/// 附件区：缩略图或文件图标，点击预览，右键可复制、用系统应用打开或删除；可以点按钮添加、把文件拖进来或粘贴。
struct FileAttachmentsSection: View {
    var attachments: [FileAttachment]
    var onAdd: ([FileAttachment]) -> Void
    var onRemove: (FileAttachment) -> Void

    @State private var picking = false
    @State private var busy = false
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("附件").foregroundStyle(.secondary)
                if !attachments.isEmpty { Text("\(attachments.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("添加附件", systemImage: "paperclip") { picking = true }
                    .controlSize(.small)
                    .disabled(busy)
            }
            if !attachments.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { i, a in
                        FileAttachmentTile(attachment: a) { Confirm.ask(WorkspaceFiles.removeText(a)) { onRemove(a) } }
                            .onTapGesture { WorkspaceFiles.show(attachments, index: i) }
                            .contextMenu(specs: { WorkspaceFiles.menu(attachments, index: i, onRemove: onRemove) })
                    }
                }
            }
            Text(attachments.isEmpty ? "把文件或图片拖到这里，或点“添加附件”" : "可以继续拖入文件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            add(files)
            return !files.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay { if dropping { DropHighlight(text: "添加为附件") } }
        .filePicker(isPresented: $picking) { paths in add(paths.map { URL(fileURLWithPath: $0) }) }
    }

    private func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = true
        guarded {
            defer { busy = false }
            let added = try await WorkspaceFiles.add(urls)
            if !added.isEmpty { onAdd(added) }
        }
    }
}

struct FileAttachmentTile: View {
    var attachment: FileAttachment
    var onRemove: () -> Void
    @State private var hover = false
    @State private var thumbnail: NSImage?

    var body: some View {
        let a = attachment
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.fieldFill)
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (a.name as NSString).pathExtension) ?? .data))
                        .resizable()
                        .frame(width: 40, height: 40)
                }
            }
            .frame(height: 72)
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(alignment: .topTrailing) {
                if hover {
                    GlassEffectContainer(spacing: 4) {
                        HStack(spacing: 4) {
                            Button { WorkspaceFiles.copy(a) } label: {
                                Image(systemName: "doc.on.doc").font(.caption).padding(5).glassEffect(.regular.interactive(), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("复制文件，可以粘贴到访达、聊天或邮件中")
                            Button(action: onRemove) {
                                Image(systemName: "trash").font(.caption).padding(5).glassEffect(.regular.interactive(), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("删除附件")
                        }
                    }
                    .padding(4)
                }
            }
            Text(a.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(Fmt.size(a.size)).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help("\(a.name)\n点击预览，右键可复制、用系统应用打开或删除")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: a.id) {
            if a.isImage { thumbnail = await ImageCache.shared.load("ws/\(a.id)") }
        }
    }
}

/// 附件预览窗口：图片、PDF、音视频、Office 文档由系统的快速查看显示；文本、表格、压缩包由应用层转换后显示。
private struct FileViewerView: View {
    var attachments: [FileAttachment]
    @State var index: Int

    var body: some View {
        let a = attachments[index]
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if attachments.count > 1 {
                    Button { go(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: []).help("上一个（←）").accessibilityLabel("上一个（←）")
                    Text("\(index + 1) / \(attachments.count)").font(.callout.monospacedDigit())
                    Button { go(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: []).help("下一个（→）").accessibilityLabel("下一个（→）")
                }
                Text(a.name).font(.headline).lineLimit(1)
                Text("\(Fmt.size(a.size)) · \(Fmt.time(ms: a.createdAt))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("复制", systemImage: "doc.on.doc") { WorkspaceFiles.copy(a) }
                    .help("复制文件，可以粘贴到访达、聊天或邮件中")
                Button("用系统应用打开", systemImage: "arrow.up.forward.app") { WorkspaceFiles.openExternal(a) }
                    .help("保存到“下载”文件夹并用系统应用打开")
            }
            .padding(.horizontal, 16)
            .padding(.top, 30)
            .padding(.bottom, 8)
            Divider()
            FileViewerBody(attachment: a).id(a.id)
        }
        .frame(minWidth: 600, minHeight: 420)
    }

    private func go(_ step: Int) {
        index = (index + step + attachments.count) % attachments.count
    }
}

private struct FileViewerBody: View {
    var attachment: FileAttachment
    @State private var file: URL?
    @State private var preview: AttachmentPreview?
    @State private var error: String?

    private var converted: Bool {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return AttachmentViewer.converted.contains(ext) || (attachment.mime.hasPrefix("text/") && ext != "html" && ext != "htm")
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("无法预览", systemImage: "doc.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("用系统应用打开") { WorkspaceFiles.openExternal(attachment) }
                }
            } else if let preview {
                ConvertedPreview(preview: preview, filename: attachment.name)
            } else if let file {
                QuickLookView(url: file)
            } else {
                LoadingView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            if converted {
                let data = try await API.shared.wsAssetData(attachment.id)
                let (name, mime) = (attachment.name, attachment.mime)
                preview = await Task.detached { Previewer.preview(filename: name, mime: mime, data: data) }.value
            } else {
                file = try await WorkspaceFiles.temporaryFile(attachment)
            }
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
    }
}
