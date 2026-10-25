import Foundation
import NWZClipboard
import NWZCore
import NWZJira
import Synchronization

/// 剪贴板设置页需要的全部信息。
public struct ClipSettings: Codable, Hashable, Sendable {
    public var config: ClipboardConfig
    /// 内置的忽略列表（始终生效）。
    public var builtinIgnored: [IgnoredApp]
    public var stats: ClipStats
    /// `ready` / `needsPermission`
    public var pasteSupport: String
    /// 不能自动粘贴的原因。
    public var pasteNote: String?
    /// 暂停记录到何时（毫秒时间戳）；`Int64.max` 表示直到手动恢复。
    public var pausedUntil: Int64?
    public var shortcutError: String?
    /// 历史保存的位置。
    public var dataDir: String
}

/// 打开面板前位于前台的应用。
public struct ClipTarget: Sendable {
    public var name: String
    public var pid: Int32?
    /// 是不是本应用（从主窗口打开的面板）。
    public var isSelf: Bool
}

/// 拖到其他应用的文件和预览图（PNG）。
public struct DragFiles: Sendable {
    public var paths: [String]
    public var preview: Data
}

/// 剪贴板历史：在后台记录复制过的内容，把选中的条目写回剪贴板并粘贴到之前使用的应用。
///
/// 面板窗口由界面实现：打开面板前调用 [`captureTarget`] 记下位于前台的应用，收起面板由
/// [`AppHost.hideClipboardPanel`] 完成。
public final class ClipboardService: Sendable {
    /// 记录到新内容（或再次复制了已有内容）时发出，载荷为 [`ClipItem`]。
    public static let changedEvent = "clipboard-changed"
    /// 设置、暂停状态或历史变化时发出。
    public static let settingsEvent = "clipboard-settings"
    /// 检查剪贴板是否变化的间隔。
    static let pollInterval = Duration.milliseconds(300)
    /// 自动清理过期历史的间隔。
    static let pruneInterval: TimeInterval = 3600
    /// 拖动预览图的边长（逻辑像素）。
    static let dragPreview = 96

    public let store: ClipboardStore
    private let system: any SystemClipboard
    private let settings: SettingsService
    private let host: any AppHost
    private let issueIndex: IssueIndex?
    private let state = Mutex(State())
    private let watcher = Mutex<Task<Void, Never>?>(nil)

    private struct State {
        /// 暂停记录到何时；0 表示未暂停，`Int64.max` 表示直到手动恢复。
        var pausedUntil: Int64 = 0
        /// 打开面板前位于前台的应用，粘贴到这里。
        var target: RunningApp?
        /// 本应用写入剪贴板后的变化序号，监听时跳过，不当作新复制的内容。
        var ownChange = -1
    }

    public init(store: ClipboardStore, system: any SystemClipboard, settings: SettingsService, host: any AppHost, issues: IssueIndex? = nil) {
        self.store = store; self.system = system; self.settings = settings; self.host = host; issueIndex = issues
    }

    private var config: ClipboardConfig { settings.configuration.snapshot().tools.clipboard }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func emit(_ event: String, _ payload: JSONValue = .null) { host.emit(ServiceEvent(event, payload: payload)) }

    // MARK: 后台记录

    /// 启动后台记录：此后复制的内容都会记录（启动前已在剪贴板中的不算）。
    public func start() {
        // 在这里取起点，而不是等后台任务开始运行时再取，否则这段时间内复制的内容会被当作起点漏掉
        let initial = system.changeCount()
        watcher.withLock { task in
            guard task == nil else { return }
            task = Task.detached(priority: .utility) { [weak self] in await self?.watch(from: initial) }
        }
    }

    public func stop() { watcher.withLock { $0?.cancel(); $0 = nil } }

