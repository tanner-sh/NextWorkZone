import SwiftUI

/// 开始编写新页面所需的信息。
struct NewPageRequest: Hashable {
    var space: String
    var parent: String?
    var parentTitle: String?
    var title: String
    /// Confluence 模板 id
    var template: String?
    /// 由知识库页面转换来的 storage
    var storage: String?
}

/// 正在编辑的页面，或正在新建的页面。
enum WikiEditing: Hashable {
    case edit(String)
    case new(NewPageRequest)
}

/// Wiki：最近、收藏、空间页面树、搜索，右侧阅读和编辑页面。
struct WikiPage: View {
    enum Tab: String { case recent, favorites, spaces, search }

    private static let tabKey = "nextworkzone.wiki.tab"
    private static let lastPageKey = "nextworkzone.wiki.lastPage"

    @Environment(AppModel.self) private var model
    @State private var tab = Tab(rawValue: AppPreferences.shared.string(forKey: WikiPage.tabKey) ?? "") ?? .recent
    @State private var selected: String? = AppPreferences.shared.string(forKey: WikiPage.lastPageKey)
    @State private var anchor: String?
    @State private var detail: WikiPageDetail?
    @State private var editing: WikiEditing?
    @State private var creating: CreateTarget?
    @State private var reloadKey = 0
    @State private var tree = SpaceTree()
    @State private var searchText = ""

    var body: some View {
        Group {
            if model.settings == nil {
                LoadingView()
            } else if !model.isReady(.confluence) {
                NotConfigured(label: "Wiki")
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 260, idealWidth: 300, maxWidth: 460)
                    detailPane.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { takeTarget() }
        .onChange(of: model.pending?.nonce) { takeTarget() }
        .task(id: model.isReady(.confluence)) { if model.isReady(.confluence) { tree.loadSpaces() } }
        #if DEBUG
        // 调试通道 /wiki-edit：打开页面的编辑器（只读取，不保存）
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("nwz.debug.wikiEdit"))) { n in
            if let id = n.object as? String { editing = .edit(id) }
        }
        #endif
        .sheet(item: $creating) { c in
            NewPageSheet(space: c.space, parent: c.parent) { request in editing = .new(request) }
        }
    }

    private struct CreateTarget: Identifiable {
        var space: String
        var parent: String?
        var id: String { "\(space)|\(parent ?? "")" }
    }

    private func takeTarget() {
        guard let t = model.take(.wiki) else { return }
        if let page = t.wikiPage {
            selected = page
            anchor = t.anchor
            editing = nil
        }
        if let q = t.wikiSearch {
            searchText = q
            switchTab(.search)
        }
    }

    private func switchTab(_ next: Tab) {
        tab = next
        AppPreferences.shared.set(next.rawValue, forKey: Self.tabKey)
    }

    private func open(_ id: String) {
        selected = id
        anchor = nil
        editing = nil
        AppPreferences.shared.set(id, forKey: Self.lastPageKey)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { tab }, set: { switchTab($0) })) {
                Label("最近", systemImage: "clock").tag(Tab.recent)
                Label("收藏", systemImage: "star").tag(Tab.favorites)
                Label("空间", systemImage: "folder").tag(Tab.spaces)
                Label("搜索", systemImage: "magnifyingglass").tag(Tab.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            switch tab {
            case .recent: RecentList(selected: $selected, onOpen: open)
            case .favorites: FavoriteList(selected: $selected, onOpen: open)
            case .spaces: SpaceTreeView(tree: tree, selected: selected, onOpen: open) { space, parent in creating = CreateTarget(space: space, parent: parent) }
            case .search: WikiSearchPanel(text: $searchText, spaces: tree.spaces ?? [], selected: $selected, onOpen: open)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let target = editing {
            WikiPageEditor(target: target) { editing = nil } onSaved: { id in
                if case .new(let req) = target { tree.refreshChildren(req.parent ?? "space:\(req.space)") }
                editing = nil
                selected = id
                reloadKey += 1
            }
            .id(target)
        } else if let pageId = selected {
            PageView(pageId: pageId, anchor: anchor, onOpen: open, onLoaded: { page in
                detail = page
                AppPreferences.shared.set(page.id, forKey: Self.lastPageKey)
                // 解析过的地址换成页面 id，刷新时不用再解析
                if selected != page.id { selected = page.id }
                tree.reveal(page)
            }, onEdit: { editing = .edit(pageId) }, onNewChild: {
                if let d = detail { creating = CreateTarget(space: d.spaceKey, parent: d.id) }
            })
            .id("\(pageId)-\(reloadKey)")
        } else {
            ContentUnavailableView("从左侧选择页面，或搜索 Wiki", systemImage: "text.book.closed")
        }
    }
}

// MARK: - 最近、收藏

private struct RecentList: View {
    @Binding var selected: String?
    var onOpen: (String) -> Void
    @State private var list: [WikiRecent]?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error { ErrorBox(message: error) { Task { await load() } }.padding(.horizontal, 12) }
            List(selection: Binding(get: { selected }, set: { if let id = $0 { onOpen(id) } })) {
                ForEach(list ?? []) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).lineLimit(2)
                        Text("\(p.space) · \(Fmt.time(ms: p.at))\(p.source == "web" ? " · 网页上查看" : "")").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(p.id)
                    .contextMenu(specs: { WikiMenus.page(id: p.id, title: p.title, space: p.space) })
                }
                if list?.isEmpty == true { Text("还没有查看过 Wiki 页面").foregroundStyle(.secondary) }
            }
            .listStyle(.inset)
            .overlay { if list == nil && error == nil { ProgressView() } }
        }
        .task { await load() }
    }

    private func load() async {
        error = nil
        do { list = try await API.shared.wikiRecent(limit: 50) } catch { self.error = errorMessage(error) }
    }
}

