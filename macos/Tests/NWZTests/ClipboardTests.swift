import Foundation
import Synchronization
import Testing
import NWZCore
import NWZClipboard
@testable import NWZServices

struct ClipboardTests {
    private func store() throws -> (URL, ClipboardStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (directory, try ClipboardStore(directory: directory))
    }

    private func text(_ value: String, app: (String, String) = ("com.example.editor", "编辑器")) -> Capture {
        Capture(text: value, app: (app.0, app.1))
    }

    private func solid(_ width: Int, _ height: Int, _ pixel: [UInt8]) -> RGBAImage {
        RGBAImage(width: width, height: height, pixels: Data(Array(repeating: pixel, count: width * height).joined()))
    }

    @Test func detectsKinds() {
        let cases: [(String, String)] = [
            ("#fff", ClipKind.color), ("#5B5BD6", ClipKind.color), ("rgb(12, 34, 56)", ClipKind.color), ("hsla(210 40% 50% / 0.5)", ClipKind.color),
            ("https://example.com/a?b=1", ClipKind.link), ("www.example.com", ClipKind.link), ("https://example.com 和别的文字", ClipKind.text),
            (#"{"a": 1, "b": [1, 2]}"#, ClipKind.code), ("SELECT id, name FROM users WHERE id = 1", ClipKind.code),
            ("fn main() {\n    println!(\"hi\");\n}", ClipKind.code), ("const a = 1;\nconst b = 2;", ClipKind.code),
            ("今天完成了登录页面的修改。\n明天继续处理导出问题。", ClipKind.text), ("PROJ-123 修复导出失败", ClipKind.text),
            ("{不是 json}", ClipKind.text), ("hello", ClipKind.text),
        ]
        for (text, kind) in cases { #expect(ClipKind.of(text) == kind, "\(text)") }
    }

    @Test func detectsSecrets() {
        #expect(ClipPrivacy.looksSecret("token = glpat-abcdefghijklmnopqrstu"))
        #expect(ClipPrivacy.looksSecret("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"))
        #expect(ClipPrivacy.looksSecret("ghp_" + String(repeating: "a", count: 36)))
        #expect(ClipPrivacy.looksSecret("AKIAABCDEFGHIJKLMNOP"))
        #expect(ClipPrivacy.looksSecret("Xk9#mP2$vL"))
        #expect(!ClipPrivacy.looksSecret("PROJ-123"))
        #expect(!ClipPrivacy.looksSecret("https://example.com/Path?a=1&B=2"))
        #expect(!ClipPrivacy.looksSecret("hello world"))
        #expect(!ClipPrivacy.looksSecret("user.Name@example.com"))
        #expect(!ClipPrivacy.looksSecret("getUserName()"))
        #expect(!ClipPrivacy.looksSecret("今天的会议纪要"))
    }

    @Test func dedupsAndMovesToFront() async throws {
        let (directory, store) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(try await store.add(text("第一条")))
        #expect(first.isNew)
        _ = try await store.add(text("https://example.com"))
        let again = try #require(try await store.add(text("第一条")))
        #expect(!again.isNew)
        #expect(again.item.id == first.item.id)
        #expect(again.item.copyCount == 2)
        let list = try await store.list(ClipQuery())
        #expect(list.first?.id == first.item.id)
        #expect(list[1].kind == ClipKind.link)
        #expect(try await store.add(Capture(text: "  ")) == nil)
    }

    @Test func searchesAndFilters() async throws {
        let (directory, store) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.add(text("修复导出失败的问题 PROJ-123"))
        _ = try await store.add(text("#ff8800"))
        _ = try await store.add(text("from another app", app: ("com.example.chat", "聊天")))
        func find(_ query: ClipQuery) async throws -> [String] { try await store.list(query).map(\.text) }
        #expect(try await find(ClipQuery(text: "导出失败")) == ["修复导出失败的问题 PROJ-123"])
        // 少于 3 个字符时用 LIKE 搜索
        #expect(try await find(ClipQuery(text: "导出")).count == 1)
        #expect(try await find(ClipQuery(text: "聊天")) == ["from another app"])
        #expect(try await find(ClipQuery(kind: "color")) == ["#ff8800"])
        #expect(try await find(ClipQuery(app: "com.example.chat")).count == 1)
        #expect(try await find(ClipQuery(text: "100%")).isEmpty)
    }

    @Test func pinboardsSurvivePruning() async throws {
        let (directory, store) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try #require(try await store.add(text("a"))).item
        let b = try #require(try await store.add(text("b"))).item
        let c = try #require(try await store.add(text("c"))).item
        let board = try await store.savePinboard(id: nil, name: "常用", color: "#3b82f6")
        try await store.setPinboard([a.id], pinboard: board.id)
        #expect(try await store.pinboards().first?.count == 1)
        // 只保留 1 条未置顶的：b 被清理，c 最新保留，a 已置顶
        #expect(try await store.prune(keepDays: 0, maxItems: 1) == 1)
        let ids = try await store.list(ClipQuery()).map(\.id)
        #expect(ids.contains(a.id) && ids.contains(c.id) && !ids.contains(b.id))
        #expect(try await store.list(ClipQuery(pinboard: board.id)).count == 1)
        try await store.deletePinboard(board.id)
        #expect(try await store.item(a.id)?.pinboard == nil)
        #expect(try await store.clearHistory() == 2)
    }

    @Test func storesImagesAndFiles() async throws {
        let (directory, store) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pixels = solid(600, 300, [255, 0, 0, 255])
        let image = try #require(try await store.add(Capture(image: pixels))).item
        #expect(image.kind == ClipKind.image)
        #expect(image.image?.width == 600)
        #expect(FileManager.default.fileExists(atPath: store.imageURL(image.id).path))
        let thumb = try #require(ClipImages.decode(Data(contentsOf: store.thumbURL(image.id))))
        #expect((thumb.width, thumb.height) == (480, 240))
        // 同样的像素不重复保存
        #expect(try await store.add(Capture(image: pixels))?.isNew == false)

        let files = try #require(try await store.add(Capture(files: ["/tmp/a.txt", "/tmp/b.png"]))).item
        #expect(files.kind == ClipKind.file)
        #expect(files.files.count == 2)
        #expect(try await store.list(ClipQuery(text: "b.png")).count == 1)

        try await store.delete([image.id])
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(image.id).path))
    }

