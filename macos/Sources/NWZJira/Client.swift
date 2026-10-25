import Foundation
import NWZCore

public struct JiraClient: Sendable {
    public let rest: RESTClient
    public var baseURL: String { rest.baseURL }
    public init(baseURL: String, token: String, http: HTTPClient) { rest = RESTClient(baseURL: baseURL, token: token, http: http) }
    public init(rest: RESTClient) { self.rest = rest }
    static let listFields = ["summary", "status", "issuetype", "priority", "project", "updated", "created", "duedate", "assignee", "reporter", "resolution", "lastViewed"]
    static func issuePath(_ key: String) -> String { "/rest/api/2/issue/" + RESTClient.component(key) }
    public func get(_ path: String, query: [(String, String)] = []) async throws -> JSONDocument { try await rest.json("GET", path, query: query) }
    public func myUsername() async throws -> String { try await get("/rest/api/2/myself")["name"].text }
    public func search(_ jql: String, startAt: Int = 0, maxResults: Int = 100, fields: [String] = []) async throws -> SearchResult {
        let raw = try await get("/rest/api/2/search", query: [("jql", jql), ("startAt", String(startAt)), ("maxResults", String(maxResults)), ("fields", (Self.listFields + fields).joined(separator: ","))])
        return SearchResult(total: raw["total"].int, issues: raw["issues"].list.map { IssueSummary(raw: $0, extra: fields) })
    }
    public func listFields() async throws -> [FieldInfo] {
        try await get("/rest/api/2/field").list.filter { $0["navigable"].bool == true }.map { FieldInfo(id: JiraFields.text($0["id"]), name: JiraFields.text($0["name"]), custom: $0["custom"].bool ?? false, kind: $0["schema"]["type"].text) }.sorted { $0.name < $1.name }
    }
    public func issue(_ key: String) async throws -> IssueDetail { try await IssueDetail(raw: get(Self.issuePath(key), query: [("expand", "renderedFields,names,schema,editmeta")])) }
    public func transitions(_ key: String) async throws -> [Transition] { try await JiraFields.transitions(get(Self.issuePath(key) + "/transitions", query: [("expand", "transitions.fields")])) }
    public func transition(_ key: String, transitionID: String, fields: [String: JSONValue]) async throws {
        var body: [String: JSONValue] = ["transition": ["id": .string(transitionID)]]
        if !fields.isEmpty { body["fields"] = .object(fields) }
        _ = try await rest.response("POST", Self.issuePath(key) + "/transitions", body: .object(body))
    }
    public func saveComment(_ key: String, id: String? = nil, body: String, visibility: CommentVisibility?) async throws -> Comment {
        var payload: [String: JSONValue] = ["body": .string(body)]
        if let visibility { payload["visibility"] = .from(visibility) }
        let raw = try await rest.json(id == nil ? "POST" : "PUT", Self.issuePath(key) + "/comment" + (id.map { "/" + RESTClient.component($0) } ?? ""), query: [("expand", "renderedBody")], body: .object(payload))
        return Comment(raw: raw)
    }
    public func deleteComment(_ key: String, id: String) async throws { _ = try await rest.response("DELETE", Self.issuePath(key) + "/comment/" + RESTClient.component(id)) }
    public func uploadAttachment(_ key: String, file: URL) async throws -> [Attachment] {
        var multipart = MultipartBody()
        try multipart.append(name: "file", filename: file.lastPathComponent, data: Data(contentsOf: file))
        var request = try rest.request("POST", Self.issuePath(key) + "/attachments")
        request.httpBody = multipart.data; request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type"); request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        return try JSONDocument(data: await rest.http.send(request).data).list.map(Attachment.init(raw:))
    }
    public func editFields(_ key: String) async throws -> [FieldMeta] {
        let raw = try await get(Self.issuePath(key), query: [("expand", "editmeta")])
        return JiraFields.parse(raw["editmeta"]["fields"]).map { field in var field = field; field.value = JiraFields.formValue(field.kind, raw["fields"][field.key]); return field }
    }
    public func updateIssue(_ key: String, fields: [String: JSONValue]) async throws { _ = try await rest.response("PUT", Self.issuePath(key), body: ["fields": .object(fields)]) }
    public func createProjects() async throws -> [CreateProject] {
        try await get("/rest/api/2/issue/createmeta")["projects"].list.map { project in
            CreateProject(id: JiraFields.text(project["id"]), key: project["key"].text, name: project["name"].text.trimmingCharacters(in: .whitespacesAndNewlines), issueTypes: project["issuetypes"].list.map { CreateIssueType(id: JiraFields.text($0["id"]), name: $0["name"].text, iconUrl: $0["iconUrl"].string, subtask: $0["subtask"].bool ?? false) })
        }
    }
    public func createFields(projectKey: String, issueTypeID: String) async throws -> [FieldMeta] {
        let raw = try await get("/rest/api/2/issue/createmeta", query: [("projectKeys", projectKey), ("issuetypeIds", issueTypeID), ("expand", "projects.issuetypes.fields")])["projects"][0]["issuetypes"][0]["fields"]
        guard raw.isObject else { throw NWZError.other("没有在该项目中创建此类问题的权限") }
        return JiraFields.parse(raw)
    }
    public func createIssue(fields: [String: JSONValue]) async throws -> String { try await rest.json("POST", "/rest/api/2/issue", body: ["fields": .object(fields)])["key"].text }
    public func renderWiki(_ markup: String, issueKey: String?) async throws -> String {
        var body: [String: JSONValue] = ["rendererType":"atlassian-wiki-renderer", "unrenderedMarkup": .string(markup)]
        if let issueKey { body["issueKey"] = .string(issueKey) }
        return String(decoding: try await rest.response("POST", "/rest/api/1.0/render", body: .object(body)).data, as: UTF8.self)
    }
    public func findUsers(_ query: String, field: String, issueKey: String?, projectKey: String?) async throws -> [UserRef] {
        let raw: JSONDocument
        if field == "assignee", let scope = issueKey ?? projectKey { raw = try await get("/rest/api/2/user/assignable/search", query: [(issueKey != nil ? "issueKey" : "project", scope), ("username", query), ("maxResults", "20")]) }
        else { raw = try await get("/rest/api/2/user/picker", query: [("query", query), ("maxResults", "20")])["users"] }
        return raw.list.map { UserRef(name: $0["name"].text, displayName: JiraFields.text($0)) }
    }
    public func suggestLabels(_ query: String) async throws -> [String] { try await get("/rest/api/1.0/labels/suggest", query: [("query", query)])["suggestions"].list.map { $0["label"].text } }
    public func searchEpics(_ query: String, projectKey: String) async throws -> [IssueRef] {
        let raw = try await get("/rest/greenhopper/1.0/epics", query: [("searchQuery", query), ("projectKey", projectKey), ("maxResults", "20")])
        var result: [IssueRef] = []
        for epic in raw["epicLists"].list.flatMap({ $0["epicNames"].list }) where !result.contains(where: { $0.key == epic["key"].text }) { result.append(IssueRef(key: epic["key"].text, summary: epic["name"].text)) }
        return result
    }
    public func pickIssues(_ query: String, projectKey: String?, standardOnly: Bool) async throws -> [IssueSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines); var clauses: [String] = []
        if JiraQueries.looksLikeKey(query) { clauses.append("key = \"\(query.uppercased())\"") }
        else if !query.isEmpty { clauses.append("summary ~ \"\(JiraQueries.escape(query))\"") }
        if let projectKey { clauses.append("project = \"\(JiraQueries.escape(projectKey))\"") }
        if standardOnly { clauses.append("issuetype in standardIssueTypes()") }
        do { return try await search(clauses.joined(separator: " AND ") + " ORDER BY updated DESC", maxResults: 15).issues }
        catch NWZError.http(400, _) { return [] }
    }
    public func assign(_ key: String, username: String?) async throws { _ = try await rest.response("PUT", Self.issuePath(key) + "/assignee", body: ["name": username.map(JSONValue.string) ?? .null]) }
    public func watchers(_ key: String) async throws -> Watchers {
        let raw = try await get(Self.issuePath(key) + "/watchers")
        return Watchers(watching: raw["isWatching"].bool ?? false, count: raw["watchCount"].int)
    }
    public func setWatching(_ key: String, me: String, watching: Bool) async throws {
        _ = try await rest.response(watching ? "POST" : "DELETE", Self.issuePath(key) + "/watchers", query: watching ? [] : [("username", me)], body: watching ? .string(me) : nil)
    }
    public func priorities() async throws -> [Priority] { try await get("/rest/api/2/priority").list.map { Priority(id: JiraFields.text($0["id"]), name: $0["name"].text, iconUrl: $0["iconUrl"].string) } }
    public func favouriteFilters() async throws -> [JiraFilter] { try await get("/rest/api/2/filter/favourite").list.map { JiraFilter(id: JiraFields.text($0["id"]), name: $0["name"].text, jql: $0["jql"].text) } }
    public func wikiPageLinks(_ key: String) async throws -> [String] {
        let links = try await get(Self.issuePath(key) + "/remotelink").list
        var ids: [String] = []
        for link in links where link["application"]["type"].text == "com.atlassian.confluence" {
            let global = link["globalId"].text.split(separator: "&").first { $0.hasPrefix("pageId=") }.map { String($0.dropFirst(7)) }
            let fromURL = URLComponents(string: link["object"]["url"].text)?.queryItems?.first { $0.name == "pageId" }?.value
            if let id = global ?? fromURL, !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }), !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
    public func linkTypes() async throws -> [LinkType] { try await get("/rest/api/2/issueLinkType")["issueLinkTypes"].list.map { LinkType(id: JiraFields.text($0["id"]), name: $0["name"].text, inward: $0["inward"].text, outward: $0["outward"].text) } }
    public func addLink(_ key: String, typeID: String, other: String, outward: Bool) async throws {
        _ = try await rest.response("POST", "/rest/api/2/issueLink", body: ["type":["id":.string(typeID)], "inwardIssue":["key":.string(outward ? key : other)], "outwardIssue":["key":.string(outward ? other : key)]])
    }
    public func deleteLink(_ id: String) async throws { _ = try await rest.response("DELETE", "/rest/api/2/issueLink/" + RESTClient.component(id)) }
    public func worklogs(_ key: String) async throws -> [Worklog] {
        async let raw = get(Self.issuePath(key) + "/worklog")
        async let me = myUsername()
        let values = try await (raw, me)
        return values.0["worklogs"].list.map { Worklog(raw: $0, me: values.1) }
    }
    public func saveWorklog(_ key: String, id: String?, input: WorklogInput) async throws {
        _ = try await rest.response(id == nil ? "POST" : "PUT", Self.issuePath(key) + "/worklog" + (id.map { "/" + RESTClient.component($0) } ?? ""), body: .from(input))
    }
    public func deleteWorklog(_ key: String, id: String) async throws { _ = try await rest.response("DELETE", Self.issuePath(key) + "/worklog/" + RESTClient.component(id)) }
    public func history(_ key: String) async throws -> [HistoryEntry] {
        let raw = try await get(Self.issuePath(key), query: [("fields", "*all"), ("expand", "changelog,names")])
        return raw["changelog"]["histories"].list.map { HistoryEntry(raw: $0, names: raw["names"]) }
    }
}
