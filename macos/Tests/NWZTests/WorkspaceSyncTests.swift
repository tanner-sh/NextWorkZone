import Foundation
import Testing
@testable import NWZWorkspace

struct WorkspaceSyncTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @Test func syncBetweenTwoDevices() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = directory.appendingPathComponent("shared")
        let a = try await Workspace(), b = try await Workspace()
        let todo = try await a.saveTodo(.init(title: "A 的待办"))
        let note = try await a.saveDoc(.init(title: "会议记录", content: "第一版"))
        let asset = try await a.saveAsset(mime: "image/png", data: Data("PNG".utf8))
        #expect(try await a.sync(at: shared).exported == 3)
        let imported = try await b.sync(at: shared)
        #expect(imported.imported == 2 && imported.devices == 1)
        #expect(try await b.todos().first?.title == todo.title)
        #expect(try await b.asset(asset.id)?.data == Data("PNG".utf8))
        _ = try await b.setTodoDone(todo.id, done: true)
        _ = try await b.sync(at: shared); _ = try await a.sync(at: shared)
        #expect(try await a.todo(todo.id)?.done == true)
        #expect(try await a.sync(at: shared).imported == 0)
        _ = try await a.saveDoc(.init(id: note.id, title: note.title, content: "A 的修改"))
        try await Task.sleep(for: .milliseconds(5))
        _ = try await b.saveDoc(.init(id: note.id, title: note.title, content: "B 的修改"))
        _ = try await b.sync(at: shared)
        #expect(try await a.sync(at: shared).conflicts == 1)
        #expect(try await a.doc(note.id)?.content == "B 的修改")
        #expect(try await a.docs(kind: "note").contains { $0.title == "会议记录（冲突副本）" && $0.excerpt == "A 的修改" })
        _ = try await a.sync(at: shared); _ = try await b.sync(at: shared)
        #expect(try await b.docs(kind: "note").count == 2)
        _ = try await a.sync(at: shared)
        _ = try await a.saveDoc(.init(id: note.id, title: note.title, content: "A 的第二次修改"))
        _ = try await a.sync(at: shared)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await b.saveDoc(.init(id: note.id, title: note.title, content: "B 的第二次修改"))
        _ = try await b.sync(at: shared)
        #expect(try await a.sync(at: shared).conflicts == 1)
        #expect(try await a.docs(kind: "note").contains { $0.excerpt == "A 的第二次修改" })
        _ = try await b.sync(at: shared)
        _ = try await b.saveDoc(.init(id: note.id, title: note.title, content: "B 接着改"))
        _ = try await b.sync(at: shared)
        #expect(try await a.sync(at: shared).conflicts == 0)
        #expect(try await a.doc(note.id)?.content == "B 接着改")
        try await a.deleteTodo(todo.id)
        _ = try await a.sync(at: shared); _ = try await b.sync(at: shared)
        #expect(try await b.todos().isEmpty == true)
    }
    @Test func incompleteLinesWaitForNextSync() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await Workspace(), b = try await Workspace()
        _ = try await a.saveTodo(.init(title: "完整的"))
        _ = try await a.sync(at: directory)
        let log = directory.appendingPathComponent("devices/\(a.deviceID).jsonl")
        var data = try Data(contentsOf: log)
        data.append(Data("{\"type\":\"todo\",\"row\":{\"id\":\"x".utf8))
        try data.write(to: log)
        #expect(try await b.sync(at: directory).imported == 1)
        #expect(try await b.todos().count == 1)
        #expect(try await b.sync(at: directory).imported == 0)
    }
    @Test func compactionKeepsLatestVersions() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await Workspace(), b = try await Workspace()
        let text = String(repeating: "长", count: 1024 * 1024)
        let doc = try await a.saveDoc(.init(title: "大文档", content: text))
        _ = try await a.sync(at: directory); _ = try await b.sync(at: directory)
        for index in 0..<4 {
            _ = try await a.saveDoc(.init(id: doc.id, title: doc.title, content: text + String(index)))
            _ = try await a.sync(at: directory)
        }
        let log = directory.appendingPathComponent("devices/\(a.deviceID).jsonl")
        #expect(try Data(contentsOf: log).count < 8 * 1024 * 1024)
        _ = try await b.sync(at: directory)
        #expect(try await b.doc(doc.id)?.content.hasSuffix("3") == true)
    }
    @Test func inboxStateAndSync() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await Workspace(), b = try await Workspace()
        let capture = try await a.capture(title: "看一下这个链接", body: "https://example.com/x", url: "https://example.com/x")
        _ = try await a.setInboxState("mr:1:2", title: "评审 !2", handledAt: 100, snoozeUntil: nil)
        _ = try await a.sync(at: directory); _ = try await b.sync(at: directory)
        let entries = try await b.inbox()
        #expect(entries.count == 2 && entries.contains { $0.id == "mr:1:2" && $0.kind == "state" && $0.handledAt == 100 })
        try await b.deleteInbox(capture.id)
        _ = try await b.sync(at: directory); _ = try await a.sync(at: directory)
        #expect(try await a.inbox().count == 1)
    }
    @Test func assetsCanArriveAfterTheirRecords() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await Workspace(), b = try await Workspace()
        let content = Data([0, 1, 2, 255])
        let asset = try await a.saveAsset(mime: "image/png", data: content)
        _ = try await a.sync(at: directory)
        let path = directory.appendingPathComponent("assets/\(asset.id)")
        try FileManager.default.removeItem(at: path)
        _ = try await b.sync(at: directory)
        #expect(try await b.asset(asset.id) == nil)
        try content.write(to: path)
        _ = try await b.sync(at: directory)
        #expect(try await b.asset(asset.id)?.data == content)
    }
    @Test func switchingFoldersExportsExistingRecords() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await Workspace(), b = try await Workspace()
        _ = try await a.saveTodo(.init(title: "换目录仍保留"))
        _ = try await a.sync(at: directory.appendingPathComponent("first"))
        #expect(try await a.sync(at: directory.appendingPathComponent("second")).exported == 1)
        _ = try await b.sync(at: directory.appendingPathComponent("second"))
        #expect(try await b.todos().first?.title == "换目录仍保留")
    }
    @Test func rejectsAssetPathsOutsideSyncDirectory() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ws = try await Workspace()
        let devices = directory.appendingPathComponent("devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        let text = "{\"type\":\"asset\",\"row\":{\"id\":\"../../private\",\"mime\":\"image/png\",\"createdAt\":1}}\n"
        try Data(text.utf8).write(to: devices.appendingPathComponent("other.jsonl"))
        _ = try await ws.sync(at: directory)
        #expect(try await ws.asset("../../private") == nil)
    }
}