    private func watch(from initial: Int) async {
        var lastCount = initial
        var lastPrune = Date.distantPast
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.pollInterval) } catch { return }
            if Date().timeIntervalSince(lastPrune) > Self.pruneInterval {
                lastPrune = Date()
                let config = config
                if let removed = try? await store.prune(keepDays: Int(config.keepDays), maxItems: Int(config.maxItems)), removed > 0 { emit(Self.settingsEvent) }
            }
            // 先比较变化序号（很便宜），有变化才读取内容
            let count = system.changeCount()
            guard count != lastCount else { continue }
            lastCount = count
            guard count != state.withLock({ $0.ownChange }) else { continue }
            let config = config
            guard config.enabled, paused() == nil, !system.isConcealed() else { continue }
            let source = system.frontmostApp()
            if let source, ClipPrivacy.ignored(source.id, extra: config.ignoredApps.map(\.id)) { continue }
            if let item = await record(config, source: source) { emit(Self.changedEvent, .from(item)) }
        }
    }

    private func record(_ config: ClipboardConfig, source: RunningApp?) async -> ClipItem? {
        let snapshot = system.read(withImage: config.saveImages)
        guard !snapshot.isEmpty else { return nil }
        if config.skipSecrets, let text = snapshot.text, ClipPrivacy.looksSecret(text) { return nil }
        let maxBytes = Int(config.maxImageMb) * 1024 * 1024
        let image = snapshot.image.flatMap { maxBytes == 0 || $0.pixels.count <= maxBytes ? $0 : nil }
        if let source, (try? await store.hasApp(source.id)) == false {
            try? await store.saveApp(source.id, name: source.name, iconPNG: source.path.flatMap { system.iconPNG(path: $0, size: 64) })
        }
        let capture = Capture(text: snapshot.text, html: snapshot.html, image: image, files: snapshot.files, app: source.map { ($0.id, $0.name) })
        return try? await store.add(capture)?.item
    }

    // MARK: 面板

    /// 打开面板前调用：记下位于前台的应用（粘贴到这里），返回它的名称（本应用时为 nil）。
    public func captureTarget() -> String? {
        let target = system.frontmostApp()
        state.withLock { $0.target = target }
        return target.flatMap { $0.pid == getpid() ? nil : $0.name }
    }

    /// 打开面板前位于前台的应用。
    public func target() -> ClipTarget? {
        state.withLock { $0.target }.map { ClipTarget(name: $0.name, pid: $0.pid, isSelf: $0.pid == getpid()) }
    }

    public var enabled: Bool { config.enabled }

    // MARK: 暂停

    /// 暂停到何时；未暂停时为 nil。
    public func paused() -> Int64? {
        let until = state.withLock { $0.pausedUntil }
        return until > Self.now() ? until : nil
    }

    /// 暂停记录 `minutes` 分钟；0 表示恢复，负数表示直到手动恢复。
    public func setPaused(minutes: Int) {
        let until: Int64 = minutes == 0 ? 0 : minutes < 0 ? .max : Self.now() + Int64(minutes) * 60_000
        state.withLock { $0.pausedUntil = until }
        host.clipboardPaused(paused: until != 0)
        emit(Self.settingsEvent)
    }

    /// 暂停或恢复（菜单栏）。
    public func togglePaused() { setPaused(minutes: paused() == nil ? -1 : 0) }

    // MARK: 写回剪贴板

    /// 把条目写入系统剪贴板。`plain` 只写纯文本；`edited` 是编辑后的文字（代替原内容）。
    private func write(_ ids: [String], plain: Bool, edited: String?) async throws {
        var contents: [ClipContent] = []
        for id in ids {
            guard let content = try await store.content(id) else { throw NWZError.other("条目已被删除") }
            contents.append(content)
        }
        let count: Int
        if let edited {
            count = system.write(text: edited, html: nil)
        } else if contents.count == 1, let one = contents.first {
            switch one.kind {
            case ClipKind.image:
                guard let url = one.image, let png = try? Data(contentsOf: url) else { throw NWZError.other("图片已丢失") }
                count = system.write(imagePNG: png)
            case ClipKind.file: count = system.write(files: one.files)
            default: count = system.write(text: one.text, html: plain ? nil : one.html)
            }
        } else if contents.allSatisfy({ $0.kind == ClipKind.file }) {
            // 多条一起粘贴：全是文件时合并为文件列表，否则把文字按行拼接（图片不参与）
            count = system.write(files: contents.flatMap(\.files))
        } else {
            let text = contents.filter { $0.kind != ClipKind.image }.map { $0.kind == ClipKind.file ? $0.files.joined(separator: "\n") : $0.text }.joined(separator: "\n")
            count = system.write(text: text, html: nil)
        }
        state.withLock { $0.ownChange = count }
        try await store.touch(ids)
    }

    /// 粘贴到打开面板前使用的应用：写入剪贴板、收起面板、交还焦点，有权限时模拟按下 ⌘V。
    /// 返回 `pasted`（已粘贴）或 `copied`（只复制了，需要用户自己粘贴）。
    public func paste(_ ids: [String], plain: Bool?, edited: String?) async throws -> String {
        let config = config
        try await write(ids, plain: plain ?? config.plainText, edited: edited)
        emit(Self.settingsEvent)
        let target = state.withLock { $0.target }
        host.hideClipboardPanel(restore: true)
        guard config.autoPaste, system.canPaste() else { return "copied" }
        let system = system
        Task.detached {
            // 等待目标应用回到前台（最多 1 秒），再留一点时间让目标窗口的输入框重新获得焦点
            if let pid = target?.pid {
                let started = Date()
                while Date().timeIntervalSince(started) < 1, system.frontmostApp()?.pid != pid { try? await Task.sleep(for: .milliseconds(15)) }
            }
            try? await Task.sleep(for: .milliseconds(60))
            system.sendPaste()
        }
        return "pasted"
    }

    /// 只复制到剪贴板（不收起面板、不粘贴）。
    public func copy(_ ids: [String], plain: Bool?, edited: String?) async throws {
        try await write(ids, plain: plain ?? false, edited: edited)
        emit(Self.settingsEvent)
    }

    // MARK: 历史

    public func list(_ query: ClipQuery) async throws -> [ClipItem] { try await store.list(query) }

    /// 文字条目的完整内容（列表中只有开头一部分）。
    public func text(_ id: String) async throws -> ClipText {
        guard let content = try await store.content(id) else { throw NWZError.other("条目已被删除") }
        return ClipText(text: content.text, html: content.html)
    }

    /// 修改历史后通知各窗口刷新。
    private func changed<T>(_ body: () async throws -> T) async throws -> T {
        let result = try await body()
        emit(Self.settingsEvent)
        return result
    }

    public func delete(_ ids: [String]) async throws { try await changed { try await store.delete(ids) } }
    public func clear() async throws -> Int { try await changed { try await store.clearHistory() } }
    public func setPinboard(_ ids: [String], pinboard: String?) async throws { try await changed { try await store.setPinboard(ids, pinboard: pinboard) } }
    public func rename(_ id: String, title: String) async throws -> ClipItem? { try await changed { try await store.rename(id, title: title) } }
    public func updateText(_ id: String, text: String) async throws -> ClipItem? { try await changed { try await store.updateText(id, text: text) } }
    public func pinboards() async throws -> [Pinboard] { try await store.pinboards() }
    public func savePinboard(id: String?, name: String, color: String) async throws -> Pinboard { try await changed { try await store.savePinboard(id: id, name: name, color: color) } }
    public func deletePinboard(_ id: String) async throws { try await changed { try await store.deletePinboard(id) } }
    public func orderPinboards(_ ids: [String]) async throws { try await changed { try await store.orderPinboards(ids) } }
    public func apps() async throws -> [ClipApp] { try await store.apps() }
    /// 标记为刚刚使用（拖到其他应用后），下次打开面板时排在最前面。
    public func touch(_ ids: [String]) async throws { try await store.touch(ids) }

    /// 本机问题库中的问题（剪贴板中出现的问题键显示概要和状态）。
    public func issues(_ keys: [String]) async throws -> [IssueHit] { try await issueIndex?.byKeys(keys) ?? [] }

    // MARK: 设置

    public func settingsView() async throws -> ClipSettings {
        ClipSettings(config: config,
                     builtinIgnored: ClipPrivacy.defaultIgnoredApps.map { IgnoredApp(id: $0.id, name: $0.name) },
                     stats: try await store.stats(),
                     pasteSupport: system.canPaste() ? "ready" : "needsPermission",
                     pasteNote: nil, pausedUntil: paused(),
                     shortcutError: host.shortcutError(action: "clipboard"),
                     dataDir: store.directory.path)
    }

    /// 保存设置：快捷键或开关变化时重新注册快捷键（失败时不保存），并按新的保留规则清理历史。
    public func saveSettings(_ next: ClipboardConfig) async throws -> ClipSettings {
        func shortcut(_ c: ClipboardConfig) -> String { c.enabled ? c.shortcut.trimmingCharacters(in: .whitespaces) : "" }
        if shortcut(config) != shortcut(next), let error = host.setShortcut(action: "clipboard", shortcut: shortcut(next)) { throw NWZError.other(error) }
        if !next.enabled { host.hideClipboardPanel(restore: false) }
        _ = try await store.prune(keepDays: Int(next.keepDays), maxItems: Int(next.maxItems))
        try await settings.updateConfiguration { $0.tools.clipboard = next }
        emit(Self.settingsEvent)
        return try await settingsView()
    }

    public func pause(minutes: Int) async throws -> ClipSettings {
        setPaused(minutes: minutes)
        return try await settingsView()
    }

    public func requestPermission() { system.requestPastePermission() }

    /// 最近记录过的来源应用中尚未忽略的（设置页中选择要忽略的应用）。
    public func ignoreCandidates() async throws -> [IgnoredApp] {
        let extra = config.ignoredApps.map(\.id)
        return try await store.apps().filter { !ClipPrivacy.ignored($0.id, extra: extra) }.map { IgnoredApp(id: $0.id, name: $0.name) }
    }

    // MARK: 拖到其他应用

    /// 把图片、文件条目准备为可以拖到其他应用（访达、聊天、邮件等）的文件。文字由界面直接处理。
    ///
    /// 图片先导出到临时文件夹，文件名带上复制时间；文件条目中已经不存在的路径会被跳过。
    /// `fallbackIcon` 是没有缩略图时使用的预览图（应用图标）。
    /// 拖动开始时必须立即给出文件，所以直接使用界面中已有的条目，不再查询数据库。
    public func dragFiles(_ items: [ClipItem], fallbackIcon: Data) throws -> DragFiles {
        var paths: [String] = [], preview: Data?
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("NextWorkZone/drag", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        for item in items {
            let id = item.id
            switch item.kind {
            case ClipKind.image:
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
                let time = formatter.string(from: Date(timeIntervalSince1970: Double(item.copiedAt) / 1000))
                let name = item.title.trimmingCharacters(in: .whitespaces).isEmpty ? "剪贴板图片 \(time)" : Self.sanitizeFileName(item.title)
                let target = exportDir.appendingPathComponent(name + ".png")
                try? FileManager.default.removeItem(at: target)
                do { try FileManager.default.copyItem(at: store.imageURL(id), to: target) } catch { throw NWZError.other("图片已丢失：\(error.localizedDescription)") }
                if preview == nil { preview = (try? Data(contentsOf: store.thumbURL(id))).flatMap { ClipImages.shrinkPNG($0, max: Self.dragPreview) } }
                paths.append(target.path)
            case ClipKind.file:
                for file in item.files where FileManager.default.fileExists(atPath: file) {
                    if preview == nil { preview = system.iconPNG(path: file, size: 64) }
                    paths.append(file)
                }
            default: break
            }
        }
        guard !paths.isEmpty else { throw NWZError.other("没有可以拖出的文件（原文件可能已被移动或删除）") }
        return DragFiles(paths: paths, preview: preview ?? ClipImages.shrinkPNG(fallbackIcon, max: 64) ?? Data())
    }

    /// 去掉文件名中不允许的字符。
    static func sanitizeFileName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).map { "/\\:*?\"<>|".contains($0) || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true ? "_" : $0 }.prefix(80))
    }
}
