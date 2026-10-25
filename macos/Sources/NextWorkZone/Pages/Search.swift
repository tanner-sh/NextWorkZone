import SwiftUI

/// 统一搜索：输入停顿后搜索——本机数据停顿 100 毫秒就查，服务器停顿 250 毫秒才查（避免边输入边发请求）。
/// 少于两个字或是网址时不搜索。⌘K 和搜索页共用。
@MainActor @Observable
final class UnifiedSearch {
    var results: SearchResults?
    /// 本机结果已出，服务器结果还在查
    var pending = false
    var error: String?
    private var task: Task<Void, Never>?
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// 两次结果合并：服务器这一步补上 GitLab、未建库时的 Jira 和 Wiki，以及问题键对应的问题。
    private static func merge(_ local: SearchResults, _ remote: SearchResults) -> SearchResults {
        var out = local
        out.issues = remote.issuesSource == "jira" ? remote.issues : remote.issues + local.issues.filter { i in !remote.issues.contains { $0.key == i.key } }
        out.issuesSource = remote.issuesSource ?? local.issuesSource
        out.pages = remote.pages.isEmpty ? local.pages : remote.pages
        out.projects = remote.projects
        out.mergeRequests = remote.mergeRequests
        out.errors = local.errors + remote.errors
        return out
    }

    func search(_ query: String) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count < 2 || q.hasPrefix("http://") || q.hasPrefix("https://") {
            results = nil
            pending = false
            error = nil
            return
        }
        pending = true
        let limit = self.limit
        task = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            async let localTask = API.shared.globalSearch(q, options: SearchOptions(phase: "local", limit: limit))
            async let remoteTask: SearchResults = {
                try await Task.sleep(for: .milliseconds(150))
                return try await API.shared.globalSearch(q, options: SearchOptions(phase: "remote", limit: limit))
            }()
            do {
                let local = try await localTask
                guard !Task.isCancelled else { return }
                results = local
                error = nil
                let remote = try await remoteTask
                guard !Task.isCancelled else { return }
                results = Self.merge(local, remote)
                pending = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = errorMessage(error)
                pending = false
            }
        }
    }
}

/// 剪贴板条目的一行摘要。
func clipLine(_ text: String, _ title: String) -> String {
    if !title.isEmpty { return title }
    return text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? text.trimmingCharacters(in: .whitespaces)
}

/// 复制剪贴板历史中的条目。
@MainActor func copyClip(_ id: String) {
    guarded {
        try await API.shared.clipCopy([id])
        toast("已复制")
    }
}

let hitIcons = ["todo": "checkmark.square", "note": "note.text", "daily": "calendar", "page": "book"]

// MARK: - ⌘K

/// ⌘K 全局搜索：页面跳转、新建待办，同时搜索工作空间和 Jira、GitLab、Wiki、剪贴板。
struct CommandPalette: View {
    struct Item: Identifiable {
        var id: String
        var icon: String
        var group: String
        var title: String
        var subtitle: String?
        var status: JiraStatus?
        var highlight = true
        var run: () -> Void
    }

    static let pages: [(PageID, String, String)] = [
        (.home, "今天", "home 首页 今天 概览 需要处理 收件箱 inbox jt"),
        (.todos, "待办", "todo 待办 任务 db"),
        (.notes, "笔记", "notes 笔记 日记 bj rj"),
        (.kb, "知识库", "kb wiki 知识库 文档 zsk"),
        (.jira, "Jira", "jira issue 问题 我的问题 wt"),
        (.activity, "动态", "activity 动态 通知 提醒 dt tz"),
        (.weekly, "周报", "weekly wiki 周报 zb"),
        (.wiki, "Wiki", "wiki confluence 文档 页面 空间 wd"),
        (.gitlab, "GitLab", "gitlab code 代码 项目 合并请求 dm"),
        (.stats, "统计", "stats 统计 报表 tj"),
        (.settings, "设置", "settings 设置 sz"),
    ]

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var search = UnifiedSearch(limit: 8)
    @State private var active = 0
    @FocusState private var focused: Bool

