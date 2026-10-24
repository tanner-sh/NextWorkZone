import AppKit
import Foundation

enum PageID: String, CaseIterable, Hashable, Codable {
    case home, todos, notes, kb, jira, activity, weekly, wiki, gitlab, stats, tools, settings, search
}

/// 跳转时附带的目标，例如打开某个 Jira 问题或 GitLab 项目。
struct NavTarget: Equatable {
    var page: PageID
    var issueKey: String?
    var projectId: Int?
    /// 笔记或知识库页面
    var docId: String?
    var todoId: String?
    /// 在问题列表中执行的 JQL（例如“查看全部相似问题”）
    var jql: String?
    /// Wiki 页面 id（或页面地址）
    var wikiPage: String?
    /// 在 Wiki 中搜索的文字
    var wikiSearch: String?
    /// 页面内的锚点（标题 id）
    var anchor: String?
    /// GitLab 项目路径（例如 group/project），找不到 id 时使用
    var projectPath: String?
    /// GitLab 合并请求编号（项目内的 !iid）
    var mrIid: Int?
    /// GitLab 分支（或 tree/ 之后的路径）
    var gitRef: String?
    var commitSha: String?
    /// 工具 id，与 page: .tools 一起使用
    var tool: String?
    /// 工具页面中的标签，例如 settings
    var toolTab: String?
    /// 工具页面中的搜索文字
    var toolQuery: String?
    var searchQuery: String?
    /// 搜索页的范围
    var searchScope: String?
    /// 每次跳转都不同，让页面即使目标相同也再处理一次。
    var nonce = UUID()

    init(_ page: PageID, issueKey: String? = nil, projectId: Int? = nil, docId: String? = nil, todoId: String? = nil, jql: String? = nil, wikiPage: String? = nil, wikiSearch: String? = nil, anchor: String? = nil, projectPath: String? = nil, mrIid: Int? = nil, gitRef: String? = nil, commitSha: String? = nil, tool: String? = nil, toolTab: String? = nil, toolQuery: String? = nil, searchQuery: String? = nil, searchScope: String? = nil) {
        self.page = page
        self.issueKey = issueKey
        self.projectId = projectId
        self.docId = docId
        self.todoId = todoId
        self.jql = jql
        self.wikiPage = wikiPage
        self.wikiSearch = wikiSearch
        self.anchor = anchor
        self.projectPath = projectPath
        self.mrIid = mrIid
        self.gitRef = gitRef
        self.commitSha = commitSha
        self.tool = tool
        self.toolTab = toolTab
        self.toolQuery = toolQuery
        self.searchQuery = searchQuery
        self.searchScope = searchScope
    }
}

// MARK: - 系统地址 → 应用内目标

/// 把系统地址（Jira 问题、Wiki 页面、GitLab 项目）转成应用内的跳转目标，避免打开浏览器。与 src/lib/links.ts 相同。
enum Links {
    enum Route {
        case target(NavTarget)
        /// Wiki 的短链接等需要向服务器解析
        case wiki
    }

    /// GitLab 地址中不是项目的路径开头。
    private static let gitlabReserved: Set<String> = ["users", "dashboard", "explore", "help", "admin", "profile", "search", "-", "api", "assets", "uploads"]
    /// 旧式（不带 /-/）的项目内页面路径。
    private static let gitlabProjectPages: Set<String> = ["tree", "blob", "commits", "commit", "merge_requests", "issues", "branches", "tags", "compare", "raw", "blame", "pipelines", "jobs", "wikis"]

    private static func systemOf(_ url: String, baseUrl: (Service) -> String) -> (Service, String)? {
        for service in Service.allCases {
            let base = baseUrl(service)
            if !base.isEmpty && (url == base || url.hasPrefix(base + "/") || url.hasPrefix(base + "?")) {
                let path = String(url.dropFirst(base.count))
                return (service, path.isEmpty ? "/" : path)
            }
        }
        return nil
    }