private struct FavoriteList: View {
    @Binding var selected: String?
    var onOpen: (String) -> Void
    @State private var favorites = WikiFavorites.shared

    var body: some View {
        List(selection: Binding(get: { selected }, set: { if let id = $0 { onOpen(id) } })) {
            ForEach(favorites.list) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).lineLimit(2)
                    Text(p.space).font(.caption).foregroundStyle(.secondary)
                }
                .tag(p.id)
                .contextMenu(specs: { WikiMenus.page(id: p.id, title: p.title, space: p.space) })
            }
            if favorites.list.isEmpty { Text("点击页面标题旁的星标收藏常看的页面").foregroundStyle(.secondary) }
        }
        .listStyle(.inset)
    }
}

// MARK: - 空间与页面树

/// 空间列表与按需加载的页面树。节点 id：空间为 `space:<key>`，页面为页面 id。
@MainActor @Observable
final class SpaceTree {
    enum Children {
        case loading
        case failed(String)
        case loaded([WikiNode])
    }

    var spaces: [WikiSpace]?
    var error: String?
    var children: [String: Children] = [:]
    var expanded: Set<String> = []
    private var requested: Set<String> = []

    func loadSpaces() {
        error = nil
        Task {
            if spaces == nil, let cached = try? await API.shared.wikiCachedSpaces() { spaces = cached }
            do { spaces = try await API.shared.wikiSpaces() } catch { self.error = errorMessage(error) }
        }
    }

    func fetch(_ id: String, force: Bool = false) {
        if requested.contains(id) && !force { return }
        requested.insert(id)
        if case .loaded = children[id] {} else { children[id] = .loading }
        Task {
            do {
                let list = id.hasPrefix("space:") ? try await API.shared.wikiSpaceRoots(String(id.dropFirst(6))) : try await API.shared.wikiChildren(id)
                children[id] = .loaded(list)
            } catch {
                requested.remove(id)
                children[id] = .failed(errorMessage(error))
            }
        }
    }

    func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            fetch(id)
            expanded.insert(id)
        }
    }

    /// 打开页面时展开它所在的空间和各级上级页面。
    func reveal(_ page: WikiPageDetail) {
        let chain = ["space:\(page.spaceKey)"] + page.ancestors.map(\.id)
        for id in chain {
            expanded.insert(id)
            fetch(id)
        }
    }

    func refreshChildren(_ id: String) { fetch(id, force: true) }
}

private struct SpaceTreeView: View {
    var tree: SpaceTree
    var selected: String?
    var onOpen: (String) -> Void
    var onCreate: (String, String?) -> Void
    @State private var filter = ""

    private enum Row: Identifiable {
        case space(WikiSpace)
        case page(WikiNode, WikiSpace, depth: Int)
        case note(String, depth: Int, id: String)

        var id: String {
            switch self {
            case .space(let s): "space:\(s.key)"
            case .page(let n, _, _): n.id
            case .note(_, _, let id): id
            }
        }
    }