    private var searchable: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.count >= 2 && !q.hasPrefix("http")
    }

    private func close() { model.paletteOpen = false }

    private struct Row {
        var id: String
        var header: String?
        var index: Int?
    }

    /// 分组标题和条目排成一列。
    private func rows(_ list: [Item]) -> [Row] {
        var out: [Row] = []
        for (i, item) in list.enumerated() {
            if i == 0 || list[i - 1].group != item.group { out.append(Row(id: "h:\(item.group):\(i)", header: item.group)) }
            out.append(Row(id: item.id, index: i))
        }
        return out
    }

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let go: (@escaping () -> Void) -> () -> Void = { fn in { fn(); model.paletteOpen = false } }
        var list: [Item] = Self.pages.filter { q.isEmpty || $0.1.contains(q) || $0.2.contains(q) }.map { p in
            Item(id: "page-\(p.0.rawValue)", icon: "return", group: "跳转", title: p.1, run: go { model.navigate(p.0) })
        }
        for tool in Tools.all where q.isEmpty || tool.name.contains(q) || tool.keywords.contains(q) {
            list.append(Item(id: "tool-\(tool.id)", icon: tool.icon, group: "工具", title: tool.name, subtitle: tool.description, run: go { model.navigate(NavTarget(.tools, tool: tool.id)) }))
        }
        // 粘贴的 Jira、Wiki、GitLab 地址：直接在应用内打开
        let raw = query.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://"), let route = Links.route(raw, baseUrl: { model.baseUrl($0) }) {
            var title = "在应用内打开 Wiki 页面"
            if case .target(let t) = route {
                title = t.page == .jira ? "打开问题 \(t.issueKey ?? "")" : t.page == .wiki ? "在应用内打开 Wiki 页面" : t.mrIid != nil ? "打开合并请求 \(t.projectPath ?? "")!\(t.mrIid!)" : "打开项目 \(t.projectPath ?? "")"
            }
            list.insert(Item(id: "open-url", icon: "return", group: "打开链接", title: title, subtitle: raw, run: go { Links.open(raw) }), at: 0)
        }
        if q.isEmpty || "新建待办 xjdb todo".contains(q) {
            list.append(Item(id: "action-todo", icon: "plus", group: "操作", title: "新建待办", subtitle: "⌘⇧N", run: go { model.quickTodoOpen = true }))
        }
        if searchable {
            list.append(Item(id: "search-page", icon: "line.3.horizontal.decrease", group: "搜索", title: "查看“\(raw)”的全部结果", subtitle: "按类型筛选 · ⌘↵", highlight: false, run: go { model.navigate(NavTarget(.search, searchQuery: raw)) }))
            if model.isReady(.confluence) {
                list.append(Item(id: "wiki-search", icon: "magnifyingglass", group: "搜索", title: "在 Wiki 中搜索“\(raw)”", subtitle: "按空间、时间筛选", highlight: false, run: go { model.navigate(NavTarget(.wiki, wikiSearch: raw)) }))
            }
        }
        let r = search.results
        for h in r?.workspace ?? [] {
            list.append(Item(id: "ws-\(h.itemType)-\(h.id)", icon: h.itemType == "todo" && !h.done ? "square" : hitIcons[h.kind] ?? "doc", group: "工作空间", title: h.title.isEmpty ? "无标题" : h.title, subtitle: "\(backlinkKindLabel[h.kind] ?? "")\(h.snippet.isEmpty ? "" : " · \(h.snippet)")", run: go {
                model.navigate(h.itemType == "todo" ? NavTarget(.todos, todoId: h.id) : NavTarget(h.kind == "page" ? .kb : .notes, docId: h.id))
            }))
        }
        for i in r?.issues ?? [] {
            let subtitle = i.snippet.map { s in "\(s.source == "comment" ? "\(s.author ?? "") 的评论：" : "描述：")\(s.text)" } ?? i.project.name
            list.append(Item(id: "issue-\(i.key)", icon: "smallcircle.filled.circle", group: "Jira 问题", title: "\(i.key) \(i.summary)", subtitle: subtitle, status: i.status, run: go { model.navigate(NavTarget(.jira, issueKey: i.key)) }))
        }
        for w in r?.pages ?? [] {
            list.append(Item(id: "wiki-\(w.id)", icon: "doc.text", group: "Wiki 页面", title: w.title, subtitle: "\(w.space)\(w.excerpt.isEmpty ? "" : " · \(w.excerpt)")", run: go { model.navigate(NavTarget(.wiki, wikiPage: w.id)) }))
        }
        for m in r?.mergeRequests ?? [] {
            list.append(Item(id: "mr-\(m.id)", icon: "arrow.triangle.pull", group: "GitLab 合并请求", title: "!\(m.iid) \(m.title)", subtitle: "\(m.reference.components(separatedBy: "!")[0]) · \(GitLab.stateLabels[m.state] ?? m.state)", run: go { model.navigate(NavTarget(.gitlab, projectId: m.projectId, mrIid: m.iid)) }))
        }
        for p in r?.projects ?? [] {
            list.append(Item(id: "project-\(p.id)", icon: "folder", group: "GitLab 项目", title: p.name, subtitle: p.pathWithNamespace, run: go { model.navigate(NavTarget(.gitlab, projectId: p.id)) }))
        }
        for c in r?.clips ?? [] {
            let line = clipLine(c.text, c.title)
            list.append(Item(id: "clip-\(c.id)", icon: "list.clipboard", group: "剪贴板", title: line.isEmpty ? "（图片或文件）" : line, subtitle: "\(c.appName.map { "\($0) · " } ?? "")回车复制", run: go { copyClip(c.id) }))
        }
        return list
    }

    var body: some View {
        let list = items
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if search.pending { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary) }
                    TextField("搜索待办、笔记、问题、Wiki、代码、剪贴板，或粘贴链接…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { if list.indices.contains(active) { list[active].run() } }
                        .onKeyPress(.downArrow) { active = min(active + 1, list.count - 1); return .handled }
                        .onKeyPress(.upArrow) { active = max(active - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command), searchable else { return .ignored }
                            model.navigate(NavTarget(.search, searchQuery: query.trimmingCharacters(in: .whitespaces)))
                            close()
                            return .handled
                        }
                }
                .padding(14)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rows(list), id: \.id) { row in
                                if let header = row.header {
                                    Text(header).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                                } else if let index = row.index {
                                    let item = list[index]
                                    HStack(spacing: 8) {
                                        Image(systemName: item.icon).frame(width: 18).foregroundStyle(.secondary)
                                        (Text(searchable && item.highlight ? highlighted(item.title, query) : AttributedString(item.title)) + Text(item.subtitle.map { " · \($0)" } ?? "").foregroundStyle(.secondary).font(.caption))
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        if let s = item.status { StatusPill(status: s) }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(index == active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                                    .onHover { if $0 { active = index } }
                                    .onTapGesture { item.run() }
                                    .id(index)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: active) { _, a in proxy.scrollTo(a) }
                }
                Divider()
                HStack(spacing: 14) {
                    if let e = search.error { Text(e).foregroundStyle(.red) }
                    else if let errs = search.results?.errors, !errs.isEmpty { Text(errs.joined(separator: "；")).foregroundStyle(.orange) }
                    else {
                        Text("↑ ↓ 选择")
                        Text("↵ 打开")
                        Text("⌘↵ 全部结果")
                        Text("Esc 关闭")
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(width: 640)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, q in
            active = 0
            search.search(q)
        }
        .onChange(of: list.count) { _, n in active = min(active, max(n - 1, 0)) }
    }
}

// MARK: - 搜索页

/// 统一搜索：工作空间、Jira 问题、Wiki 页面、GitLab 合并请求和项目、剪贴板历史，按类型筛选。
struct SearchPage: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all, workspace, jira, wiki, gitlab, clipboard
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "全部"
            case .workspace: "工作空间"
            case .jira: "Jira"
            case .wiki: "Wiki"
            case .gitlab: "GitLab"
            case .clipboard: "剪贴板"
            }
        }
    }

    /// 每类结果的条数；“全部”中每类只显示前几条。
    static let limit = 50
    static let preview = 5

    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var scope: Scope = .all
    @State private var search = UnifiedSearch(limit: SearchPage.limit)
    @State private var issueMenu = IssueMenu()
    @FocusState private var focused: Bool

    private func count(_ s: Scope) -> Int {
        guard let r = search.results else { return 0 }
        switch s {
        case .workspace: return r.workspace.count
        case .jira: return r.issues.count
        case .wiki: return r.pages.count
        case .gitlab: return r.mergeRequests.count + r.projects.count
        case .clipboard: return r.clips.count
        case .all: return Scope.allCases.dropFirst().reduce(0) { $0 + count($1) }
        }
    }

    var body: some View {
        let q = input.trimmingCharacters(in: .whitespaces)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("搜索").font(.largeTitle.weight(.semibold))
                    Text("本机数据（待办、笔记、知识库、本机问题库和 Wiki 库、剪贴板）先显示，GitLab 等服务器结果随后补上。").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if search.pending { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                    TextField("输入至少两个字", text: $input).textFieldStyle(.plain).font(.title3).focused($focused)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { s in Text(search.results != nil ? "\(s.label) \(count(s))" : s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let e = search.error { ErrorBox(message: e) }
                if let errs = search.results?.errors, !errs.isEmpty { Notice(text: errs.joined(separator: "；")) }
                if q.count < 2 { Text("输入至少两个字开始搜索。").foregroundStyle(.secondary) }
                if search.results != nil && q.count >= 2 && count(scope) == 0 && !search.pending { Text("没有找到相关内容。").foregroundStyle(.secondary) }
                if let r = search.results { groups(r, q: q) }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .issueMenuDialogs(issueMenu)
        .onAppear {
            if let t = model.take(.search) {
                input = t.searchQuery ?? input
                scope = t.searchScope.flatMap(Scope.init) ?? scope
            }
            focused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.navigated)) { _ in
            if let t = model.take(.search), let q = t.searchQuery { input = q }
        }
        .task(id: input) { search.search(input) }
    }

    private func take<T>(_ list: [T]) -> [T] { scope == .all ? Array(list.prefix(Self.preview)) : list }

    @ViewBuilder
    private func groups(_ r: SearchResults, q: String) -> some View {
        let show = { (s: Scope) in scope == .all || scope == s }
        if show(.workspace) && !r.workspace.isEmpty {
            ResultGroup(title: "工作空间", n: r.workspace.count, moreScope: scope == .all && r.workspace.count > Self.preview ? .workspace : nil, onMore: { scope = $0 }) {
                ForEach(take(r.workspace)) { h in
                    ResultRow(icon: h.itemType == "todo" && !h.done ? "square" : hitIcons[h.kind] ?? "doc", title: h.title.isEmpty ? "无标题" : h.title, query: q, meta: backlinkKindLabel[h.kind], snippet: h.snippet, done: h.done) {
                        model.navigate(h.itemType == "todo" ? NavTarget(.todos, todoId: h.id) : NavTarget(h.kind == "page" ? .kb : .notes, docId: h.id))
                    }
                }
            }
        }
        if show(.jira) && !r.issues.isEmpty {
            ResultGroup(title: "Jira 问题", n: r.issues.count, note: r.issuesSource == "local" ? "本机问题库" : "Jira 搜索", moreScope: scope == .all && r.issues.count > Self.preview ? .jira : nil, onMore: { scope = $0 }) {
                ForEach(take(r.issues)) { i in
                    ResultRow(icon: "smallcircle.filled.circle", title: "\(i.key) \(i.summary)", query: q, meta: [i.project.name, i.assignee, i.resolved.map { "\(Fmt.time($0)) 解决" } ?? Fmt.time(i.updated)].compactMap { $0 }.joined(separator: " · "), snippet: i.snippet.map { "\($0.source == "comment" ? "\($0.author ?? "")：" : "")\($0.text)" }, status: i.status) {
                        model.navigate(NavTarget(.jira, issueKey: i.key))
                    }
                    .contextMenu(specs: { issueMenu.specs(.summary(i.summaryValue)) })
                }
            }
        }
        if show(.wiki) && !r.pages.isEmpty {
            ResultGroup(title: "Wiki 页面", n: r.pages.count, moreScope: scope == .all && r.pages.count > Self.preview ? .wiki : nil, onMore: { scope = $0 }) {
                ForEach(take(r.pages)) { w in
                    ResultRow(icon: "doc.text", title: w.title, query: q, meta: w.space, snippet: w.excerpt) { model.navigate(NavTarget(.wiki, wikiPage: w.id)) }
                        .contextMenu(specs: { WikiMenus.page(id: w.id, title: w.title, space: w.space) })
                }
            }
        }
        if show(.gitlab) && !r.mergeRequests.isEmpty {
            ResultGroup(title: "GitLab 合并请求", n: r.mergeRequests.count, moreScope: scope == .all && count(.gitlab) > Self.preview ? .gitlab : nil, onMore: { scope = $0 }) {
                ForEach(take(r.mergeRequests)) { m in
                    ResultRow(icon: "arrow.triangle.pull", title: "!\(m.iid) \(m.title)", query: q, meta: "\(m.reference.components(separatedBy: "!")[0]) · \(m.author.name) · \(Fmt.time(m.updatedAt))", chip: GitLab.stateLabels[m.state] ?? m.state) {
                        model.navigate(NavTarget(.gitlab, projectId: m.projectId, mrIid: m.iid))
                    }
                }
            }
        }
        if show(.gitlab) && !r.projects.isEmpty {
            ResultGroup(title: "GitLab 项目", n: r.projects.count, onMore: { _ in }) {
                ForEach(take(r.projects)) { p in
                    ResultRow(icon: "folder", title: p.name, query: q, meta: p.pathWithNamespace, snippet: p.description) { model.navigate(NavTarget(.gitlab, projectId: p.id)) }
                }
            }
        }
        if show(.clipboard) && !r.clips.isEmpty {
            ResultGroup(title: "剪贴板", n: r.clips.count, note: "点击复制", moreScope: scope == .all && r.clips.count > Self.preview ? .clipboard : nil, onMore: { scope = $0 }) {
                ForEach(take(r.clips)) { c in
                    let line = clipLine(c.text, c.title)
                    ResultRow(icon: "list.clipboard", title: line.isEmpty ? "（图片或文件）" : line, query: q, meta: [c.appName, Fmt.time(ms: c.copiedAt)].compactMap { $0 }.joined(separator: " · "), snippet: c.text.contains("\n") ? c.text : nil) {
                        copyClip(c.id)
                    } trailing: {
                        Button("在剪贴板中查看") { model.navigate(NavTarget(.tools, tool: "clipboard", toolQuery: q)) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }
}

private struct ResultGroup<Content: View>: View {
    var title: String
    var n: Int
    var note: String? = nil
    var moreScope: SearchPage.Scope? = nil
    var onMore: (SearchPage.Scope) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text("\(n)").foregroundStyle(.secondary)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let moreScope { Button("查看全部 \(n) 条") { onMore(moreScope) }.buttonStyle(.link).font(.caption) }
            }
            VStack(spacing: 2) { content() }
        }
    }
}

private struct ResultRow<Trailing: View>: View {
    var icon: String
    var title: String
    var query: String
    var meta: String? = nil
    var snippet: String? = nil
    var done = false
    var status: JiraStatus? = nil
    var chip: String? = nil
    var onOpen: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(title, query)).strikethrough(done).lineLimit(1)
                if let meta, !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let snippet, !snippet.isEmpty { Text(highlighted(snippet, query)).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
            }
            Spacer(minLength: 4)
            if let status { StatusPill(status: status) }
            if let chip { Chip(text: chip) }
            trailing()
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

extension ResultRow where Trailing == EmptyView {
    init(icon: String, title: String, query: String, meta: String? = nil, snippet: String? = nil, done: Bool = false, status: JiraStatus? = nil, chip: String? = nil, onOpen: @escaping () -> Void) {
        self.init(icon: icon, title: title, query: query, meta: meta, snippet: snippet, done: done, status: status, chip: chip, onOpen: onOpen, trailing: { EmptyView() })
    }
}