    static func route(_ url: String, baseUrl: (Service) -> String) -> Route? {
        guard let (service, path) = systemOf(url.trimmingCharacters(in: .whitespaces), baseUrl: baseUrl) else { return nil }
        let hash = path.contains("#") ? path.components(separatedBy: "#")[1].removingPercentEncoding : nil
        switch service {
        case .jira:
            if let m = path.firstMatch(of: /^\/browse\/([A-Z][A-Z0-9_]+-\d+)/) {
                return .target(NavTarget(.jira, issueKey: String(m.1)))
            }
            let query = path.components(separatedBy: "?").dropFirst().first?.components(separatedBy: "#").first ?? ""
            if let key = URLComponents(string: "?" + query)?.queryItems?.first(where: { $0.name == "selectedIssue" })?.value {
                return .target(NavTarget(.jira, issueKey: key))
            }
            return nil
        case .confluence:
            if path.firstMatch(of: /^\/(download|rest|plugins|images|s)\//) != nil { return nil }
            if let m = path.firstMatch(of: /[?&]pageId=(\d+)/) { return .target(NavTarget(.wiki, wikiPage: String(m.1), anchor: hash)) }
            if let m = path.firstMatch(of: /^\/pages\/(\d+)(\/|$)/) { return .target(NavTarget(.wiki, wikiPage: String(m.1), anchor: hash)) }
            if path.firstMatch(of: /^\/(x|display|spaces|pages)\//) != nil { return .wiki }
            return nil
        case .gitlab:
            let clean = path.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
            let segments = clean.split(separator: "/").map(String.init)
            if segments.count < 2 || gitlabReserved.contains(segments[0]) { return nil }
            let dash = segments.firstIndex(of: "-") ?? -1
            let legacy = segments.indices.first(where: { $0 >= 2 && gitlabProjectPages.contains(segments[$0]) }) ?? -1
            let end = dash > 0 ? dash : legacy
            let projectPath = (end > 0 ? Array(segments[..<end]) : segments).joined(separator: "/")
            let pageIndex = dash > 0 ? end + 1 : end
            let kind = end > 0 && pageIndex < segments.count ? segments[pageIndex] : nil
            let args = end > 0 && pageIndex + 1 <= segments.count ? segments[(pageIndex + 1)...].map { $0.removingPercentEncoding ?? $0 } : []
            if kind == "merge_requests", let iid = args.first.flatMap(Int.init), iid > 0 {
                return .target(NavTarget(.gitlab, projectPath: projectPath, mrIid: iid))
            }
            if kind == "commit", let sha = args.first, sha.wholeMatch(of: /[0-9a-fA-F]{7,40}/) != nil {
                return .target(NavTarget(.gitlab, projectPath: projectPath, commitSha: sha.lowercased()))
            }
            if let kind, ["tree", "commits", "blob"].contains(kind), !args.isEmpty {
                return .target(NavTarget(.gitlab, projectPath: projectPath, gitRef: args.joined(separator: "/")))
            }
            return .target(NavTarget(.gitlab, projectPath: projectPath))
        }
    }

    /// 解析地址为应用内目标；不是系统地址时返回 `nil`。
    @MainActor static func resolve(_ url: String) async -> NavTarget? {
        let base = { (s: Service) in AppModel.shared.baseUrl(s) }
        switch route(url, baseUrl: base) {
        case .target(let t): return t
        case .wiki:
            guard let id = (try? await API.shared.wikiResolve(url)) ?? nil else { return nil }
            return NavTarget(.wiki, wikiPage: id, anchor: url.contains("#") ? url.components(separatedBy: "#")[1].removingPercentEncoding : nil)
        case nil: return nil
        }
    }

    /// 点击链接：系统内的地址在应用内打开，其他地址用浏览器打开。
    @MainActor static func open(_ url: String) {
        Task {
            if let target = await resolve(url) {
                AppModel.shared.navigate(target)
            } else if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        }
    }

    /// 在浏览器中打开。
    static func openInBrowser(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
