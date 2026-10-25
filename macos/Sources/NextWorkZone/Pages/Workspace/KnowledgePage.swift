import SwiftUI

/// 知识库：树状组织的页面，支持标签、从 Jira 沉淀、剪藏 Wiki、发布到 Wiki。
struct KnowledgePage: View {
    private static let expandedKey = "nextworkzone.kb.expanded"

    @Environment(AppModel.self) private var model
    @Environment(\.pageActive) private var active
    @State private var pages: [DocSummary]?
    @State private var selected: String?
    @State private var expanded: Set<String> = Set(AppPreferences.shared.stringArray(forKey: KnowledgePage.expandedKey) ?? [])
    @State private var filter = ""
    @State private var tag: String?
    @State private var importKind: ImportKind?
    @State private var pageDialog: PageDialog?
    @State private var error: String?

    enum ImportKind: String, Identifiable {
        case jira, wiki
        var id: String { rawValue }
    }

    struct PageDialog: Identifiable {
        enum Kind { case move, publish }
        var kind: Kind
        var doc: Doc
        var id: String { "\(kind)-\(doc.id)" }
    }

    /// 按上级分组的页面；上级被删除的页面显示在顶层。
    private var byParent: [String: [DocSummary]] {
        let list = pages ?? []
        let ids = Set(list.map(\.id))
        var map: [String: [DocSummary]] = [:]
        for p in list {
            let parent = p.parentId.flatMap { ids.contains($0) ? $0 : nil } ?? ""
            map[parent, default: []].append(p)
        }
        for k in map.keys { map[k]!.sort { $0.sort != $1.sort ? $0.sort < $1.sort : $0.title < $1.title } }
        return map
    }

