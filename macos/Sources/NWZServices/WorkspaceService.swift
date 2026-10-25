import Foundation
import NWZCore
import NWZWorkspace

/// 未迁移的远端来源通过此接口注入；收件箱状态和本地工作记录始终由新工作台管理。
public protocol WorkspaceRemoteSources: Sendable {
    func inboxSources() async throws -> InboxView
    func workEvents(day: String) async throws -> WorkLog
    func markActivityRead(_ ids: [String]) async throws
    func setWikiTask(page: String, task: String, done: Bool) async throws
}

public actor WorkspaceService {
    public nonisolated let store: Workspace
    private let settings: SettingsService
    private let host: any AppHost
    private let remote: (any WorkspaceRemoteSources)?
    private var lastSync: SyncReport?
    private var lastError: String?
    private var tasks: [Task<Void, Never>] = []

    public init(store: Workspace, settings: SettingsService, host: any AppHost, remote: (any WorkspaceRemoteSources)? = nil) {
        self.store = store; self.settings = settings; self.host = host; self.remote = remote
    }
    deinit { tasks.forEach { $0.cancel() } }

    public func start() {
        guard tasks.isEmpty else { return }
        tasks = [Task { [weak self] in
            while !Task.isCancelled {
                _ = try? await self?.sync()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }, Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendDueAlerts()
                do { try await Task.sleep(for: .seconds(20)) } catch { break }
            }
        }]
    }
    public func stop() { tasks.forEach { $0.cancel() }; tasks.removeAll() }

    public func getSettings() -> WorkspaceSettings {
        let config = settings.configuration.snapshot().workspace
        return .init(syncDir: config.syncDir, jiraTodos: config.jiraTodos, deviceId: store.deviceID, lastSync: lastSync, lastError: lastError, captureShortcut: config.captureShortcut, captureError: host.shortcutError(action: "capture"))
    }
    public func saveSettings(syncDir: String, jiraTodos: Bool) async throws -> WorkspaceSettings {
        let directory = syncDir.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        if !directory.isEmpty && (!FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) || !isDirectory.boolValue) {
            throw NWZError.other("同步文件夹不存在：\(directory)")
        }
        let changed = settings.configuration.snapshot().workspace.syncDir != directory
        try await settings.updateConfiguration { $0.workspace.syncDir = directory; $0.workspace.jiraTodos = jiraTodos }
        if changed { lastSync = nil; lastError = nil; _ = try? await sync() }
        return getSettings()
    }
    public func saveCaptureShortcut(_ shortcut: String) async throws -> WorkspaceSettings {
        let value = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = settings.configuration.snapshot().workspace.captureShortcut
        if let error = host.setShortcut(action: "capture", shortcut: value) { throw NWZError.other(error) }
        do { try await settings.updateConfiguration { $0.workspace.captureShortcut = value } }
        catch { _ = host.setShortcut(action: "capture", shortcut: previous); throw error }
        return getSettings()
    }
    public func sync() async throws -> SyncReport? {
        let directory = settings.configuration.snapshot().workspace.syncDir
        guard !directory.isEmpty else { return nil }
        do {
            let report = try await store.sync(at: settings.paths.syncRoot(in: URL(fileURLWithPath: directory)))
            lastSync = report; lastError = nil
            if report.imported > 0 || report.conflicts > 0 { host.emit(.init("workspace-synced", payload: .from(report))) }
            return report
        } catch { lastSync = nil; lastError = error.localizedDescription; throw error }
    }
    public func setTodoDone(_ id: String, done: Bool) async throws -> Todo {
        if let todo = try await store.todo(id), todo.source == "wiki", let page = todo.refKey, let task = id.split(separator: "-").last {
            try await remote?.setWikiTask(page: page, task: String(task), done: done)
        }
        return try await store.setTodoDone(id, done: done)
    }
    public func doc(_ id: String) async throws -> Doc? {
        let value = try await store.doc(id)
        return value?.deleted == true ? nil : value
    }
    public func saveAsset(base64: String, mime: String) async throws -> AssetMeta {
        guard let data = Data(base64Encoded: base64) else { throw NWZError.other("图片数据格式不正确") }
        return try await store.saveAsset(mime: mime, data: data)
    }
    public func toolsHidden() -> [String] { settings.configuration.snapshot().tools.hidden }
    public func setToolsHidden(_ hidden: [String]) async throws -> [String] {
        try await settings.updateConfiguration { $0.tools.hidden = hidden }
        return hidden
    }
    public func inbox() async throws -> InboxView {
        if try await store.capturesToTodos() > 0 { host.emit(.init("workspace-synced")) }
        let source = try await remote?.inboxSources() ?? InboxView()
        let entries = Dictionary(uniqueKeysWithValues: try await store.inbox().map { ($0.id, $0) })
        var ready: [InboxItem] = [], snoozed: [InboxItem] = []
        let now = Workspace.now()
        for var item in source.items + source.snoozed {
            let entry = entries[item.id], handled = entry?.handledAt ?? 0
            if item.source == "activity" {
                item.events.removeAll { Self.eventTime($0.at) <= handled }
                guard !item.events.isEmpty else { continue }
                item.at = item.events.map { Self.eventTime($0.at) }.max() ?? item.at
            } else if handled >= item.at { continue }
            item.snoozeUntil = entry?.snoozeUntil
            if let until = item.snoozeUntil, until > now { snoozed.append(item) } else { ready.append(item) }
        }
        ready.sort { $0.at > $1.at }; snoozed.sort { ($0.snoozeUntil ?? 0) < ($1.snoozeUntil ?? 0) }
        return .init(items: ready, snoozed: snoozed, notes: source.notes)
    }
    public func handleInbox(_ input: InboxHandleInput) async throws {
        if let ids = input.eventIds, !ids.isEmpty { try await remote?.markActivityRead(ids) }
        _ = try await store.setInboxState(input.id, title: input.title, handledAt: Workspace.now(), snoozeUntil: nil)
    }
    public func snoozeInbox(_ id: String, title: String, until: Int64?) async throws {
        _ = try await store.setInboxState(id, title: title, handledAt: nil, snoozeUntil: until)
    }
    public func worklog(_ day: String) async throws -> WorkLog {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: day), formatter.string(from: date) == day, let end = formatter.calendar.date(byAdding: .day, value: 1, to: date) else { throw NWZError.other("日期无效：\(day)") }
        let from = Int64(date.timeIntervalSince1970 * 1_000), to = Int64(end.timeIntervalSince1970 * 1_000)
        var result = try await remote?.workEvents(day: day) ?? WorkLog(day: day)
        result.events.removeAll { $0.system == "todo" || $0.at < from || $0.at >= to }
        for todo in try await store.todos() where todo.done && !todo.autoDone {
            if let at = todo.completedAt, at >= from && at < to {
                result.events.append(.init(at: at, system: "todo", kind: "done", title: todo.title, key: todo.refSystem == "jira" ? todo.refKey : nil))
            }
        }
        result.events.sort { $0.at < $1.at }
        return result
    }
    static func eventTime(_ value: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return Int64(date.timeIntervalSince1970 * 1_000) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return Int64(date.timeIntervalSince1970 * 1_000) }
        let fallback = DateFormatter(); fallback.locale = Locale(identifier: "en_US_POSIX"); fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return fallback.date(from: value).map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
    }
    private func sendDueAlerts() async {
        guard let alerts = try? await store.takeDueAlerts(Workspace.now()), !alerts.isEmpty else { return }
        let title = alerts.count == 1 ? (alerts[0].itemType == "todo" ? "待办提醒" : "稍后提醒") : "\(alerts.count) 条提醒"
        host.notify(title: title, body: alerts.prefix(4).map(\.title).joined(separator: "\n"))
        host.emit(.init("inbox-changed"))
    }
}
