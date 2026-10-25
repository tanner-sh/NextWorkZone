import AppKit
import SwiftUI

/// 快速记录：在任何应用中按全局快捷键弹出一个小窗口，记一条待办或一段日记。
/// 窗口启动时就创建好并隐藏；不激活本应用，收起后焦点自然留在之前使用的应用。
@MainActor
final class CaptureWindow {
    static let shared = CaptureWindow()
    private var panel: ClipboardPanel.Panel?
    private let model = CaptureModel()
    private var monitor: Any?

    func prepare() {
        guard panel == nil else { return }
        let panel = ClipboardPanel.Panel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 230), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.title = "快速记录"
        let host = NSHostingView(rootView: CaptureView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureWindow.shared.hide() }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        guard let panel else { return }
        if panel.isVisible && panel.isKeyWindow {
            hide()
            return
        }
        // 显示在鼠标所在屏幕的中间偏上
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + area.height * 0.62 - panel.frame.height / 2))
        }
        model.reset()
        panel.orderFrontRegardless()
        panel.makeKey()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                return self.model.handleKey(event) ? nil : event
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

@MainActor @Observable
final class CaptureModel {
    enum Mode: String, CaseIterable {
        case todo, daily
        var label: String { self == .todo ? "待办" : "日记" }
        var icon: String { self == .todo ? "checkmark.square" : "calendar" }
        var placeholder: String { self == .todo ? "要做什么？" : "记一笔，追加到今天的日记" }
    }

    static let dueOptions: [(String, () -> String?)] = [("今天", { Fmt.today() }), ("明天", { Fmt.addDays(Fmt.today(), 1) }), ("不设日期", { nil })]
    private static let modeKey = "nextworkzone.capture.mode"

    var mode: Mode = Mode(rawValue: AppPreferences.shared.string(forKey: modeKey) ?? "") ?? .todo {
        didSet { AppPreferences.shared.set(mode.rawValue, forKey: Self.modeKey) }
    }
    var text = ""
    var dueIndex = 0
    var clipboard: String?
    var error: String?
    var saved: String?
    var busy = false
    /// 每次弹出加一，界面据此聚焦输入框
    var opening = 0

    /// 每次弹出时清空并聚焦，读取剪贴板（可一键使用）
    func reset() {
        text = ""
        error = nil
        saved = nil
        busy = false
        clipboard = Pasteboard.text()?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        opening += 1
    }

    func save() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                if mode == .todo {
                    // 第一行作标题，其余作备注
                    let lines = value.components(separatedBy: "\n")
                    _ = try await API.shared.wsSaveTodo(TodoInput(title: lines[0].trimmingCharacters(in: .whitespaces), notes: lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), due: .some(Self.dueOptions[dueIndex].1())))
                    Events.workspaceChanged()
                    saved = "已加入待办"
                } else {
                    try await ClipActions.appendToDaily(value.replacing(/\n+/, with: " "))
                    saved = "已写入今天的日记"
                }
                try? await Task.sleep(for: .milliseconds(500))
                CaptureWindow.shared.hide()
            } catch {
                self.error = errorMessage(error)
                busy = false
            }
        }
    }

    /// Tab 切换类型，回车保存（⇧↩ 换行），Esc 收起。返回 true 表示已处理。
    func handleKey(_ e: NSEvent) -> Bool {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch e.keyCode {
        case 53:
            CaptureWindow.shared.hide()
            return true
        case 36, 76:
            if mods.contains(.shift) { return false }
            save()
            return true
        case 48:
            let all = Mode.allCases
            let i = all.firstIndex(of: mode) ?? 0
            mode = all[(i + (mods.contains(.shift) ? all.count - 1 : 1)) % all.count]
            return true
        default:
            if mods.contains(.command), let n = Int(e.charactersIgnoringModifiers ?? ""), (1...Mode.allCases.count).contains(n) {
                mode = Mode.allCases[n - 1]
                return true
            }
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct CaptureView: View {
    @Bindable var model: CaptureModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $model.mode) {
                    ForEach(CaptureModel.Mode.allCases, id: \.self) { m in Label(m.label, systemImage: m.icon).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("Tab 切换 · ↵ 保存 · ⇧↵ 换行 · Esc 收起").font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text(model.mode.placeholder).font(.title3).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
            }
            .frame(maxHeight: .infinity)
            HStack {
                if model.mode == .todo {
                    Picker("", selection: $model.dueIndex) {
                        ForEach(CaptureModel.dueOptions.indices, id: \.self) { Text(CaptureModel.dueOptions[$0].0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if let clip = model.clipboard, model.text.isEmpty {
                    Button {
                        model.text = clip
                        focused = true
                    } label: {
                        Label("使用剪贴板：\(String(clip.replacing(/\s+/, with: " ").prefix(40)))", systemImage: "doc.on.clipboard").lineLimit(1)
                    }
                    .help(clip)
                }
                Spacer()
                if let e = model.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                if let s = model.saved { Text(s).font(.caption).foregroundStyle(.green) }
                Button("保存") { model.save() }.buttonStyle(.borderedProminent).disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
            .controlSize(.small)
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .onChange(of: model.opening) { focused = true }
        .onChange(of: model.mode) { focused = true }
    }
}
