import Foundation
import NWZCore
import NWZWiki
import NWZWorkspace

public typealias WsWikiPage = WikiPageView
public struct PublishResult: Codable, Hashable, Sendable {
    public var url: String
    public var updated: Bool
    public var doc: Doc?
    public init(url: String, updated: Bool, doc: Doc?) { self.url = url; self.updated = updated; self.doc = doc }
}

extension WikiService {
    public func workspacePage(_ input: String) async throws -> WikiPageView {
        try await client().pageView(pageID(input))
    }
    public func publish(docID: String?, mode: String, parent: String, title: String, storage: String, assets: [String], workspace: Workspace) async throws -> PublishResult {
        let client = try await client(), title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NWZError.other("页面标题不能为空") }
        guard ["create", "update", "overwrite"].contains(mode) else { throw NWZError.other("无法识别的发布方式") }
        var storage = storage, files: [(String, String, Data)] = []
        for id in assets {
            guard let asset = try await workspace.asset(id) else { throw NWZError.other("图片尚未同步或不存在，请稍后重试") }
            let ext = ["image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/svg+xml": "svg"][asset.mime] ?? "png"
            let filename = id + "." + ext
            storage = storage.replacingOccurrences(of: "ws-asset:" + id, with: filename)
            files.append((filename, asset.mime, asset.data))
        }
        let pageID: String, version: Int, updated: Bool
        if mode == "create" {
            let id = try await self.pageID(parent)
            pageID = try await client.createPage(parent: id, title: title, storage: storage)
            version = 1; updated = false
        } else {
            guard let docID, let doc = try await workspace.doc(docID) else { throw NWZError.other("知识库页面不存在") }
            guard let published = doc.publishedUrl, let id = parsePageID(published), let rawVersion = URLComponents(string: published)?.queryItems?.first(where: { $0.name == "pageVersion" })?.value, let oldVersion = Int(rawVersion) else { throw NWZError.other("这篇知识库页面还没有发布过") }
            let base = mode == "overwrite" ? try await client.page(id).version : oldVersion
            version = try await client.savePage(id, title: title, storage: storage, baseVersion: base, minorEdit: false, message: "从 NextWorkZone 知识库更新")
            pageID = id; updated = true
        }
        let existing = updated ? (try? await client.attachments(pageID).map(\.filename)) ?? [] : []
        for (filename, mime, data) in files where !existing.contains(filename) { try await client.attach(pageID, filename: filename, mime: mime, data: data) }
        let url = client.pageURL(pageID), published = url + "&pageVersion=\(version)"
        let doc: Doc?
        if let docID { doc = try await workspace.setPublished(docID, url: published) }
        else { doc = nil }
        requestIndexSync()
        return PublishResult(url: url, updated: updated, doc: doc)
    }
}