    @Test func editsAndRenames() async throws {
        let (directory, store) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try #require(try await store.add(text("旧内容"))).item
        let b = try #require(try await store.add(text("另一条"))).item
        #expect(try await store.updateText(a.id, text: #"{"a": 1}"#)?.kind == ClipKind.code)
        // 改成与另一条相同的内容时合并
        #expect(try await store.updateText(a.id, text: "另一条")?.id == b.id)
        #expect(try await store.item(a.id) == nil)
        _ = try await store.rename(b.id, title: "签名")
        #expect(try await store.list(ClipQuery(text: "签名")).count == 1)
    }

    @Test func picksIconColor() {
        var pixels = Data()
        for _ in 0..<8 { for x in 0..<8 { pixels.append(contentsOf: x < 6 ? [40, 120, 240, 255] : [255, 255, 255, 255]) } }
        #expect(ClipImages.dominantColor(RGBAImage(width: 8, height: 8, pixels: pixels)) == "#2878f0")
        #expect(ClipImages.dominantColor(solid(8, 8, [128, 128, 128, 255])) == nil)
    }

    @Test func watcherRecordsSkipsSecretsAndOwnWrites() async throws {
        let (directory, store) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(dataDirectory: directory)
        let settings = try SettingsService(paths: paths, configuration: ConfigurationStore(path: paths.config))
        let system = FakeClipboard(), host = WorkspaceTestHost()
        let service = ClipboardService(store: store, system: system, settings: settings, host: host)
        service.start()
        defer { service.stop() }

        system.copy(ClipboardSnapshot(text: "会议纪要"), from: RunningApp(id: "com.example.editor", name: "编辑器"))
        try await waitUntil { try await store.list(ClipQuery()).count == 1 }
        system.copy(ClipboardSnapshot(text: "Xk9#mP2$vL"), from: RunningApp(id: "com.example.editor", name: "编辑器"))
        system.copy(ClipboardSnapshot(text: "主密码"), from: RunningApp(id: "com.1password.1password", name: "1Password"))
        system.copy(ClipboardSnapshot(text: "第二条"), from: RunningApp(id: "com.example.editor", name: "编辑器"))
        try await waitUntil { try await store.list(ClipQuery()).count == 2 }
        #expect(try await store.list(ClipQuery()).map(\.text) == ["第二条", "会议纪要"])

        // 本应用写回剪贴板的内容不再记录为新条目，只移到最前面
        let first = try #require(try await store.list(ClipQuery()).last)
        try await service.copy([first.id], plain: nil, edited: nil)
        #expect(system.written.withLock { $0 } == ["会议纪要"])
        try await Task.sleep(for: .milliseconds(700))
        #expect(try await store.list(ClipQuery()).map(\.text) == ["会议纪要", "第二条"])
        #expect(try await store.list(ClipQuery()).first?.copyCount == 2)
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<50 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("等待超时")
    }
}

/// 内存中的系统剪贴板：每次“复制”增加变化序号，并记下来源应用。
final class FakeClipboard: SystemClipboard {
    private let state = Mutex<(count: Int, snapshot: ClipboardSnapshot, app: RunningApp?)>((0, ClipboardSnapshot(), nil))
    let written = Mutex<[String]>([])

    func copy(_ snapshot: ClipboardSnapshot, from app: RunningApp) {
        state.withLock { $0 = ($0.count + 1, snapshot, app) }
        // 给后台记录一次轮询的时间，避免连续复制被合并成一次变化
        Thread.sleep(forTimeInterval: 0.45)
    }

    func changeCount() -> Int { state.withLock { $0.count } }
    func isConcealed() -> Bool { false }
    func read(withImage: Bool) -> ClipboardSnapshot { state.withLock { $0.snapshot } }
    func write(text: String, html: String?) -> Int {
        written.withLock { $0.append(text) }
        return state.withLock { $0.count += 1; $0.snapshot = ClipboardSnapshot(text: text); return $0.count }
    }
    func write(imagePNG: Data) -> Int { state.withLock { $0.count += 1; return $0.count } }
    func write(files: [String]) -> Int { state.withLock { $0.count += 1; return $0.count } }
    func frontmostApp() -> RunningApp? { state.withLock { $0.app } }
    func iconPNG(path: String, size: Int) -> Data? { nil }
    func canPaste() -> Bool { false }
    func requestPastePermission() {}
    func sendPaste() {}
}
