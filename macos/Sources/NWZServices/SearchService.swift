import Foundation
import NWZClipboard
import NWZCore
import NWZGitLab
import NWZJira
import NWZWiki
import NWZWorkspace

public struct SearchOptions: Codable, Hashable, Sendable {
    /// `local` / `remote`；为空时两步都做。
    public var phase: String?
    /// 每类结果的条数。
    public var limit: Int?
    public init(phase: String? = nil, limit: Int? = nil) { self.phase = phase; self.limit = limit }
}

public struct SearchResults: Codable, Hashable, Sendable {
    public var issues: [IssueHit] = []
    /// 问题来自 `local`（本机问题库）还是 `jira`（服务器搜索）；没有搜索时为空。
    public var issuesSource: String?
    public var projects: [Project] = []
    public var mergeRequests: [MergeRequest] = []
    public var pages: [WikiHit] = []
    /// 本地的待办、笔记、知识库
    public var workspace: [SearchHit] = []
    public var clips: [ClipItem] = []
    /// 某个系统搜索失败时的提示（未配置的系统直接跳过）。
    public var errors: [String] = []
    public init() {}
}

/// 统一搜索（⌘K）：分两步，界面先取本机结果（快），再取服务器结果。
///
/// 本机问题库、Wiki 库可用时由本机这一步负责，否则由服务器这一步负责；
/// 问题键在本机问题库中找不到时，仍向服务器查这个键。
public struct SearchService: Sendable {
    static let defaultLimit = 8
    static let maxLimit = 100

    let settings: SettingsService
    let workspace: Workspace
    let jira: JiraService
    let wiki: WikiService
    let gitlab: GitLabService
    let clipboard: ClipboardStore

    public init(settings: SettingsService, workspace: Workspace, jira: JiraService, wiki: WikiService, gitlab: GitLabService, clipboard: ClipboardStore) {
        self.settings = settings; self.workspace = workspace; self.jira = jira; self.wiki = wiki; self.gitlab = gitlab; self.clipboard = clipboard
    }

    public func search(_ query: String, options: SearchOptions?) async -> SearchResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results = SearchResults()
        guard !query.isEmpty else { return results }
        let limit = min(max(options?.limit ?? Self.defaultLimit, 1), Self.maxLimit)
        let local = options?.phase != "remote", remote = options?.phase != "local"
        async let jiraReady = jiraIndexReady()
        async let wikiReady = wikiIndexReady()
        let jiraLocal = await jiraReady, wikiLocal = await wikiReady

        if local {
            // 四个库互不相关，同时查，用时取决于最慢的一个
            async let workspaceHits = try? await workspace.search(query, limit: limit)
            async let issueHits: [IssueHit]? = jiraLocal ? try? await jira.searchIndex(IndexQuery(text: query, project: "", state: "all", mine: false, limit: limit)) : nil
            async let pageHits: [WikiHit]? = wikiLocal ? try? await localPages(query, limit: limit) : nil
            async let clipHits = try? await clipboard.list(ClipQuery(text: query, limit: limit))
            results.workspace = await workspaceHits ?? []
            if let hits = await issueHits { results.issues = hits; results.issuesSource = "local" }
            results.pages = await pageHits ?? []
            results.clips = await clipHits ?? []
        }

