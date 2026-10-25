import AppKit
import ApplicationServices
import NWZClipboard

/// 剪贴板历史使用的系统能力：NSPasteboard、NSWorkspace、辅助功能权限与 CGEvent。
/// 后台记录线程也会调用，这里只用可以在任意线程使用的接口。
final class MacClipboard: SystemClipboard {
    private var pasteboard: NSPasteboard { .general }

    func changeCount() -> Int { pasteboard.changeCount }

    func isConcealed() -> Bool {
        (pasteboard.types ?? []).contains { ClipPrivacy.concealedTypes.contains($0.rawValue) }
    }

    func read(withImage: Bool) -> ClipboardSnapshot {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return ClipboardSnapshot(files: urls.map(\.path)) }
        let text = pasteboard.string(forType: .string).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let html = text == nil ? nil : pasteboard.string(forType: .html).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // 有文字时以文字为准：表格软件复制单元格时还会附带一张渲染出来的图片
        var image: RGBAImage?
        if text == nil, withImage {
            let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation
            image = data.flatMap(ClipImages.decode)
        }
        return ClipboardSnapshot(text: text, html: html, image: image)
    }

    func write(text: String, html: String?) -> Int {
        pasteboard.clearContents()
        if let html { pasteboard.setString(html, forType: .html) }
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    func write(imagePNG: Data) -> Int {
        pasteboard.clearContents()
        pasteboard.setData(imagePNG, forType: .png)
        // 不少应用只认 TIFF
        if let tiff = NSBitmapImageRep(data: imagePNG)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        return pasteboard.changeCount
    }

    func write(files: [String]) -> Int {
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
        return pasteboard.changeCount
    }

    func frontmostApp() -> RunningApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let path = app.bundleURL?.path
        guard let id = app.bundleIdentifier ?? path else { return nil }
        return RunningApp(id: id, name: app.localizedName ?? id, path: path, pid: app.processIdentifier)
    }

    func iconPNG(path: String, size: Int) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = NSRect(x: 0, y: 0, width: size, height: size)
        guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func canPaste() -> Bool { AXIsProcessTrusted() }

    func requestPastePermission() {
        // kAXTrustedCheckOptionPrompt 的值；直接引用那个全局变量在 Swift 6 中会被当作可变的共享状态
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    /// ANSI 键盘布局上 V 键的虚拟键码。
    private static let keyV: CGKeyCode = 9

    func sendPaste() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: Self.keyV, keyDown: down) else { continue }
            // 只带 ⌘，即使用户还按着其他修饰键（例如用 ⌘数字 选择时）
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }
}