    /// 展开后的可见行（按需加载的树拍平）。
    private var rows: [Row] {
        let q = filter.lowercased()
        var out: [Row] = []
        func add(_ id: String, space: WikiSpace, depth: Int) {
            switch tree.children[id] {
            case .loaded(let list):
                if list.isEmpty { out.append(.note("没有页面", depth: depth, id: "\(id)#empty")) }
                for node in list {
                    out.append(.page(node, space, depth: depth))
                    if node.hasChildren && tree.expanded.contains(node.id) { add(node.id, space: space, depth: depth + 1) }
                }
            case .failed(let m): out.append(.note(m, depth: depth, id: "\(id)#error"))
            default: out.append(.note("加载中…", depth: depth, id: "\(id)#loading"))
            }
        }
        for s in tree.spaces ?? [] where q.isEmpty || "\(s.name) \(s.key)".lowercased().contains(q) {
            out.append(.space(s))
            if tree.expanded.contains("space:\(s.key)") { add("space:\(s.key)", space: s, depth: 1) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选空间", text: $filter).textFieldStyle(.plain)
                Button { tree.loadSpaces() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新")
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .padding(.horizontal, 12)
            if let e = tree.error { ErrorBox(message: e) { tree.loadSpaces() }.padding(.horizontal, 12) }
            List(selection: Binding(get: { selected }, set: { id in if let id, !id.hasPrefix("space:"), !id.contains("#") { onOpen(id) } })) {
                ForEach(rows) { row in
                    switch row {
                    case .space(let s): spaceRow(s)
                    case .page(let n, let s, let depth): pageRow(n, space: s, depth: depth)
                    case .note(let text, let depth, _):
                        Text(text).font(.caption).foregroundStyle(.secondary).padding(.leading, CGFloat(depth) * 14 + 18)
                    }
                }
                if tree.spaces?.isEmpty == false && rows.isEmpty { Text("没有匹配的空间").foregroundStyle(.secondary) }
            }
            .listStyle(.inset)
            .overlay { if tree.spaces == nil && tree.error == nil { ProgressView() } }
        }
    }

    private func spaceRow(_ s: WikiSpace) -> some View {
        let id = "space:\(s.key)"
        let open = tree.expanded.contains(id)
        return HStack(spacing: 4) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).frame(width: 14)
            Image(systemName: "globe").foregroundStyle(.secondary)
            Text(s.name).lineLimit(1)
            Spacer()
            if let home = s.homepageId {
                Button { onOpen(home) } label: { Image(systemName: "text.book.closed") }.buttonStyle(.borderless).help("打开空间首页")
            }
            Button { onCreate(s.key, nil) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("在空间顶层新建页面")
        }
        .help(s.description.isEmpty ? s.name : s.description)
        .rowTap { tree.toggle(id) }
        .tag(id)
        .contextMenu(specs: { [.action(open ? "收起" : "展开") { tree.toggle(id) }, .separator] + WikiMenus.space(s, onCreate: { onCreate(s.key, nil) }, onRefresh: open ? { tree.refreshChildren(id) } : nil) })
    }

    private func pageRow(_ n: WikiNode, space: WikiSpace, depth: Int) -> some View {
        let open = tree.expanded.contains(n.id)
        return HStack(spacing: 4) {
            if n.hasChildren {
                Button { tree.toggle(n.id) } label: { Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).frame(width: 14) }.buttonStyle(.plain)
            } else {
                Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary).frame(width: 14)
            }
            Text(n.title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth - 1) * 14)
        .help(n.title)
        .tag(n.id)
        .contextMenu(specs: {
            var specs = WikiMenus.page(id: n.id, title: n.title, space: space.name, onNewChild: { onCreate(space.key, n.id) })
            if n.hasChildren {
                specs.append(.separator)
                specs.append(.action(open ? "收起" : "展开") { tree.toggle(n.id) })
                if open { specs.append(.action("刷新子页面") { tree.refreshChildren(n.id) }) }
            }
            return specs
        })
    }
}

// MARK: - 搜索

