import Foundation
import NWZCore
import NWZJira

extension JiraService {
    public static let readOnlyCommands: Set<String> = Set(ReadOnlyCommands.names.filter { $0.hasPrefix("jira_") || $0 == "local_image_preview" })
    public func readOnly(_ command: String, arguments args: [String: JSONValue]) async throws -> Data {
        func text(_ key: String) -> String { args[key]?.string ?? "" }
        func number(_ key: String, _ fallback: Int = 0) -> Int { args[key]?.number.flatMap(Int.init(exactly:)) ?? fallback }
        func flag(_ key: String) -> Bool { args[key]?.bool ?? false }
        func strings(_ key: String) -> [String] { args[key]?.decode([String].self) ?? [] }
        func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
        guard Self.readOnlyCommands.contains(command) else { throw NWZError.other("调试接口仅允许只读命令") }
        switch command {
        case "jira_cached_search": return try await encode(cachedSearch(text("jql"), fields: strings("fields")))
        case "jira_search": return try await encode(search(text("jql"), startAt: number("startAt"), maxResults: number("maxResults", 100), fields: strings("fields")))
        case "jira_fields": return try await encode(fields(refresh: flag("refresh")))
        case "jira_my_worklogs": return try await encode(myWorklogs(from: text("from"), to: text("to")))
        case "jira_issue": return try await encode(issue(text("key")))
        case "jira_transitions": return try await encode(client().transitions(text("key")))
        case "jira_comment_levels": return try await encode(commentLevels(text("key")))
        case "jira_me": return try await encode(me())
        case "jira_watchers": return try await encode(client().watchers(text("key")))
        case "jira_priorities": return try await encode(priorities())
        case "jira_favourite_filters": return try await encode(client().favouriteFilters())
        case "jira_similar_issues": return try await encode(similarIssues(key: text("key"), summary: text("summary"), resolvedOnly: flag("resolvedOnly")))
        case "jira_index_status": return try await encode(indexStatus())
        case "jira_index_search":
            let query = args["query"]?.decode(IndexQuery.self) ?? IndexQuery(text: "", project: "", state: "all", mine: false)
            return try await encode(searchIndex(query))
        case "jira_viewed": return try await encode(index.viewed(strings("keys")))
        case "jira_tools_settings": return try encode(toolsSettings())
        case "jira_reminders": return try await encode(reminders())
        case "jira_activity": return try await encode(activity())
        case "jira_preview_attachment": return try await encode(attachments.preview(service: Service(rawValue: text("service")) ?? .jira, url: text("url"), filename: text("filename"), mime: text("mime")))
        case "jira_edit_fields": return try await encode(client().editFields(text("key")))
        case "jira_cached_create_projects": return try await encode(cachedCreateProjects())
        case "jira_create_projects": return try await encode(createProjects())
        case "jira_create_fields": return try await encode(client().createFields(projectKey: text("projectKey"), issueTypeID: text("issueTypeId")))
        case "jira_find_users": return try await encode(client().findUsers(text("query"), field: text("field"), issueKey: args["issueKey"]?.string, projectKey: args["projectKey"]?.string))
        case "jira_suggested_assignees": return try await encode(suggestedAssignees(text("key")))
        case "jira_suggest_labels": return try await encode(client().suggestLabels(text("query")))
        case "jira_search_epics": return try await encode(client().searchEpics(text("query"), projectKey: text("projectKey")))
        case "jira_pick_issues": return try await encode(client().pickIssues(text("query"), projectKey: args["projectKey"]?.string, standardOnly: flag("standardOnly")))
        case "jira_link_types": return try await encode(client().linkTypes())
        case "jira_worklogs": return try await encode(client().worklogs(text("key")))
        case "jira_history": return try await encode(client().history(text("key")))
        case "local_image_preview": return try encode(AttachmentService.localImagePreview(text("path")))
        default: throw NWZError.other("未知的 Jira 只读命令")
        }
    }
}
