import SwiftUI

/// 合并请求的来源：跨项目（我发起的、请我审核、指派给我）或某个项目。
enum MrSource: Hashable {
    case scope(String)
    case project(String)
}

/// 分页加载合并请求。
@MainActor @Observable
final class MrListModel {
    var items: [MergeRequest]?
    var hasMore = false
    var loading = false
    var error: String?
    private var page = 1
    private var key = ""
    private var state = ""

    /// 每页条数，与应用层一致。
    static let pageSize = 30

    func load(_ source: MrSource, state: String, search: String, page p: Int = 1) async {
        let k = "\(source)|\(state)|\(search)"
        if p == 1 && k != key { items = nil }
        key = k
        self.state = state
        loading = true
        error = nil
        do {
            let query = MrQuery(state: state, search: search.isEmpty ? nil : search, page: p)
            let list: [MergeRequest] = switch source {
            case .scope(let s): try await API.shared.glMergeRequests(scope: s, query: query)
            case .project(let id): try await API.shared.glProjectMergeRequests(id, query: query)
            }
            guard k == key else { return }
            if p == 1 { items = list } else {
                let known = Set((items ?? []).map(\.id))
                items = (items ?? []) + list.filter { !known.contains($0.id) }
            }
            hasMore = list.count == Self.pageSize
            page = p
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
        loading = false
    }

    func loadMore(_ source: MrSource, state: String, search: String) async {
        await load(source, state: state, search: search, page: page + 1)
    }

    var loadedMore: Bool { page > 1 }

    /// 用详情里的最新数据更新列表中的一项。
    func replace(_ mr: MergeRequest) {
        guard var list = items, let i = list.firstIndex(where: { $0.id == mr.id }) else { return }
        // 按状态筛选时，合并、关闭或重新打开后不再符合的移出列表
        if state != "all" && !state.isEmpty && mr.state != state { list.remove(at: i) } else { list[i] = mr }
        items = list
    }
}

let mrStates: [(String, String)] = [("opened", "打开"), ("merged", "已合并"), ("closed", "已关闭"), ("all", "全部")]

/// GitLab：合并请求（跨项目）或项目列表，右侧为详情。
struct GitlabPage: View {
    enum Mode: String { case mrs, projects }

    private static let starredKey = "nextworkzone.gitlab.starred"
    private static let modeKey = "nextworkzone.gitlab.mode"
    private static let scopeKey = "nextworkzone.gitlab.mrScope"
    private static let lastProjectKey = "nextworkzone.gitlab.lastProject"
    static let scopes = [("created_by_me", "我发起的"), ("reviewer", "请我审核"), ("assigned_to_me", "指派给我")]

    struct MrRef: Hashable {
        var project: String
        var iid: Int
        var id: Int?
    }

    struct Opening: Hashable {
        var gitRef: String?
        var commitSha: String?
    }

    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var projects: [Project]?
    @State private var loading = false
    @State private var error: String?
    @State private var filter = ""
    @State private var starred: [Int] = AppPreferences.shared.array(forKey: GitlabPage.starredKey) as? [Int] ?? []
    @State private var selected: Int?
    @State private var mode = Mode(rawValue: AppPreferences.shared.string(forKey: GitlabPage.modeKey) ?? "") ?? .mrs
    @State private var scope = AppPreferences.shared.string(forKey: GitlabPage.scopeKey) ?? "created_by_me"
    @State private var mrState = "opened"
    @State private var mrInput = ""
    @State private var mrSearch = ""
    @State private var selectedMr: MrRef?
    @State private var mrList = MrListModel()
    /// 从链接跳转过来时要打开的分支或提交
    @State private var opening: Opening?
    @State private var pendingPath: String?

    var body: some View {
        Group {
            if model.settings == nil {
                LoadingView()
            } else if !model.isReady(.gitlab) {
                NotConfigured(label: "GitLab")
            } else {
                SplitPane("gitlab", minWidth: 320, idealWidth: 380, maxWidth: 560) {
                    VStack(alignment: .leading, spacing: 8) {
                        if mode == .mrs { mrPane } else { projectPane }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                } trailing: {
                    detail
                }
                .pageToolbar { toolbar }
            }
        }
        .onAppear { takeTarget() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.navigated)) { _ in takeTarget() }
        .task(id: model.isReady(.gitlab)) { if model.isReady(.gitlab) { await loadProjects() } }
        .task(id: "\(scope)|\(mrState)|\(mrSearch)|\(model.isReady(.gitlab))") {
            if model.isReady(.gitlab) { await mrList.load(.scope(scope), state: mrState, search: mrSearch) }
        }
        .onChange(of: visit) {
            // 回到 GitLab 页面或回到应用时在原地刷新；加载过更多时不刷新，免得列表变短
            if model.isReady(.gitlab) && !mrList.loadedMore { Task { await mrList.load(.scope(scope), state: mrState, search: mrSearch) } }
        }
        .onChange(of: projects) { resolvePath() }
    }

