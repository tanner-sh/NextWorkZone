import SwiftUI

/// 项目：代码、合并请求、提交、分支、对比。
/// `initialRef`：打开时显示的分支（可以是 tree/ 之后的路径，取其中最长的已有分支名）；`initialCommit`：打开时显示的提交。
struct ProjectView: View {
    var projectId: Int
    var initialRef: String?
    var initialCommit: String?

    enum Tab: String { case code, mrs, commits, branches, compare }

    @State private var project: Project?
    @State private var branches: [Branch] = []
    @State private var ref = ""
    @State private var tab: Tab = .code
    /// 提交标签中打开的提交
    @State private var openCommit: String?
    @State private var openMr: Int?
    /// 新建合并请求对话框（值为预选的源分支）
    @State private var creating: NewMrRequest?
    @State private var path = ""
    @State private var isFile = false
    @State private var error: String?

    struct NewMrRequest: Identifiable {
        var source: String?
        var id: String { source ?? "" }
    }

    var body: some View {
        Group {
            if let error {
                VStack { ErrorBox(message: error) }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else if let project {
                if ref.isEmpty {
                    Text("这是一个空仓库。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content(project).pageToolbar { toolbar(project) }
                }
            } else {
                LoadingView()
            }
        }
        .task(id: projectId) { await load() }
        .sheet(item: $creating) { req in
            if let project {
                NewMergeRequestSheet(project: project, branches: branches, initialSource: req.source) { mr in
                    tab = .mrs
                    openMr = mr.iid
                }
            }
        }
    }

    private func load() async {
        do {
            async let p = API.shared.glProject(projectId)
            async let b = API.shared.glBranches(projectId)
            let (proj, list) = try await (p, b)
            project = proj
            branches = list
            if initialRef != nil || initialCommit != nil { tab = .commits }
            openCommit = initialCommit
            var wanted: Branch?
            if let r = initialRef {
                wanted = list.filter { r == $0.name || r.hasPrefix("\($0.name)/") }.max { $0.name.count < $1.name.count }
                if wanted == nil { toast("分支 \(r) 已不存在", error: true) }
            }
            ref = wanted?.name ?? proj.defaultBranch ?? list.first?.name ?? ""
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
    }

    private func openBranch(_ name: String) {
        ref = name
        path = ""
        isFile = false
        tab = .code
    }

    /// 项目的操作放在窗口工具栏右侧：分支（代码、提交）、新建合并请求、在浏览器中打开；打开了合并请求时由它提供。
    @ToolbarContentBuilder
    private func toolbar(_ project: Project) -> some ToolbarContent {
        if !(tab == .mrs && openMr != nil) {
            if tab == .code || tab == .commits {
                ToolbarItem {
                    // 工具栏中的菜单样式 Picker 不显示当前值，改用显示分支名的菜单
                    Menu {
                        ForEach(branches) { b in
                            Toggle(b.name, isOn: Binding(get: { b.name == ref }, set: { if $0 { openBranch(b.name) } }))
                        }
                    } label: {
                        Label(ref, systemImage: "arrow.triangle.branch")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("切换分支")
                }
            }
            ToolbarItemGroup {
                Button("新建合并请求", systemImage: "plus") { creating = NewMrRequest(source: ref != project.defaultBranch ? ref : nil) }.help("新建合并请求")
                Button("在浏览器中打开", systemImage: "safari") { Links.openInBrowser(project.webUrl) }.help("在浏览器中打开")
            }
        }
    }

    @ViewBuilder
    private func content(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Button(project.pathWithNamespace) { Links.openInBrowser(project.webUrl) }.buttonStyle(.link).font(.callout).help("在浏览器中打开")
                Text(project.name).font(.title2.weight(.semibold))
                if let d = project.description, !d.isEmpty { Text(d).foregroundStyle(.secondary) }
            }
            HStack {
                Picker("", selection: Binding(get: { tab }, set: { t in
                    tab = t
                    if t == .mrs { openMr = nil }
                    if t == .commits { openCommit = nil }
                })) {
                    Label("代码", systemImage: "chevron.left.forwardslash.chevron.right").tag(Tab.code)
                    Label("合并请求", systemImage: "arrow.triangle.pull").tag(Tab.mrs)
                    Label("提交", systemImage: "smallcircle.filled.circle").tag(Tab.commits)
                    Label("分支 \(branches.count)", systemImage: "arrow.triangle.branch").tag(Tab.branches)
                    Label("对比", systemImage: "arrow.left.arrow.right").tag(Tab.compare)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch tab {
            case .code:
                CodeTab(projectId: projectId, projectUrl: project.webUrl, ref: ref, path: $path, isFile: $isFile)
            case .mrs:
                if let iid = openMr {
                    MergeRequestView(project: String(projectId), iid: iid, onBack: { openMr = nil }).id(iid)
                } else {
                    ProjectMrsTab(projectId: projectId) { openMr = $0 }
                }
            case .commits:
                if let sha = openCommit {
                    CommitDetailView(projectId: projectId, projectPath: project.pathWithNamespace, sha: sha) { openCommit = nil }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if ref != project.defaultBranch { RelatedIssuesSection(target: CodeTarget(projectPath: project.pathWithNamespace, branch: ref, text: ref)) }
                            CommitsTab(projectId: projectId, ref: ref) { openCommit = $0 }
                        }
                    }
                }
            case .branches:
                BranchesTab(branches: branches, projectUrl: project.webUrl, onOpen: openBranch) { creating = NewMrRequest(source: $0) }
            case .compare:
                CompareTab(projectId: projectId, branches: branches, defaultBranch: project.defaultBranch ?? "")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

/// 代码浏览：`path` 为目录时列出内容，为文件时显示文件。
private struct CodeTab: View {
    var projectId: Int
    var projectUrl: String
    var ref: String
    @Binding var path: String
    @Binding var isFile: Bool
    @State private var entries: [TreeEntry]?
    @State private var file: FileContent?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 面包屑
            HStack(spacing: 4) {
                Button(ref) { go("", false) }.buttonStyle(.link)
                let parts = path.isEmpty ? [] : path.components(separatedBy: "/")
                ForEach(parts.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    if i == parts.count - 1 {
                        Text(parts[i]).fontWeight(.semibold)
                    } else {
                        Button(parts[i]) { go(parts[...i].joined(separator: "/"), false) }.buttonStyle(.link)
                    }
                }
            }
            .font(.callout)
            if let error { ErrorBox(message: error) }
            if isFile {
                if let file {
                    FileBody(file: file)
                } else if error == nil {
                    LoadingView()
                }
            } else if let entries {
                List {
                    if !path.isEmpty {
                        Label("..", systemImage: "arrow.turn.left.up").rowTap { go(path.components(separatedBy: "/").dropLast().joined(separator: "/"), false) }
                    }
                    ForEach(entries) { e in
                        Label {
                            Text(e.name).fontWeight(e.kind == "tree" ? .medium : .regular)
                        } icon: {
                            Image(systemName: e.kind == "tree" ? "folder.fill" : e.kind == "commit" ? "shippingbox" : "doc.text").foregroundStyle(e.kind == "tree" ? Color.accentColor : .secondary)
                        }
                        .rowTap { if e.kind != "commit" { go(e.path, e.kind == "blob") } }
                        .contextMenu(specs: { GitLab.treeEntryMenu(e, projectUrl: projectUrl, ref: ref) { go(e.path, e.kind == "blob") } })
                    }
                    if entries.isEmpty { Text("空目录").foregroundStyle(.secondary) }
                }
                .listStyle(.inset)
            } else if error == nil {
                LoadingView()
            }
        }
        .task(id: "\(ref)|\(path)|\(isFile)") {
            error = nil
            entries = nil
            file = nil
            do {
                if isFile { file = try await API.shared.glFile(projectId, ref: ref, path: path) } else { entries = try await API.shared.glTree(projectId, ref: ref, path: path) }
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
            }
        }
    }

    private func go(_ target: String, _ file: Bool) {
        path = target
        isFile = file
    }
}

private struct FileBody: View {
    var file: FileContent

    var body: some View {
        if file.tooLarge {
            Text("文件过大（\(Fmt.size(file.size))），请在浏览器中查看。").foregroundStyle(.secondary)
        } else if let url = file.imageDataUrl, let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])), let image = NSImage(data: data) {
            ScrollView { Image(nsImage: image) }
        } else if file.binary || file.text == nil {
            Text("二进制文件（\(Fmt.size(file.size))），无法预览。").foregroundStyle(.secondary)
        } else {
            CodeView(code: file.text ?? "", path: file.path)
                .groupBackground(radius: Theme.controlRadius)
        }
    }
}

private struct CommitsTab: View {
    var projectId: Int
    var ref: String
    var onOpen: (String) -> Void
    @State private var commits: [Commit] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { ErrorBox(message: error) }
            CommitListView(commits: commits, onOpen: onOpen)
            if hasMore && !commits.isEmpty {
                Button(loading ? "加载中…" : "加载更多") { Task { await load(page + 1) } }.disabled(loading)
            }
            if loading && commits.isEmpty { ProgressView() }
        }
        .task(id: ref) { await load(1) }
    }

    private func load(_ p: Int) async {
        loading = true
        error = nil
        do {
            let list = try await API.shared.glCommits(projectId, ref: ref, path: nil, page: p)
            commits = p == 1 ? list : commits + list
            hasMore = list.count == 50
            page = p
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
        loading = false
    }
}