private struct WikiSearchPanel: View {
    @Binding var text: String
    var spaces: [WikiSpace]
    @Binding var selected: String?
    var onOpen: (String) -> Void
    @State private var space = ""
    @State private var days = 0
    @State private var mine = false
    @State private var server = false
    @State private var result: WikiSearchResult?
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private static let dayOptions = [(0, "不限时间"), (7, "最近一周"), (30, "最近一月"), (365, "最近一年")]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if loading { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                    TextField("搜索标题和正文", text: $text).textFieldStyle(.plain).focused($focused)
                }
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                HStack {
                    Picker("", selection: $space) {
                        Text("全部空间").tag("")
                        ForEach(spaces) { s in Text(s.name).tag(s.key) }
                    }
                    Picker("", selection: $days) {
                        ForEach(Self.dayOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("我修改的", isOn: $mine).toggleStyle(.checkbox)
                }
                .labelsHidden()
                .controlSize(.small)
                if let result {
                    HStack {
                        Text(result.source == "local" ? "本机 Wiki 库 · \(result.hits.count) 个结果" : "Confluence 搜索 · 共 \(result.total) 个")
                        Spacer()
                        Button(server ? "改用本机搜索" : "在服务器上搜索") { server.toggle() }.buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            if let error { ErrorBox(message: error).padding(.horizontal, 12) }
            List(selection: Binding(get: { selected }, set: { if let id = $0 { onOpen(id) } })) {
                ForEach(result?.hits ?? []) { h in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlighted(h.title, text)).lineLimit(2)
                        if !h.snippet.isEmpty { Text(highlighted(h.snippet, text)).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        Text("\(h.spaceName)\(h.ancestors.last.map { " › \($0.title)" } ?? "")\(h.authorName.isEmpty ? "" : " · \(h.authorName)")\(h.modified.isEmpty ? "" : " · \(Fmt.time(h.modified))")")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(h.id)
                    .contextMenu(specs: { WikiMenus.page(id: h.id, title: h.title, space: h.spaceName) })
                }
                if let result, result.hits.isEmpty { Text("没有找到页面").foregroundStyle(.secondary) }
                if result == nil && !loading { Text("输入关键词搜索；多个关键词用空格分开，需全部出现").foregroundStyle(.secondary) }
            }
            .listStyle(.inset)
        }
        .onAppear { focused = true }
        .task(id: "\(text)|\(space)|\(days)|\(mine)|\(server)") {
            let q = text.trimmingCharacters(in: .whitespaces)
            if q.isEmpty && space.isEmpty && days == 0 && !mine {
                result = nil
                return
            }
            loading = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                result = try await API.shared.wikiSearch(WikiQuery(text: q, space: space, mine: mine, days: days), server: server)
                error = nil
            } catch {
                if !Task.isCancelled { self.error = errorMessage(error) }
            }
            loading = false
        }
    }
}

// MARK: - 新建页面

/// 新建 Wiki 页面：填写标题，选择从空白页、Confluence 模板或知识库页面开始，然后进入编辑器（保存时才创建）。
private struct NewPageSheet: View {
    var space: String
    var parent: String?
    var onStart: (NewPageRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var source = "blank"
    @State private var templates: [WikiTemplate] = []
    @State private var kbPages: [DocSummary] = []
    @State private var parentTitle: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建 Wiki 页面").font(.headline)
            Text("位置：\(space) 空间\(parent != nil ? "「\(parentTitle ?? "…")」下" : "顶层")。编写完成并确认保存后才会在 Wiki 上创建。").font(.callout).foregroundStyle(.secondary)
            TextField("页面标题", text: $title).textFieldStyle(.roundedBorder).onSubmit(start)
            Picker("内容", selection: $source) {
                Text("空白页面").tag("blank")
                if !templates.isEmpty {
                    Section("Confluence 模板") {
                        ForEach(templates) { t in Text("\(t.name)\(t.spaceKey.map { "（\($0)）" } ?? "")").tag("template:\(t.id)") }
                    }
                }
                if !kbPages.isEmpty {
                    Section("从知识库页面") {
                        ForEach(kbPages) { p in Text(p.title.isEmpty ? "无标题" : p.title).tag("kb:\(p.id)") }
                    }
                }
            }
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始编写", action: start).keyboardShortcut(.defaultAction).disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            templates = (try? await API.shared.wikiTemplates(space: space)) ?? []
            kbPages = (try? await API.shared.wsDocs("page")) ?? []
            if let parent { parentTitle = try? await API.shared.wikiPageVersion(parent).title }
        }
    }

    private func start() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        busy = true
        Task {
            do {
                var storage: String?
                if source.hasPrefix("kb:") {
                    let doc = try await API.shared.wsDoc(String(source.dropFirst(3)))
                    let converted = try await Rich.markdownToStorage(doc?.content ?? "")
                    if !converted.assets.isEmpty { toast("知识库页面中的图片不会带过去，可以在网页上补充") }
                    storage = converted.storage
                }
                onStart(NewPageRequest(space: space, parent: parent, parentTitle: parentTitle, title: t, template: source.hasPrefix("template:") ? String(source.dropFirst(9)) : nil, storage: storage))
                dismiss()
            } catch {
                self.error = errorMessage(error)
                busy = false
            }
        }
    }
}