    private func takeTarget() {
        guard let t = model.take(.gitlab) else { return }
        if let iid = t.mrIid, let p = t.projectId.map(String.init) ?? t.projectPath {
            mode = .mrs
            selectedMr = MrRef(project: p, iid: iid)
        } else if t.projectId != nil || t.projectPath != nil {
            mode = .projects
            opening = t.gitRef != nil || t.commitSha != nil ? Opening(gitRef: t.gitRef, commitSha: t.commitSha) : nil
            if let id = t.projectId { selected = id } else { pendingPath = t.projectPath; resolvePath() }
        }
    }

    /// 从链接跳转过来时只有项目路径：在列表中找，找不到再按名称搜索。
    private func resolvePath() {
        guard let path = pendingPath?.lowercased(), let projects else { return }
        if let found = projects.first(where: { $0.pathWithNamespace.lowercased() == path }) {
            selected = found.id
            pendingPath = nil
            return
        }
        pendingPath = nil
        Task {
            do {
                let list = try await API.shared.glProjects(search: path.components(separatedBy: "/").last ?? path)
                if let match = list.first(where: { $0.pathWithNamespace.lowercased() == path }) { selected = match.id } else { toast("没有找到项目 \(path)", error: true) }
            } catch { toast(errorMessage(error), error: true) }
        }
    }

    private func setMode(_ m: Mode) {
        mode = m
        AppPreferences.shared.set(m.rawValue, forKey: Self.modeKey)
    }

    private func loadProjects() async {
        loading = true
        error = nil
        if projects == nil, let cached = try? await API.shared.glCachedProjects() { projects = cached }
        do { projects = try await API.shared.glProjects() } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
        loading = false
        // 记住上次打开的项目；没有指定项目时打开它（不在列表里就打开第一个），右侧不留空
        if selected == nil && pendingPath == nil, let list = projects, !list.isEmpty {
            let last = AppPreferences.shared.integer(forKey: Self.lastProjectKey)
            selected = list.contains { $0.id == last } ? last : visible.first?.id
        }
    }

    private func toggleStar(_ id: Int) {
        if starred.contains(id) { starred.removeAll { $0 == id } } else { starred.append(id) }
        AppPreferences.shared.set(starred, forKey: Self.starredKey)
    }

    private var visible: [Project] {
        let q = filter.lowercased()
        let list = (projects ?? []).filter { q.isEmpty || "\($0.pathWithNamespace) \($0.description ?? "")".lowercased().contains(q) }
        return list.filter { starred.contains($0.id) } + list.filter { !starred.contains($0.id) }
    }

    // MARK: 工具栏

