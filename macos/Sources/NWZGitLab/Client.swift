import Foundation
import NWZCore

public struct GitLabClient: Sendable {
    public let rest: RESTClient
    public var baseURL: String { rest.baseURL }
    public init(rest: RESTClient) { self.rest = rest }
    static func path(_ segments: [String]) -> String { "/api/v4/" + segments.map(RESTClient.component).joined(separator: "/") }
    func get(_ segments: [String], query: [(String, String)] = []) async throws -> JSONDocument { try await rest.json("GET", Self.path(segments), query: query) }
    func all(_ segments: [String], query: [(String, String)] = [], limit: Int) async throws -> [JSONDocument] {
        guard limit > 0 else { return [] }
        var items: [JSONDocument] = [], page = "1", seen: Set<String> = []
        while seen.insert(page).inserted {
            try Task.checkCancellation()
            let response = try await rest.response("GET", Self.path(segments), query: query + [("per_page", String(min(100, limit))), ("page", page)])
            items += try JSONDocument(data: response.data).list
            guard items.count < limit, let next = response.header("x-next-page"), !next.isEmpty else { break }
            // 页码只用作查询参数；异常分页不能造成无限循环。
            page = next
        }
        return Array(items.prefix(limit))
    }
    public func currentUser() async throws -> GlUser { try await GlUser(raw: get(["user"])) }
    public func projects(search: String? = nil, limit: Int = 300) async throws -> [Project] {
        var query = [("membership", "true"), ("simple", "true"), ("order_by", "last_activity_at")]
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { query.append(("search", search)) }
        return try await all(["projects"], query: query, limit: limit).map(Project.init(raw:))
    }
    public func project(_ id: Int) async throws -> Project { try await project(path: String(id)) }
    public func project(path: String) async throws -> Project { try await Project(raw: get(["projects", path])) }
    public func branch(_ project: Int, name: String) async throws -> Branch? {
        do { return try await Branch(raw: get(["projects", String(project), "repository", "branches", name])) }
        catch NWZError.http(404, _) { return nil }
    }
    public func branches(_ project: Int, search: String? = nil) async throws -> [Branch] {
        let query = search.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : [("search", $0)] } ?? []
        return try await all(["projects", String(project), "repository", "branches"], query: query, limit: 500).map(Branch.init(raw:)).sorted { a, b in a.default == b.default ? a.commit.authoredDate > b.commit.authoredDate : a.default }
    }
    public func tree(_ project: Int, ref: String, path: String) async throws -> [TreeEntry] {
        var query = [("ref", ref)]; if !path.isEmpty { query.append(("path", path)) }
        return try await all(["projects", String(project), "repository", "tree"], query: query, limit: 2000).map(TreeEntry.init(raw:)).sorted { a, b in (a.kind == "tree") == (b.kind == "tree") ? a.name.lowercased() < b.name.lowercased() : a.kind == "tree" }
    }
    public func file(_ project: Int, ref: String, path: String) async throws -> FileContent {
        let api = Self.path(["projects", String(project), "repository", "files", path]), query = [("ref", ref)], maxSize = 2 * 1024 * 1024
        let head = try await rest.response("HEAD", api, query: query)
        var file = FileContent(path: path, size: Int(head.header("x-gitlab-size") ?? "") ?? 0)
        if file.size > maxSize { file.tooLarge = true; return file }
        let raw = try await rest.json("GET", api, query: query); file.size = raw["size"].int
        if file.size > maxSize { file.tooLarge = true; return file }
        guard let data = Data(base64Encoded: raw["content"].text.replacingOccurrences(of: "\n", with: "")) else { throw NWZError.other("文件内容解码失败") }
        if data.count > maxSize { file.size = max(file.size, data.count); file.tooLarge = true; return file }
        if let mime = Self.imageMIME(path) { file.imageDataUrl = "data:\(mime);base64," + data.base64EncodedString() }
        else if let (text, encoding) = Self.decodeText(data) { file.text = text; file.encoding = encoding }
        else { file.binary = true }
        return file
    }
    /// 文件原始内容（二进制文件在应用内预览时用）。
    public func rawFile(_ project: Int, ref: String, path: String) async throws -> Data {
        try await rest.response("GET", Self.path(["projects", String(project), "repository", "files", path, "raw"]), query: [("ref", ref)]).data
    }
    /// 识别文本文件的编码：UTF-8（可带 BOM）、UTF-16（带 BOM）、GB18030；含 NUL 等控制字符的视为二进制。
    static func decodeText(_ data: Data) -> (String, String)? {
        let bytes = Array(data)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { return String(bytes: bytes.dropFirst(3), encoding: .utf8).map { ($0, "UTF-8") } }
        if bytes.starts(with: [0xff, 0xfe]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian).map { ($0, "UTF-16LE") } }
        if bytes.starts(with: [0xfe, 0xff]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian).map { ($0, "UTF-16BE") } }
        let control = bytes.prefix(8192).filter { $0 < 9 || ($0 > 13 && $0 < 32) }.count
        if bytes.prefix(8192).contains(0) || control * 100 > min(bytes.count, 8192) { return nil }
        if let text = String(bytes: bytes, encoding: .utf8) { return (text, "UTF-8") }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(bytes: bytes, encoding: gb).map { ($0, "GB18030") }
    }
    static func imageMIME(_ path: String) -> String? {
        ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp", "svg":"image/svg+xml", "ico":"image/x-icon", "bmp":"image/bmp"][path.split(separator: ".").last.map { $0.lowercased() } ?? ""]
    }
    public func commits(_ project: Int, ref: String, path: String? = nil, page: Int = 1) async throws -> [Commit] {
        var query = [("ref_name", ref), ("per_page", "50"), ("page", String(page))]
        if let path, !path.isEmpty { query.append(("path", path)) }
        return try await get(["projects", String(project), "repository", "commits"], query: query).list.map(Commit.init(raw:))
    }
    public func commitsBetween(_ project: Int, ref: String, since: String, until: String, limit: Int) async throws -> [Commit] {
        try await all(["projects", String(project), "repository", "commits"], query: [("ref_name", ref), ("since", since), ("until", until)], limit: limit).map(Commit.init(raw:))
    }
    public func commitInfo(_ project: Int, sha: String) async throws -> Commit { try await Commit(raw: get(["projects", String(project), "repository", "commits", sha])) }
    public func searchCommits(_ project: Int, text: String, limit: Int) async throws -> [Commit] { try await all(["projects", String(project), "search"], query: [("scope", "commits"), ("search", text)], limit: limit).map(Commit.init(raw:)) }
    public func commit(_ project: Int, sha: String) async throws -> CommitDetail {
        let commit = try await commitInfo(project, sha: sha)
        let diffs = try await all(["projects", String(project), "repository", "commits", sha, "diff"], limit: 500).map(FileDiff.init(raw:))
        return CommitDetail(commit: commit, diffs: diffs)
    }
    public func compare(_ project: Int, from: String, to: String) async throws -> Comparison {
        let raw = try await get(["projects", String(project), "repository", "compare"], query: [("from", from), ("to", to)])
        return Comparison(commits: raw["commits"].list.reversed().map(Commit.init(raw:)), diffs: raw["diffs"].list.map(FileDiff.init(raw:)))
    }
    public func myEvents(after: String, before: String) async throws -> [GitLabEvent] {
        try await all(["events"], query: [("after", after), ("before", before)], limit: 500).compactMap(GitLabEvent.init(raw:)).sorted { $0.at < $1.at }
    }
}