        if remote {
            let keyMissing = Self.isIssueKey(query) ? await keyNotIndexed(query) : false
            async let issues: Result<[IssueHit], Error>? = !jiraLocal || keyMissing ? remoteIssues(query, limit: limit) : nil
            async let pages: Result<[WikiHit], Error>? = wikiLocal ? nil : remotePages(query, limit: limit)
            async let projects: Result<[Project], Error>? = gitlabCall { try await $0.projects(search: query, limit: limit) }
            async let mergeRequests: Result<[MergeRequest], Error>? = gitlabCall { try await $0.searchMergeRequests(query, limit: limit) }
            switch await issues {
            case .success(let list)?:
                if jiraLocal {
                    // 只补上问题键对应的那一个，放在最前
                    if let hit = list.first(where: { $0.key.caseInsensitiveCompare(query) == .orderedSame }) { results.issues.insert(hit, at: 0) }
                    results.issuesSource = "local"
                } else {
                    results.issues = list
                    results.issuesSource = "jira"
                }
            case .failure(let error)?: results.errors.append("Jira：\(error.localizedDescription)")
            case nil: break
            }
            switch await pages {
            case .success(let list)?: results.pages = list
            case .failure(let error)?: results.errors.append("Wiki：\(error.localizedDescription)")
            case nil: break
            }
            switch await projects {
            case .success(let list)?: results.projects = list
            case .failure(let error)?: results.errors.append("GitLab：\(error.localizedDescription)")
            case nil: break
            }
            switch await mergeRequests {
            case .success(let list)?: results.mergeRequests = list
            case .failure(let error)?: results.errors.append("GitLab 合并请求：\(error.localizedDescription)")
            case nil: break
            }
        }
        return results
    }

    /// 本机问题库、Wiki 库是否可用：系统已配置、开启了本机库，且已经同步过。
    private func jiraIndexReady() async -> Bool {
        guard settings.configuration.snapshot().jiraTools.indexEnabled, (try? await jira.client()) != nil else { return false }
        return (try? await jira.index.isEmpty()) == false
    }

    private func wikiIndexReady() async -> Bool {
        guard settings.configuration.snapshot().wikiTools.indexEnabled, (try? await wiki.client()) != nil else { return false }
        return (try? await wiki.index.isEmpty()) == false
    }

    /// 问题键在本机问题库中找不到（可能是范围外的项目，或刚建的问题）。
    private func keyNotIndexed(_ key: String) async -> Bool {
        (try? await jira.index.byKeys([key.uppercased()]))?.isEmpty ?? true
    }

    /// Wiki 页面：本机 Wiki 库（快，且能匹配两个字的中文词）。
    private func localPages(_ query: String, limit: Int) async throws -> [WikiHit] {
        let client = try await wiki.client()
        return try await wiki.index.search(WikiQuery(text: query, limit: limit)).map {
            WikiHit(id: $0.id, title: $0.title, space: $0.spaceName, url: client.pageURL($0.id), excerpt: $0.snippet)
        }
    }

    /// 未配置的系统返回 nil（直接跳过，不算错误）。
    private func remotePages(_ query: String, limit: Int) async -> Result<[WikiHit], Error>? {
        guard let client = try? await wiki.client() else { return nil }
        do { return .success(try await client.search(query, limit: limit)) } catch { return .failure(error) }
    }

    private func gitlabCall<T>(_ body: (GitLabClient) async throws -> T) async -> Result<T, Error>? {
        guard let client = try? await gitlab.client() else { return nil }
        do { return .success(try await body(client)) } catch { return .failure(error) }
    }

    private func remoteIssues(_ query: String, limit: Int) async -> Result<[IssueHit], Error>? {
        guard let client = try? await jira.client() else { return nil }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let text = "text ~ \"\(escaped)\" ORDER BY updated DESC"
        do {
            let result: SearchResult
            if Self.isIssueKey(query) {
                // 问题编号不存在时 Jira 会报错，此时退回全文搜索
                do { result = try await client.search("key = \"\(query.uppercased())\" OR \(text)", maxResults: limit) } catch { result = try await client.search(text, maxResults: limit) }
            } else {
                result = try await client.search(text, maxResults: limit)
            }
            return .success(result.issues.map { IssueHit(issue: $0, resolved: nil, commentCount: 0, snippet: nil, lastComments: []) })
        } catch {
            return .failure(error)
        }
    }

    /// 形如 `ABC-123` 的问题编号。
    static func isIssueKey(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*-[0-9]+/) != nil
    }
}