    private var allTags: [String] { Array(Set((pages ?? []).flatMap(\.tags))).sorted() }
    private var filtering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty || tag != nil }
    private var matches: [DocSummary] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return (pages ?? []).filter { (tag == nil || $0.tags.contains(tag!)) && (q.isEmpty || "\($0.title) \($0.excerpt)".lowercased().contains(q)) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 300)
            Divider()
            Group {
                if let selected {
                    let tree = byParent
                    DocPane(docId: selected, onSaved: { doc in
                        if let i = pages?.firstIndex(where: { $0.id == doc.id }) {
                            pages?[i].title = doc.title
                            pages?[i].tags = doc.tags
                            pages?[i].updatedAt = doc.updatedAt
                        }
                    }, onDeleted: {
                        self.selected = nil
                        Task { await load() }
                    }, header: { doc in
                        PageHeader(doc: doc, pages: pages ?? [], children: tree[doc.id] ?? []) { self.selected = $0 }
                    }, actions: { doc in
                        Button { create(parent: doc.id) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("添加子页面")
                        Button { pageDialog = PageDialog(kind: .move, doc: doc) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("移动到…")
                        if model.isReady(.confluence) {
                            Button { pageDialog = PageDialog(kind: .publish, doc: doc) } label: { Image(systemName: "paperplane") }.buttonStyle(.borderless).help("发布到 Wiki")
                        }
                    }, footer: { _ in EmptyView() })
                    .id(selected)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "book").font(.largeTitle)
                        Text("选择左侧的页面，或新建一个")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await load() }
        .onWorkspaceChange { Task { await load() } }
        .onChange(of: model.current.nonce, initial: true) {
            if active, model.current.page == .kb, let id = model.current.docId { selected = id }
        }
        .onChange(of: expanded) { AppPreferences.shared.set(Array(expanded), forKey: Self.expandedKey) }
        .onChange(of: selected) { expandAncestors() }
        .onChange(of: pages) { expandAncestors() }
        .sheet(item: $importKind) { kind in
            ImportSheet(kind: kind, parentId: selected.flatMap { id in pages?.contains { $0.id == id } == true ? id : nil }) { doc in
                Task {
                    await load()
                    selected = doc.id
                }
            }
        }
        .sheet(item: $pageDialog) { d in
            switch d.kind {
            case .move: MoveSheet(doc: d.doc, pages: pages ?? []) { Task { await load() } }
            case .publish: PublishSheet(doc: d.doc)
            }
        }
    }

    private func load() async {
        do {
            pages = try await API.shared.wsDocs("page")
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// 选中的页面所在的上级都展开。
    private func expandAncestors() {
        guard let selected, let pages else { return }
        var cursor = pages.first { $0.id == selected }?.parentId
        var chain: [String] = []
        while let c = cursor, !chain.contains(c) {
            chain.append(c)
            cursor = pages.first { $0.id == c }?.parentId
        }
        if !chain.allSatisfy(expanded.contains) { expanded.formUnion(chain) }
    }

    private func create(parent: String?) {
        Task {
            do {
                let doc = try await API.shared.wsSaveDoc(DocInput(kind: "page", title: "", content: "", parentId: parent))
                Events.workspaceChanged()
                if let parent { expanded.insert(parent) }
                await load()
                selected = doc.id
            } catch {
                self.error = errorMessage(error)
            }
        }
    }

    /// 某个页面的所有下级页面 id。
    private func descendants(_ id: String, _ tree: [String: [DocSummary]]) -> [String] {
        (tree[id] ?? []).flatMap { [$0.id] + descendants($0.id, tree) }
    }

    private func openDialog(_ kind: PageDialog.Kind, _ id: String) {
        guarded {
            if let doc = try await API.shared.wsDoc(id) { pageDialog = PageDialog(kind: kind, doc: doc) }
        }
    }

    private func pageMenu(_ page: DocSummary) -> [MenuSpec] {
        let tree = byParent
        let below = descendants(page.id, tree)
        let allOpen = !below.isEmpty && ([page.id] + below.filter { !(tree[$0] ?? []).isEmpty }).allSatisfy(expanded.contains)
        var specs: [MenuSpec] = [
            .action("打开") { selected = page.id },
            .action("添加子页面", icon: "plus") { create(parent: page.id) },
        ]
        if !below.isEmpty {
            specs.append(.action(allOpen ? "收起全部子页面" : "展开全部子页面", icon: allOpen ? "chevron.up.chevron.down" : "chevron.down") {
                if allOpen { expanded.subtract([page.id] + below) } else { expanded.formUnion([page.id] + below) }
            })
        }
        specs += [.separator, .action("移动到…", icon: "folder") { openDialog(.move, page.id) }]
        if model.isReady(.confluence) { specs.append(.action("发布到 Wiki…", icon: "paperplane") { openDialog(.publish, page.id) }) }
        if page.sourceSystem == "jira", let key = page.sourceKey { specs.append(.action("打开来源问题 \(key)", icon: "smallcircle.filled.circle") { model.navigate(NavTarget(.jira, issueKey: key)) }) }
        if page.sourceSystem == "wiki", let key = page.sourceKey { specs.append(.action("打开 Wiki 原页面", icon: "arrow.up.forward.square") { model.navigate(NavTarget(.wiki, wikiPage: key)) }) }
        specs += [
            DocMenus.copyTitle(page.title),
            .separator,
            DocMenus.delete(page.id, label: below.isEmpty ? "删除" : "删除（含子页面）") { if let s = selected, ([page.id] + below).contains(s) { selected = nil } },
        ]
        return specs
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("", text: $filter, prompt: Text("筛选页面")).textFieldStyle(.roundedBorder)
                Button { create(parent: nil) } label: { Image(systemName: "plus") }.help("新建页面")
            }
            HStack {
                Button("从 Jira 沉淀", systemImage: "smallcircle.filled.circle") { importKind = .jira }
                Button("剪藏 Wiki", systemImage: "square.and.arrow.down") { importKind = .wiki }
            }
            .controlSize(.small)
            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Image(systemName: "tag").font(.caption).foregroundStyle(.secondary)
                        ForEach(allTags, id: \.self) { t in
                            Button(t) { tag = tag == t ? nil : t }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(tag == t ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
            if let error { ErrorBox(message: error) { Task { await load() } } }
            List(selection: Binding(get: { selected }, set: { if let v = $0 { selected = v } })) {
                if filtering {
                    ForEach(matches) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title.isEmpty ? "无标题" : p.title).lineLimit(1)
                            if !p.excerpt.isEmpty { Text(p.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        .tag(p.id)
                        .contextMenu(specs: { pageMenu(p) })
                    }
                    if matches.isEmpty { Text("没有匹配的页面").foregroundStyle(.secondary) }
                } else {
                    let tree = byParent
                    ForEach(rows(tree), id: \.page.id) { row in
                        treeRow(row.page, depth: row.depth, hasChildren: !(tree[row.page.id] ?? []).isEmpty)
                            .tag(row.page.id)
                            .contextMenu(specs: { pageMenu(row.page) })
                    }
                    if pages?.isEmpty == true {
                        Text("知识库还是空的。可以新建页面，或把解决过的 Jira 问题、常看的 Wiki 页面沉淀进来。").foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .padding([.horizontal, .top], 12)
    }

    /// 展开后的树（扁平的行）。
    private func rows(_ tree: [String: [DocSummary]]) -> [(page: DocSummary, depth: Int)] {
        var out: [(DocSummary, Int)] = []
        func walk(_ parent: String, _ depth: Int) {
            for p in tree[parent] ?? [] {
                out.append((p, depth))
                if expanded.contains(p.id) { walk(p.id, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }

    private func treeRow(_ page: DocSummary, depth: Int, hasChildren: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                if expanded.contains(page.id) { expanded.remove(page.id) } else { expanded.insert(page.id) }
            } label: {
                Image(systemName: expanded.contains(page.id) ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 14)
            }
            .buttonStyle(.plain)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)
            Text(page.title.isEmpty ? "无标题" : page.title).lineLimit(1)
            if page.sourceSystem == "jira" { Image(systemName: "smallcircle.filled.circle").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }
}

/// 页面 id：地址中的 pageId= 或 /pages/<id>。
func wikiPageIdOf(_ url: String?) -> String? {
    guard let url else { return nil }
    if let m = url.firstMatch(of: /[?&]pageId=(\d+)/) { return String(m.1) }
    if let m = url.firstMatch(of: /\/pages\/(\d+)/) { return String(m.1) }
    return nil
}

/// 面包屑、来源、子页面。
private struct PageHeader: View {
    var doc: Doc
    var pages: [DocSummary]
    var children: [DocSummary]
    var onSelect: (String) -> Void
    @Environment(AppModel.self) private var model

    private var chain: [DocSummary] {
        var out: [DocSummary] = []
        var cursor = doc.parentId
        while let c = cursor, let p = pages.first(where: { $0.id == c }), !out.contains(where: { $0.id == c }) {
            out.insert(p, at: 0)
            cursor = p.parentId
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chain.isEmpty {
                HStack(spacing: 4) {
                    ForEach(chain) { p in
                        Button(p.title.isEmpty ? "无标题" : p.title) { onSelect(p.id) }.buttonStyle(.link)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let source = doc.sourceSystem {
                HStack(spacing: 4) {
                    Image(systemName: source == "jira" ? "smallcircle.filled.circle" : "square.and.arrow.down")
                    Text("来源：")
                    if source == "jira", let key = doc.sourceKey {
                        Button(key) { model.navigate(NavTarget(.jira, issueKey: key)) }.buttonStyle(.link)
                    } else if let key = doc.sourceKey {
                        Button("Wiki 原页面\(KBImport.wikiVersion(doc.sourceUrl).map { "（第 \($0) 版）" } ?? "")") { model.navigate(NavTarget(.wiki, wikiPage: key)) }.buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if doc.sourceSystem == "wiki", doc.sourceKey != nil { ClipStatus(doc: doc) }
            if let url = doc.publishedUrl, let id = wikiPageIdOf(url) {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane")
                    Text("已发布到")
                    Button("Wiki 页面\(KBImport.wikiVersion(url).map { "（发布时为第 \($0) 版）" } ?? "")") { model.navigate(NavTarget(.wiki, wikiPage: id)) }.buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !children.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(children) { c in
                        Button { onSelect(c.id) } label: { Label(c.title.isEmpty ? "无标题" : c.title, systemImage: "book") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// 剪藏的 Wiki 页面之后有更新时提示：查看变化、重新剪藏。
private struct ClipStatus: View {
    var doc: Doc
    @State private var latest: WikiPageVersionInfo?
    @State private var showDiff = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let clipped = KBImport.wikiVersion(doc.sourceUrl)
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let clipped, let latest, latest.version > clipped {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Wiki 原页面已更新到第 \(latest.version) 版（\(latest.by)，\(Fmt.time(latest.when))），这里剪藏的是第 \(clipped) 版。")
                        Spacer()
                        Button("查看变化") { showDiff = true }
                        Button(busy ? "剪藏中…" : "重新剪藏", action: reclip).disabled(busy)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                }
                .font(.callout)
                .padding(10)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .sheet(isPresented: $showDiff) {
                    VStack(alignment: .leading) {
                        Text("原页面的变化（第 \(clipped) 版 → 第 \(latest.version) 版）").font(.headline)
                        ScrollView { VersionDiff(pageId: doc.sourceKey ?? "", from: clipped, to: latest.version) }
                        HStack { Spacer(); Button("关闭") { showDiff = false }.keyboardShortcut(.cancelAction) }
                    }
                    .padding(20)
                    .frame(width: 820, height: 600)
                }
            }
        }
        .task(id: doc.sourceKey) {
            guard clipped != nil, let key = doc.sourceKey else { return }
            latest = try? await API.shared.wikiPageVersion(key)
        }
    }

    private func reclip() {
        guard Confirm.ask("用 Wiki 原页面的最新内容替换这篇知识库页面的正文？你在这里做过的修改会被替换掉（可以先复制保留）。", confirm: "用最新内容替换") else { return }
        busy = true
        error = nil
        Task {
            do {
                _ = try await KBImport.reclip(doc)
                latest = nil
            } catch {
                self.error = errorMessage(error)
            }
            busy = false
        }
    }
}

private struct MoveSheet: View {
    var doc: Doc
    var pages: [DocSummary]
    var onMoved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target: DocSummary?
    @State private var error: String?

    /// 不能移到自己或自己的下级。
    private var blocked: Set<String> {
        var set: Set<String> = [doc.id]
        var grew = true
        while grew {
            grew = false
            for p in pages where p.parentId.map(set.contains) == true && !set.contains(p.id) {
                set.insert(p.id)
                grew = true
            }
        }
        return set
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("移动“\(doc.title.isEmpty ? "无标题" : doc.title)”").font(.title3.weight(.semibold))
            Text("移到哪个页面下").font(.callout)
            let blocked = self.blocked
            SearchPicker(selected: target.map { [$0] } ?? [], onChange: { target = $0.first }, search: { q in
                pages.filter { !blocked.contains($0.id) && ($0.title.isEmpty ? "无标题" : $0.title).lowercased().contains(q.trimmingCharacters(in: .whitespaces).lowercased()) }
            }, label: { $0.title.isEmpty ? "无标题" : $0.title }, placeholder: "搜索页面", searchOnFocus: true)
            if let error { ErrorBox(message: error) }
            HStack {
                Button("移到顶层") { move(nil) }.disabled(doc.parentId == nil)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("移动") { if let target { move(target.id) } }.keyboardShortcut(.defaultAction).disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func move(_ parent: String?) {
        Task {
            do {
                let siblings = pages.filter { $0.parentId == parent && $0.id != doc.id }
                _ = try await API.shared.wsMoveDoc(doc.id, parentId: parent, sort: (siblings.map(\.sort).max() ?? 0) + 1)
                Events.workspaceChanged()
                onMoved()
                dismiss()
            } catch {
                self.error = errorMessage(error)
            }
        }
    }
}

private struct WikiChoice: Hashable {
    var id: String
    var title: String
    var space = ""
}

/// 发布到 Wiki：已发布过时默认更新原页面，也可以另外新建。
private struct PublishSheet: View {
    var doc: Doc
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var mode = "create"
    @State private var parent: WikiChoice?
    @State private var title = ""
    @State private var publishing = false
    @State private var published: PublishResult?
    @State private var error: String?
    /// 页面在上次发布之后被别人改过
    @State private var conflict: WikiPageVersionInfo?

    private var publishedId: String? { wikiPageIdOf(doc.publishedUrl) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发布到 Wiki").font(.title3.weight(.semibold))
            if let published {
                Label("\(published.updated ? "已更新 Wiki 页面" : "已发布为 Wiki 新页面")，正文中的图片已作为附件上传。", systemImage: "checkmark.circle").foregroundStyle(.green)
                HStack {
                    Spacer()
                    Button("打开页面") {
                        if let id = wikiPageIdOf(published.url) { model.navigate(NavTarget(.wiki, wikiPage: id)) }
                        dismiss()
                    }
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                if publishedId != nil {
                    Picker("", selection: $mode) {
                        Text("更新已发布的页面").tag("update")
                        Text("另外新建页面").tag("create")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if mode == "update" {
                    Text("用这篇知识库页面的当前内容更新上次发布的 Wiki 页面（其他人可见）。").font(.callout).foregroundStyle(.secondary)
                    if let conflict {
                        Text("这个 Wiki 页面在你上次发布后被修改过（现在是第 \(conflict.version) 版，最后由 \(conflict.by) 修改）。更新会覆盖这些修改；建议先到 Wiki 中查看历史版本。")
                            .padding(8)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Text("会在所选页面下新建一个子页面（其他人可见），不会修改已有页面。工作空间内部的文档链接发布后只保留文字。").font(.callout).foregroundStyle(.secondary)
                }
                TextField("页面标题", text: $title)
                if mode == "create" {
                    Text("上级页面").font(.callout)
                    SearchPicker(selected: parent.map { [$0] } ?? [], onChange: { parent = $0.first }, search: { q in
                        let text = q.trimmingCharacters(in: .whitespaces)
                        if text.isEmpty { return [] }
                        // 直接粘贴页面地址
                        if text.hasPrefix("http://") || text.hasPrefix("https://") || text.allSatisfy(\.isNumber) { return [WikiChoice(id: text, title: text)] }
                        return try await API.shared.wikiSearch(WikiQuery(text: text, limit: 20)).hits.map { WikiChoice(id: $0.id, title: $0.title, space: $0.spaceName) }
                    }, label: \.title, detail: \.space, placeholder: "搜索 Wiki 页面，或粘贴页面地址")
                }
                if let error { ErrorBox(message: error) }
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    if mode == "update" && conflict != nil {
                        Button(publishing ? "发布中…" : "仍然覆盖", role: .destructive) { publish(overwrite: true) }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || publishing)
                    } else {
                        Button(publishing ? "发布中…" : mode == "update" ? "更新页面" : "发布") { publish(overwrite: false) }
                            .keyboardShortcut(.defaultAction)
                            .disabled((mode == "create" && parent == nil) || title.trimmingCharacters(in: .whitespaces).isEmpty || publishing)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(publishing)
        .task {
            title = doc.title
            mode = publishedId != nil ? "update" : "create"
            if let id = publishedId, let v = KBImport.wikiVersion(doc.publishedUrl), let info = try? await API.shared.wikiPageVersion(id), info.version > v {
                conflict = info
            }
        }
    }

    private func publish(overwrite: Bool) {
        publishing = true
        error = nil
        Task {
            do {
                let converted = try await Rich.markdownToStorage(doc.content)
                published = try await API.shared.wsPublishToWiki(docId: doc.id, mode: mode == "create" ? "create" : overwrite ? "overwrite" : "update", parent: parent?.id ?? "", title: title.trimmingCharacters(in: .whitespaces), storage: converted.storage, assets: converted.assets)
                Events.workspaceChanged()
            } catch {
                self.error = errorMessage(error)
            }
            publishing = false
        }
    }
}

private struct KBIssueChoice: Hashable {
    var key: String
    var summary: String
}

/// 从 Jira 问题沉淀、剪藏 Wiki 页面。
private struct ImportSheet: View {
    var kind: KnowledgePage.ImportKind
    var parentId: String?
    var onImported: (Doc) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var issue: KBIssueChoice?
    @State private var page: WikiChoice?
    @State private var under = true
    @State private var busy = false
    @State private var error: String?

    private var ready: Bool { model.isReady(kind == .jira ? .jira : .confluence) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .jira ? "从 Jira 问题沉淀" : "剪藏 Wiki 页面").font(.title3.weight(.semibold))
            if !ready { ErrorBox(message: "尚未配置 \(kind == .jira ? "Jira" : "Wiki")") }
            Text(kind == .jira ? "把问题的描述、解决方案等字段和讨论记录整理成一篇知识库页面，并保留与问题的关联。" : "把 Wiki 页面的当前内容保存为知识库页面（之后与原页面独立），可离线查看和修改。")
                .font(.callout).foregroundStyle(.secondary)
            if kind == .jira {
                Text("问题").font(.callout)
                SearchPicker(selected: issue.map { [$0] } ?? [], onChange: { issue = $0.first }, search: { q in
                    q.trimmingCharacters(in: .whitespaces).isEmpty ? [] : try await API.shared.jiraPickIssues(q, projectKey: nil, standardOnly: false).map { KBIssueChoice(key: $0.key, summary: $0.summary) }
                }, label: { "\($0.key) \($0.summary)" }, placeholder: "输入问题键或概要搜索")
            } else {
                Text("Wiki 页面").font(.callout)
                SearchPicker(selected: page.map { [$0] } ?? [], onChange: { page = $0.first }, search: { q in
                    let text = q.trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { return [] }
                    if text.hasPrefix("http://") || text.hasPrefix("https://") || text.allSatisfy(\.isNumber) { return [WikiChoice(id: text, title: text)] }
                    return try await API.shared.globalSearch(text).pages.map { WikiChoice(id: $0.id, title: $0.title, space: $0.space) }
                }, label: \.title, detail: \.space, placeholder: "搜索 Wiki 页面，或粘贴页面地址")
            }
            if parentId != nil { Toggle("放在当前选中的页面下", isOn: $under).toggleStyle(.checkbox) }
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "处理中…" : kind == .jira ? "沉淀为页面" : "剪藏", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !ready || (kind == .jira ? issue == nil : page == nil))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func run() {
        busy = true
        error = nil
        Task {
            do {
                let parent = under ? parentId : nil
                let doc = kind == .jira ? try await KBImport.issueToPage(issue!.key, parentId: parent) : try await KBImport.wikiToPage(page!.id, parentId: parent)
                onImported(doc)
                dismiss()
            } catch {
                self.error = errorMessage(error)
                busy = false
            }
        }
    }
}
