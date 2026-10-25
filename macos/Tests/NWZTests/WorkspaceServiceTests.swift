import Foundation
import Synchronization
import Testing
import NWZCore
import NWZWorkspace
@testable import NWZServices

final class WorkspaceTestHost: AppHost, Sendable {
    let events = Mutex<[ServiceEvent]>([])
    let shortcuts = Mutex<[String]>([])
    func emit(_ event: ServiceEvent) { events.withLock { $0.append(event) } }
    func notify(title: String, body: String) {}
    func openPath(path: String) -> String? { nil }
    func setShortcut(action: String, shortcut: String) -> String? {
        if shortcut == "invalid" { return "快捷键无效" }
        shortcuts.withLock { $0.append(shortcut) }; return nil
    }
    func shortcutError(action: String) -> String? { nil }
    func hideClipboardPanel(restore: Bool) {}
    func clipboardPaused(paused: Bool) {}
}
private actor WorkspaceTestRemote: WorkspaceRemoteSources {
    var items: [InboxItem] = []
    var marked: [String] = []
    var taskChanges: [String] = []
    var failTask = false
    func setItems(_ value: [InboxItem]) { items = value }
    func inboxSources() -> InboxView { .init(items: items) }
    func workEvents(day: String) -> WorkLog { .init(day: day) }
    func markActivityRead(_ ids: [String]) { marked += ids }
    func setFailure() { failTask = true }
    func setWikiTask(page: String, task: String, done: Bool) throws {
        if failTask { throw NWZError.other("离线请求失败") }
        taskChanges.append("\(page):\(task):\(done)")
    }
}
struct WorkspaceServiceTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func settings(_ directory: URL) throws -> SettingsService {
        let paths = AppPaths(dataDirectory: directory)
        return try SettingsService(paths: paths, configuration: ConfigurationStore(path: paths.config))
    }
    @Test func inboxHandlingSnoozingAndNewChanges() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = WorkspaceTestRemote(), host = WorkspaceTestHost(), store = try await Workspace()
        let service = WorkspaceService(store: store, settings: try settings(directory), host: host, remote: remote)
        let now = Workspace.now()
        let items = [InboxItem(id: "due:ABC-1", source: "due", title: "ABC-1", at: now - 1_000), InboxItem(id: "mr:1:2", source: "mr", title: "评审", at: now - 500)]
        await remote.setItems(items)
        #expect(try await service.inbox().items.count == 2)
        try await service.snoozeInbox("mr:1:2", title: "评审", until: now + 60_000)
        #expect(try await service.inbox().snoozed.first?.id == "mr:1:2")
        try await service.handleInbox(.init(id: "due:ABC-1", title: "ABC-1", eventIds: ["event-1"]))
        #expect(await remote.marked == ["event-1"])
        #expect(try await service.inbox().items.isEmpty == true)
        await remote.setItems([.init(id: "due:ABC-1", source: "due", title: "ABC-1", at: now + 86_400_000)])
        #expect(try await service.inbox().items.count == 1)
    }
    @Test func wikiTaskChangesBeforeLocalCompletion() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = WorkspaceTestRemote(), store = try await Workspace()
        let service = WorkspaceService(store: store, settings: try settings(directory), host: WorkspaceTestHost(), remote: remote)
        _ = try await store.syncWikiTodos([.init(pageId: "9", pageTitle: "会议", taskId: "2", text: "整理方案")])
        #expect(try await service.setTodoDone("wiki-9-2", done: true).done)
        #expect(await remote.taskChanges == ["9:2:true"])
        await remote.setFailure()
        await #expect(throws: (any Error).self) { try await service.setTodoDone("wiki-9-2", done: false) }
        #expect(try await store.todo("wiki-9-2")?.done == true)
    }
    @Test func workspaceSettingsAndV2Sync() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = WorkspaceTestHost(), settings = try settings(directory), store = try await Workspace()
        let service = WorkspaceService(store: store, settings: settings, host: host)
        _ = try await store.saveTodo(.init(title: "同步测试"))
        let config = try await service.saveSettings(syncDir: directory.path, jiraTodos: false)
        #expect(config.lastSync?.exported == 1 && !config.jiraTodos)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("NextWorkZone/v2/devices/\(store.deviceID).jsonl").path))
        await #expect(throws: (any Error).self) { try await service.saveSettings(syncDir: directory.appendingPathComponent("missing").path, jiraTodos: true) }
        #expect(settings.configuration.snapshot().workspace.syncDir == directory.path)
        _ = try await service.saveCaptureShortcut("Ctrl+Shift+N")
        await #expect(throws: (any Error).self) { try await service.saveCaptureShortcut("invalid") }
        #expect(settings.configuration.snapshot().workspace.captureShortcut == "Ctrl+Shift+N")
        #expect(try await service.setToolsHidden(["test-tool"]) == ["test-tool"])
        #expect(await service.toolsHidden() == ["test-tool"])
    }
    @Test func worklogIncludesManualCompletionsAndDebugRejectsWrites() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await Workspace(), serviceSettings = try settings(directory)
        let service = WorkspaceService(store: store, settings: serviceSettings, host: WorkspaceTestHost())
        let todo = try await store.saveTodo(.init(title: "本地工作", refSystem: "jira", refKey: "ABC-1"))
        _ = try await service.setTodoDone(todo.id, done: true)
        _ = try await store.syncJiraTodos([.init(key: "ABC-2", summary: "自动完成")])
        _ = try await store.syncJiraTodos([])
        let log = try await service.worklog(Workspace.today())
        #expect(log.events.count == 1 && log.events[0].key == "ABC-1" && log.events[0].system == "todo")
        await #expect(throws: (any Error).self) { try await service.worklog("2026-02-31") }
        await #expect(throws: (any Error).self) { try await service.readOnly("ws_delete_todo", arguments: ["id": .string(todo.id)]) }
        #expect(try await store.todos().count == 2)
    }
}