/// 提交详情；`projectPath` 有值时显示提到这个提交的问题。
struct CommitDetailView: View {
    var projectId: Int
    var projectPath: String?
    var sha: String
    var onBack: () -> Void
    @State private var detail: CommitDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button("返回", systemImage: "chevron.left", action: onBack)
                if let error { ErrorBox(message: error) }
                if let d = detail {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.commit.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        HStack(spacing: 4) {
                            Text("\(d.commit.authorName) · \(Fmt.time(d.commit.authoredDate)) ·")
                            Text(d.commit.shortId).font(.caption.monospaced())
                            if let url = d.commit.webUrl { Button("在浏览器中打开") { Links.openInBrowser(url) }.buttonStyle(.link) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if d.commit.message.trimmingCharacters(in: .whitespacesAndNewlines) != d.commit.title.trimmingCharacters(in: .whitespacesAndNewlines) {
                            Text(d.commit.message.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).groupBackground(radius: Theme.controlRadius)
                        }
                    }
                    if let projectPath { RelatedIssuesSection(target: CodeTarget(projectPath: projectPath, sha: d.commit.id, text: d.commit.message.isEmpty ? d.commit.title : d.commit.message)) }
                    DiffListView(diffs: d.diffs)
                } else if error == nil {
                    ProgressView()
                }
            }
            .padding(.vertical, 8)
        }
        .task(id: sha) {
            do { detail = try await API.shared.glCommit(projectId, sha: sha) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
        }
    }
}

