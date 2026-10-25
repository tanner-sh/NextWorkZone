import Foundation
import NWZCore
import NWZWiki

extension WikiService {
    public static let readOnlyCommands: Set<String> = Set("""
        wiki_cached_spaces wiki_spaces wiki_space_roots wiki_children wiki_page wiki_resolve
        wiki_attachments wiki_recent wiki_versions wiki_diff wiki_version_html wiki_page_version
        wiki_comments wiki_users wiki_search wiki_issue_pages wiki_edit wiki_templates
        wiki_preview_save wiki_index_status wiki_tools_settings ws_wiki_page
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    public func readOnly(_ command: String, arguments a: [String: JSONValue]) async throws -> Data {
        guard Self.readOnlyCommands.contains(command) else { throw NWZError.other("调试通道只允许读取 Wiki 数据") }
        func s(_ key: String) -> String { a[key]?.string ?? "" }
        func n(_ key: String, _ fallback: Int = 0) -> Int { a[key]?.decode(Int.self) ?? fallback }
        func output<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
        switch command {
        case "wiki_cached_spaces": return try await output(cachedSpaces())
        case "wiki_spaces": return try await output(spaces())
        case "wiki_space_roots": return try await output(client().spaceRoots(s("space")))
        case "wiki_children": return try await output(client().children(s("page")))
        case "wiki_page": return try await output(page(s("page")))
        case "wiki_resolve": return try await output(client().resolvePage(s("input")))
        case "wiki_attachments": return try await output(pageAttachments(s("page")))
        case "wiki_recent": return try await output(recent(limit: n("limit", 30)))
        case "wiki_versions": return try await output(client().versions(s("page")))
        case "wiki_diff": return try await output(diff(s("page"), from: n("from"), to: n("to")))
        case "wiki_version_html": return try await output(client().versionHTML(s("page"), version: n("version")))
        case "wiki_page_version": return try await output(client().pageVersion(s("page")))
        case "wiki_comments": return try await output(client().comments(s("page")))
        case "wiki_users": return try await output(client().userNames(a["keys"]?.decode([String].self) ?? []))
        case "wiki_search": return try await output(search(a["query"]?.decode(WikiQuery.self) ?? WikiQuery(), server: a["server"]?.decode(Bool.self) ?? false, start: n("start")))
        case "wiki_issue_pages": return try await output(issuePages(s("key")))
        case "wiki_edit": return try await output(edit(s("page")))
        case "wiki_templates": return try await output(client().templates(space: a["space"]?.string))
        case "wiki_preview_save": return try await output(previewSave(page: a["page"]?.string, xhtml: s("xhtml"), fragments: a["fragments"]?.decode([String].self) ?? []))
        case "wiki_index_status": return try await output(indexStatus())
        case "wiki_tools_settings": return try output(toolsSettings())
        case "ws_wiki_page": return try await output(workspacePage(s("page")))
        default: throw NWZError.other("未知的只读 Wiki 命令")
        }
    }
}