    /// 左侧：切换合并请求和项目，合并请求的状态，刷新。详情的操作由 MergeRequestView、ProjectView 放在右侧。
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("显示", selection: Binding(get: { mode }, set: { setMode($0) })) {
                Text("合并请求").tag(Mode.mrs)
                Text("项目").tag(Mode.projects)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .navigation) {
            if mode == .mrs {
                // 工具栏中的菜单样式 Picker 不显示当前值，改用显示状态名的菜单
                Menu {
                    ForEach(mrStates, id: \.0) { st in
                        Toggle(st.1, isOn: Binding(get: { mrState == st.0 }, set: { if $0 { mrState = st.0 } }))
                    }
                } label: {
                    Text(mrStates.first { $0.0 == mrState }?.1 ?? "状态")
                }
                .help("合并请求的状态")
                Button("刷新", systemImage: "arrow.clockwise") { Task { await mrList.load(.scope(scope), state: mrState, search: mrSearch) } }
                    .disabled(mrList.loading).help("刷新")
            } else {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await loadProjects() } }.disabled(loading).help("刷新")
            }
        }
    }

    /// 列表条数，显示在筛选框右侧（窗口不显示 GitLab 页面的标题）。
    private var subtitle: String {
        if mode == .mrs { return mrList.items.map { "\($0.count)\(mrList.hasMore ? "+" : "") 个合并请求" } ?? "" }
        return projects.map { "\($0.count) 个项目" } ?? ""
    }

    // MARK: 合并请求列表

    private var mrPane: some View {
        MrListBody(list: mrList, selected: selectedMr?.id, showProject: true, empty: mrSearch.isEmpty ? "没有合并请求" : "没有匹配的合并请求") { mr in
            selectedMr = MrRef(project: String(mr.projectId), iid: mr.iid, id: mr.id)
        } loadMore: {
            Task { await mrList.loadMore(.scope(scope), state: mrState, search: mrSearch) }
        }
        .listHeader {
            Picker("", selection: Binding(get: { scope }, set: { scope = $0; AppPreferences.shared.set($0, forKey: Self.scopeKey) })) {
                ForEach(Self.scopes, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            FilterField(prompt: "搜索标题，回车", text: $mrInput, trailing: subtitle) { mrSearch = mrInput.trimmingCharacters(in: .whitespaces) }
        }
    }

    // MARK: 项目列表

    private var projectPane: some View {
        List(selection: Binding(get: { selected }, set: { if let id = $0 { openProject(id) } })) {
            ForEach(visible) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(p.name).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(Fmt.time(p.lastActivityAt)).font(.caption).foregroundStyle(.secondary)
                        Button { toggleStar(p.id) } label: {
                            Image(systemName: starred.contains(p.id) ? "star.fill" : "star").foregroundStyle(starred.contains(p.id) ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(starred.contains(p.id) ? "取消收藏" : "收藏")
                    }
                    Text("\(p.pathWithNamespace)\(p.description.map { $0.isEmpty ? "" : " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(p.description.map { "\(p.pathWithNamespace)\n\($0)" } ?? p.pathWithNamespace)
                }
                .padding(.vertical, 2)
                .tag(p.id)
                .contextMenu(specs: { projectMenu(p) })
            }
            if projects != nil && visible.isEmpty { Text("没有匹配的项目").foregroundStyle(.secondary) }
        }
        .listStyle(.inset)
        .overlay { if projects == nil && error == nil { ProgressView() } }
        .listHeader {
            FilterField(prompt: "筛选项目（收藏的项目置顶）", text: $filter, trailing: subtitle)
            if let error { ErrorBox(message: error) { Task { await loadProjects() } } }
        }
    }

    /// 在列表中手动打开项目：不再带着链接中的分支或提交。
    private func openProject(_ id: Int) {
        opening = nil
        selected = id
        AppPreferences.shared.set(id, forKey: Self.lastProjectKey)
    }

    private func projectMenu(_ p: Project) -> [MenuSpec] {
        let copy: (String) -> @MainActor () -> Void = { text in { Pasteboard.copy(text); toast("已复制") } }
        let isStarred = starred.contains(p.id)
        return [
            .action("打开", icon: "folder") { openProject(p.id) },
            .action(isStarred ? "取消收藏" : "收藏", icon: isStarred ? "star.slash" : "star") { toggleStar(p.id) },
            .separator,
            .action("复制项目路径", icon: "doc.on.doc", copy(p.pathWithNamespace)),
            .action("复制克隆地址", icon: "arrow.triangle.branch", copy("\(p.webUrl).git")),
            .action("复制网页地址", copy(p.webUrl)),
            .separator,
            .action("在浏览器中打开", icon: "safari") { Links.openInBrowser(p.webUrl) },
        ]
    }

    @ViewBuilder
    private var detail: some View {
        if mode == .mrs {
            if let ref = selectedMr {
                MergeRequestView(project: ref.project, iid: ref.iid, onChanged: { mrList.replace($0) }).id(ref)
            } else {
                ContentUnavailableView("选择左侧的合并请求", systemImage: "arrow.triangle.pull", description: Text("发起新的合并请求请到「项目」中"))
            }
        } else if let id = selected {
            ProjectView(projectId: id, initialRef: opening?.gitRef, initialCommit: opening?.commitSha)
                .id("\(id)|\(opening?.gitRef ?? "")|\(opening?.commitSha ?? "")")
        } else {
            Text("选择左侧的项目").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 合并请求列表：加载中、错误、空列表和“加载更多”。
struct MrListBody: View {
    var list: MrListModel
    var selected: Int?
    var showProject: Bool
    var empty: String
    var onOpen: (MergeRequest) -> Void
    var loadMore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let e = list.error { ErrorBox(message: e) }
            List(selection: Binding(get: { selected }, set: { id in if let mr = list.items?.first(where: { $0.id == id }) { onOpen(mr) } })) {
                ForEach(list.items ?? []) { mr in
                    MrListItem(mr: mr, showProject: showProject)
                        .tag(mr.id)
                        .contextMenu(specs: { GitLab.mrMenu(mr) { onOpen(mr) } })
                }
                if list.items?.isEmpty == true { Text(empty).foregroundStyle(.secondary) }
                if list.items != nil && list.hasMore {
                    Button(list.loading ? "加载中…" : "加载更多", action: loadMore).disabled(list.loading).frame(maxWidth: .infinity)
                }
            }
            .listStyle(.inset)
            .overlay { if list.items == nil && list.error == nil { ProgressView() } }
        }
    }
}

private struct MrListItem: View {
    var mr: MergeRequest
    var showProject: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(showProject ? (GitLab.projectPath(mr).components(separatedBy: "/").last ?? "") + " " : "")!\(mr.iid)").font(.callout.monospaced()).foregroundStyle(.secondary)
                if mr.draft { Chip(text: "草稿") }
                if mr.state != "opened" { MrStatePill(state: mr.state) }
                Spacer()
            }
            Text(mr.title).lineLimit(2)
            HStack(spacing: 6) {
                Avatar(name: mr.author.name, size: 16)
                Text("\(mr.author.name) · \(mr.sourceBranch) → \(mr.targetBranch)").lineLimit(1)
                Spacer()
                if mr.state == "opened" && mr.hasConflicts { Image(systemName: "exclamationmark.circle").foregroundStyle(.red).help("有冲突") }
                if mr.userNotesCount > 0 { Label("\(mr.userNotesCount)", systemImage: "bubble.left").labelStyle(.titleAndIcon) }
                Text(Fmt.time(mr.updatedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