private struct ProjectMrsTab: View {
    var projectId: Int
    var onOpen: (Int) -> Void
    @State private var state = "opened"
    @State private var input = ""
    @State private var search = ""
    @State private var list = MrListModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $state) { ForEach(mrStates, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
                FilterField(prompt: "搜索标题、描述，回车", text: $input) { search = input.trimmingCharacters(in: .whitespaces) }
            }
            MrListBody(list: list, selected: nil, showProject: false, empty: "没有符合条件的合并请求") { onOpen($0.iid) } loadMore: {
                Task { await list.loadMore(.project(String(projectId)), state: state, search: search) }
            }
        }
        .task(id: "\(state)|\(search)") { await list.load(.project(String(projectId)), state: state, search: search) }
    }
}

private struct BranchesTab: View {
    var branches: [Branch]
    var projectUrl: String
    var onOpen: (String) -> Void
    var onCreateMr: (String) -> Void
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("筛选分支", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            List {
                ForEach(branches.filter { filter.isEmpty || $0.name.lowercased().contains(filter.lowercased()) }) { b in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(b.name).fontWeight(.medium)
                                if b.default { Chip(text: "默认", tint: .accentColor) }
                                if b.protected { Chip(text: "保护") }
                                if b.merged { Chip(text: "已合并") }
                            }
                            Text("\(b.commit.title) · \(b.commit.authorName) · \(Fmt.time(b.commit.authoredDate))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !b.default && !b.merged {
                            Button("发起合并请求", systemImage: "arrow.triangle.pull") { onCreateMr(b.name) }.controlSize(.small).help("以这个分支发起合并请求")
                        }
                    }
                    .rowTap { onOpen(b.name) }
                    .contextMenu(specs: { GitLab.branchMenu(b, projectUrl: projectUrl, onOpen: { onOpen(b.name) }, onCreateMr: !b.default && !b.merged ? { @MainActor in onCreateMr(b.name) } : nil) })
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct CompareTab: View {
    var projectId: Int
    var branches: [Branch]
    var defaultBranch: String
    @State private var from = ""
    @State private var to = ""
    @State private var result: Comparison?
    @State private var loading = false
    @State private var error: String?
    @State private var selected: String?

    var body: some View {
        if let sha = selected {
            CommitDetailView(projectId: projectId, sha: sha) { selected = nil }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("", selection: $from) { ForEach(branches) { Text($0.name).tag($0.name) } }.labelsHidden().fixedSize()
                        Text("…").foregroundStyle(.secondary)
                        Picker("", selection: $to) { ForEach(branches) { Text($0.name).tag($0.name) } }.labelsHidden().fixedSize()
                        Button(loading ? "对比中…" : "对比", action: compare).buttonStyle(.borderedProminent).disabled(loading || from == to)
                    }
                    Text("显示从「\(from)」到「\(to)」新增的提交与改动。").font(.caption).foregroundStyle(.secondary)
                    if let error { ErrorBox(message: error) }
                    if let result {
                        Text("提交 (\(result.commits.count))").font(.headline)
                        if result.commits.isEmpty { Text("没有差异。").foregroundStyle(.secondary) } else { CommitListView(commits: result.commits) { selected = $0 } }
                        if !result.diffs.isEmpty {
                            Text("改动文件 (\(result.diffs.count))").font(.headline)
                            DiffListView(diffs: result.diffs)
                        }
                    }
                }
            }
            .onAppear {
                if from.isEmpty { from = defaultBranch }
                if to.isEmpty { to = branches.first { $0.name != defaultBranch }?.name ?? defaultBranch }
            }
        }
    }

    private func compare() {
        loading = true
        error = nil
        result = nil
        Task {
            do { result = try await API.shared.glCompare(projectId, from: from, to: to) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            loading = false
        }
    }
}
