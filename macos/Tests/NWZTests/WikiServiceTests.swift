import Foundation
import Testing
import NWZCore
import NWZRich
import NWZWiki
import NWZWorkspace
@testable import NWZServices

private struct WikiTestWeb: WebResourceSource {
    func fetch(service: Service, url: String) async throws -> (Data, String?) { (Data(), nil) }
}

@Suite struct WikiServiceTests {
    func settings(_ dir: URL, _ transport: OfflineTransport) throws -> SettingsService {
        let paths = AppPaths(dataDirectory: dir); try paths.createDirectories()
        let config = try ConfigurationStore(path: paths.config)
        try config.update { $0.confluence.baseUrl = "https://wiki.example.com"; $0.wikiTools.indexEnabled = false }
        try paths.credentialsStore.save([Secret.token.key(for: .confluence): "test-token"])
        return try SettingsService(paths: paths, configuration: config, client: HTTPClient(transport: transport))
    }
    @Test func editingPreservesStorageAndRejectsWriteDebugCommands() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = #"{"id":"1","title":"页面","space":{"key":"S"},"version":{"number":2},"body":{"storage":{"value":"<p>文字&nbsp; <strong>粗</strong></p>"}}}"#
        let t = OfflineTransport([.response(200, page), .response(200, page)])
        let wiki = try WikiService(settings: settings(dir, t), host: WorkspaceTestHost(), web: WikiTestWeb())
        let edit = try await wiki.edit("1"), load = RichEdit.load(edit.html)
        let preview = try await wiki.previewSave(page: "1", xhtml: RichEdit.xhtml(segments: load.segments, baseline: load.doc, edited: load.doc), fragments: edit.fragments)
        #expect(!preview.changed && preview.diff.isEmpty)
        #expect(preview.storage == "<p>文字&nbsp; <strong>粗</strong></p>")
        await #expect(throws: NWZError.self) { try await wiki.readOnly("wiki_save", arguments: [:]) }
        #expect(await t.requests.count == 2)
    }
    @Test func spacesCacheIsScopedToAccountAndHost() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = OfflineTransport([.response(200, #"{"results":[{"key":"S","name":"空间"}]}"#)]), settings = try settings(dir, t)
        let wiki = try WikiService(settings: settings, host: WorkspaceTestHost(), web: WikiTestWeb())
        #expect(try await wiki.cachedSpaces() == nil)
        #expect(try await wiki.spaces().count == 1)
        #expect(try await wiki.cachedSpaces()?.first?.key == "S")
        try await settings.updateConfiguration { $0.confluence.baseUrl = "https://other.example.com" }
        #expect(try await wiki.cachedSpaces() == nil)
    }
    @Test func taskWriteUpdatesCorrespondingTodo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = OfflineTransport([.response(200, "{}")]), store = try await Workspace()
        _ = try await store.syncWikiTodos([NWZWorkspace.AssignedWikiTask(pageId: "1", pageTitle: "页面", taskId: "2", text: "任务")])
        let wiki = try WikiService(settings: settings(dir, t), host: WorkspaceTestHost(), web: WikiTestWeb())
        await wiki.bindWorkspace(store)
        try await wiki.setTask("1", task: "2", done: true)
        #expect(try await store.todo("wiki-1-2")?.done == true)
        #expect(await t.requests.map(\.httpMethod) == ["POST"])
    }
    @Test func publishUploadsLocalAssetsAndRemembersVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = OfflineTransport([.response(200, #"{"id":"1","title":"父页面","space":{"key":"S"},"version":{"number":1}}"#), .response(201, #"{"id":"2"}"#), .response(200, "{}")])
        let store = try await Workspace(), wiki = try WikiService(settings: settings(dir, t), host: WorkspaceTestHost(), web: WikiTestWeb())
        let doc = try await store.saveDoc(DocInput(title: "笔记", content: "内容"))
        let asset = try await store.saveAsset(mime: "image/png", data: Data([1, 2, 3]))
        let result = try await wiki.publish(docID: doc.id, mode: "create", parent: "1", title: "标题", storage: "<p><ac:image><ri:attachment ri:filename=\"ws-asset:\(asset.id)\" /></ac:image></p>", assets: [asset.id], workspace: store)
        #expect(result.url == "https://wiki.example.com/pages/viewpage.action?pageId=2" && !result.updated)
        #expect(result.doc?.publishedUrl?.hasSuffix("pageVersion=1") == true)
        let requests = await t.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "POST"])
        let body = try JSONDocument(data: #require(requests[1].httpBody))
        #expect(body["body"]["storage"]["value"].text.contains(asset.id + ".png"))
        #expect(!body["body"]["storage"]["value"].text.contains("ws-asset:"))
        await wiki.stop()
    }
    @Test func missingAssetFailsBeforeCreatingPage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = OfflineTransport([]), wiki = try WikiService(settings: settings(dir, t), host: WorkspaceTestHost(), web: WikiTestWeb()), store = try await Workspace()
        await #expect(throws: NWZError.self) { try await wiki.publish(docID: nil, mode: "create", parent: "1", title: "标题", storage: "<p />", assets: ["missing"], workspace: store) }
        #expect(await t.requests.isEmpty)
    }
}
