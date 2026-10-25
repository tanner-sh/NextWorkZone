import SwiftUI

// 问题详情中的各个区块。

/// 一行问题：图标、问题键、概要、状态；点击在应用内打开，右键为问题菜单。
struct IssueRefRow<Actions: View>: View {
    var key: String
    var summary: String
    var status: JiraStatus?
    var icon: String?
    var prefix: String? = nil
    var menu: IssueMenu
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            if let prefix { Text(prefix).foregroundStyle(.secondary).lineLimit(1) }
            SysImage(service: .jira, src: icon, size: 16)
            Button(key) { AppModel.shared.navigate(NavTarget(.jira, issueKey: key)) }.buttonStyle(.link)
            Text(summary).lineLimit(1)
            Spacer(minLength: 4)
            if let status { StatusPill(status: status) }
            actions()
        }
        .contentShape(Rectangle())
        .contextMenu(specs: { menu.specs(.key(key, summary: summary)) })
    }
}

extension IssueRefRow where Actions == EmptyView {
    init(key: String, summary: String, status: JiraStatus?, icon: String?, prefix: String? = nil, menu: IssueMenu) {
        self.init(key: key, summary: summary, status: status, icon: icon, prefix: prefix, menu: menu, actions: { EmptyView() })
    }
}

struct SubtasksSection: View {
    var issue: IssueDetail
    var menu: IssueMenu
    var onCreate: () -> Void

    var body: some View {
        // 子任务下不能再建子任务
        if !(issue.parent != nil && issue.subtasks.isEmpty) {
            let done = issue.subtasks.filter { $0.status?.category == "done" }.count
            BlockSection(title: "子任务", icon: "arrow.triangle.branch", count: issue.subtasks.isEmpty ? nil : "\(done)/\(issue.subtasks.count)") {
                if issue.parent == nil { Button("新建子任务", systemImage: "plus", action: onCreate) }
            } content: {
                if issue.subtasks.isEmpty {
                    Text("暂无子任务").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(issue.subtasks) { s in IssueRefRow(key: s.key, summary: s.summary, status: s.status, icon: s.issueType?.iconUrl, menu: menu) }
                    }
                }
            }
        }
    }
}

struct LinksSection: View {
    var issue: IssueDetail
    var menu: IssueMenu
    var onChanged: (IssueDetail) -> Void
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        BlockSection(title: "关联问题", icon: "link", count: issue.links.isEmpty ? nil : "\(issue.links.count)") {
            if !adding { Button("添加链接", systemImage: "plus") { adding = true } }
        } content: {
            if adding {
                LinkForm(issueKey: issue.key) { adding = false } onDone: { d in
                    adding = false
                    onChanged(d)
                }
            }
            if let error { ErrorBox(message: error) }
            if issue.links.isEmpty {
                if !adding { Text("暂无关联问题").font(.callout).foregroundStyle(.secondary) }
            } else {
                VStack(spacing: 6) {
                    ForEach(issue.links) { l in
                        IssueRefRow(key: l.key, summary: l.summary, status: l.status, icon: l.issueType?.iconUrl, prefix: l.relation, menu: menu) {
                            Button {
                                guard Confirm.ask("删除与 \(l.key) 的链接？") else { return }
                                Task {
                                    do { onChanged(try await API.shared.jiraDeleteLink(issue.key, linkId: l.id)) } catch { self.error = errorMessage(error) }
                                }
                            } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("删除链接")
                        }
                    }
                }
            }
        }
    }
}

/// 链接关系：每种链接类型按方向拆成两种可选的关系。
private struct Relation: Hashable {
    var id: String
    var typeId: String
    var outward: Bool
    var label: String
    var typeName: String
}

private struct LinkForm: View {
    var issueKey: String
    var onCancel: () -> Void
    var onDone: (IssueDetail) -> Void
    nonisolated(unsafe) private static var typesCache: [LinkType]?
    @State private var types: [LinkType]?
    @State private var relation: Relation?
    @State private var targets: [IssueChoice] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        let relations: [Relation] = (types ?? []).flatMap { t -> [Relation] in
            var both = [Relation(id: "\(t.id):out", typeId: t.id, outward: true, label: t.outward, typeName: t.name)]
            // 双向描述相同的类型（如“相关”）只列一次
            if t.inward != t.outward { both.append(Relation(id: "\(t.id):in", typeId: t.id, outward: false, label: t.inward, typeName: t.name)) }
            return both
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(issueKey) 的关系").font(.callout).foregroundStyle(.secondary)
                    SearchPicker<Relation>(selected: relation.map { [$0] } ?? [], onChange: { relation = $0.first }, search: { q in relations.filter { q.isEmpty || $0.label.lowercased().contains(q.lowercased()) } }, label: { $0.label }, detail: { $0.typeName }, placeholder: types == nil ? "正在加载链接类型…" : "搜索关系，例如“阻塞”", searchOnFocus: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("问题").font(.callout).foregroundStyle(.secondary)
                    SearchPicker<IssueChoice>(selected: targets, onChange: { targets = $0 }, search: { q in
                        q.isEmpty ? [] : try await API.shared.jiraPickIssues(q, projectKey: nil, standardOnly: false).filter { $0.key != issueKey }.map { IssueChoice(key: $0.key, summary: $0.summary) }
                    }, label: { $0.key }, detail: { $0.summary }, placeholder: "输入问题键或概要搜索", multiple: true)
                }
            }
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button(saving ? "添加中…" : "添加链接") {
                    guard let relation else { return }
                    saving = true
                    Task {
                        do {
                            var detail: IssueDetail?
                            for t in targets { detail = try await API.shared.jiraAddLink(issueKey, typeId: relation.typeId, other: t.key, outward: relation.outward) }
                            if let detail { onDone(detail) }
                        } catch {
                            self.error = errorMessage(error)
                            saving = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(relation == nil || targets.isEmpty || saving)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .task {
            if let cached = Self.typesCache { types = cached; return }
            do {
                let list = try await API.shared.jiraLinkTypes()
                Self.typesCache = list
                types = list
            } catch { self.error = errorMessage(error) }
        }
    }
}

/// 相似问题：概要相近的其他问题，默认只看已解决的，并显示解决情况和最后的评论。
struct SimilarSection: View {
    var issue: IssueDetail
    var menu: IssueMenu
    @State private var resolvedOnly = true
    @State private var result: SimilarIssues?
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 内容为空时也要执行 task
            Color.clear.frame(width: 0, height: 0)
            if result.map({ $0.jql != nil }) ?? true {
                BlockSection(title: "相似问题", icon: "sparkles", count: result.map { $0.source == "local" ? "本机问题库" : "Jira 搜索" }) {
                    Toggle("只看已解决", isOn: $resolvedOnly).toggleStyle(.checkbox)
                    if let jql = result?.jql, !(result?.issues.isEmpty ?? true) {
                        Button("在列表中查看更多") { AppModel.shared.navigate(NavTarget(.jira, jql: jql)) }.buttonStyle(.borderless)
                    }
                } content: {
                    if let error { ErrorBox(message: error) }
                    if result == nil && error == nil { ProgressView().controlSize(.small) }
                    if let result {
                        if result.issues.isEmpty {
                            Text("没有找到相似的问题").font(.callout).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(result.issues) { hit in SimilarItem(hit: hit, menu: menu) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(issue.key)|\(issue.summary)|\(resolvedOnly)") {
            result = nil
            error = nil
            do { result = try await API.shared.jiraSimilarIssues(issue.key, summary: issue.summary, resolvedOnly: resolvedOnly) } catch { self.error = errorMessage(error) }
        }
    }
}

/// 一条相似问题：概要、经办人、状态；下面是解决结果、用时和最后的评论。
private struct SimilarItem: View {
    var hit: IssueHit
    var menu: IssueMenu
    @State private var expanded = false

    var body: some View {
        let days: Int? = hit.resolved.map { r in max(0, Int(((Double(Fmt.ms(r)) - Double(Fmt.ms(hit.created))) / 86_400_000).rounded())) }
        let facts = [hit.resolution, hit.resolved.map { "\(Fmt.time($0)) 解决" }, days.map { $0 == 0 ? "当天解决" : "用时 \($0) 天" }, hit.commentCount > 0 ? "\(hit.commentCount) 条评论" : nil].compactMap { $0 }
        let comments = expanded ? hit.lastComments : Array(hit.lastComments.suffix(1))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SysImage(service: .jira, src: hit.issueType.iconUrl, size: 16)
                Text(hit.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                Text(hit.summary).lineLimit(1).help(hit.summary)
                Spacer(minLength: 4)
                if let a = hit.assignee {
                    HStack(spacing: 3) { Avatar(name: a, size: 16); Text(a).font(.callout) }.help("经办人：\(a)")
                }
                StatusPill(status: hit.status)
            }
            .contentShape(Rectangle())
            .onTapGesture { AppModel.shared.navigate(NavTarget(.jira, issueKey: hit.key)) }
            .contextMenu(specs: { menu.specs(.summary(hit.summaryValue)) })
            if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).padding(.leading, 22) }
            ForEach(comments.indices, id: \.self) { i in
                (Text(comments[i].author).bold() + Text("：\(comments[i].body)"))
                    .font(.caption)
                    .lineLimit(expanded ? nil : 2)
                    .padding(.leading, 22)
                    .help(expanded ? "" : comments[i].body)
            }
            if hit.lastComments.count > 1 {
                Button(expanded ? "收起" : "最后 \(hit.lastComments.count) 条评论") { expanded.toggle() }.buttonStyle(.link).font(.caption).padding(.leading, 22)
            }
        }
    }
}

/// 引用了这个问题的 Wiki 页面（页面中的 Jira 宏、正文中的问题键）。
struct WikiPagesSection: View {
    var issueKey: String
    var onCount: (Int) -> Void
    @State private var pages: [WikiPageHit]?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 内容为空时也要执行 task
            Color.clear.frame(width: 0, height: 0)
            if let pages, !pages.isEmpty {
                BlockSection(title: "Wiki 页面", icon: "text.book.closed", count: "\(pages.count)") {
                    VStack(spacing: 6) {
                        ForEach(pages) { p in
                            HStack {
                                Image(systemName: "text.book.closed").foregroundStyle(.secondary)
                                Text(p.title).lineLimit(1)
                                Spacer()
                                Text("\(p.spaceName)\(p.modified.isEmpty ? "" : " · \(Fmt.time(p.modified))")").font(.caption).foregroundStyle(.secondary)
                            }
                            .rowTap { AppModel.shared.navigate(NavTarget(.wiki, wikiPage: p.id)) }
                            .contextMenu(specs: { WikiMenus.page(id: p.id, title: p.title, space: p.spaceName) })
                        }
                    }
                }
            }
        }
        .task(id: issueKey) {
            guard AppModel.shared.isReady(.confluence) else { return }
            pages = nil
            pages = (try? await API.shared.wikiIssuePages(issueKey)) ?? []
            onCount(pages?.count ?? 0)
        }
    }
}

let backlinkKindLabel = ["todo": "待办", "note": "笔记", "daily": "日记", "page": "知识库"]

/// 引用了某个条目（Jira 问题、文档）的待办和文档。
struct BacklinksSection<Actions: View>: View {
    var system: String
    var itemKey: String
    var title = "工作空间中的引用"
    var hideEmpty = false
    var onCount: ((Int) -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @State private var links: [Backlink]?

    static func target(_ l: Backlink) -> NavTarget {
        l.itemType == "todo" ? NavTarget(.todos, todoId: l.id) : NavTarget(l.kind == "page" ? .kb : .notes, docId: l.id)
    }


    var body: some View {
        ZStack(alignment: .topLeading) {
            // 内容为空时也要执行 task
            Color.clear.frame(width: 0, height: 0)
            if let links, !(hideEmpty && links.isEmpty && Actions.self == EmptyView.self) {
                BlockSection(title: title, icon: "link", count: links.isEmpty ? nil : "\(links.count)", actions: actions) {
                    if links.isEmpty {
                        Text("还没有待办或文档引用它").font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(links) { l in
                                HStack(spacing: 6) {
                                    Image(systemName: l.itemType == "todo" ? (l.done ? "checkmark.square" : "square") : l.kind == "page" ? "book" : l.kind == "daily" ? "calendar" : "note.text").foregroundStyle(.secondary)
                                    Text(backlinkKindLabel[l.kind] ?? "").font(.caption).foregroundStyle(.secondary)
                                    Text(l.title.isEmpty ? "无标题" : l.title).strikethrough(l.done).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.time(ms: l.updatedAt)).font(.caption).foregroundStyle(.secondary)
                                }
                                .rowTap { AppModel.shared.navigate(Self.target(l)) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(system)|\(itemKey)") { await load() }
        .onWorkspaceChange { Task { await load() } }
    }

    private func load() async {
        links = (try? await API.shared.wsBacklinks(system: system, key: itemKey)) ?? []
        onCount?(links?.count ?? 0)
    }
}

extension BacklinksSection where Actions == EmptyView {
    init(system: String, itemKey: String, title: String = "工作空间中的引用", hideEmpty: Bool = false) {
        self.init(system: system, itemKey: itemKey, title: title, hideEmpty: hideEmpty, onCount: nil, actions: { EmptyView() })
    }
}

/// 附件：缩略图或文件类型，点击预览，右键可用系统应用打开。
struct AttachmentsSection: View {
    var issueKey: String
    var attachments: [Attachment]
    var busy: String?
    var onPick: () -> Void

    var body: some View {
        BlockSection(title: "附件", icon: "paperclip", count: attachments.isEmpty ? nil : "\(attachments.count)") {
            Button("上传附件", systemImage: "square.and.arrow.up", action: onPick).disabled(busy != nil)
        } content: {
            if let busy { Text(busy).font(.callout).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { i, a in
                    AttachmentTile(attachment: a, service: .jira)
                        .onTapGesture { AttachmentViewer.show(attachments, index: i, service: .jira) }
                        .contextMenu(specs: { AttachmentViewer.menu(a, preview: { AttachmentViewer.show(attachments, index: i, service: .jira) }, service: .jira) })
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                Text("把文件拖进这里即可上传")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct AttachmentTile: View {
    var attachment: Attachment
    var service: Service

    var body: some View {
        let a = attachment
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
                if let thumb = a.thumbnailUrl {
                    SysImage(service: service, src: thumb)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "doc").font(.title2)
                        Text(String(((a.filename as NSString).pathExtension.isEmpty ? "file" : (a.filename as NSString).pathExtension).prefix(4)).uppercased()).font(.caption2.bold())
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(a.filename).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(Fmt.size(a.size)).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help("\(a.filename)\n\(a.author) · \(Fmt.time(a.created))\n点击预览，右键可用系统应用打开")
    }
}

// MARK: - 代码

/// 问题详情中的“代码”：描述、评论里链接的分支、提交、合并请求，以及标题含问题键的合并请求、提交说明含问题键的提交。
struct IssueCodeSection: View {
    var issue: IssueDetail
    var onCount: (Int) -> Void
    /// 线索来自某条评论时，点击跳到那条评论
    var onComment: (String) -> Void = { _ in }
    @State private var refs: [CodeRef]?

    /// 结果缓存一段时间：在问题之间来回切换时不重复请求 GitLab。
    nonisolated(unsafe) private static var cache: [String: (at: Date, refs: [CodeRef])] = [:]

    static let stateLabels = ["opened": "打开", "merged": "已合并", "closed": "已关闭", "locked": "已锁定"]
    static let pipelineLabels = [
        "success": "流水线已通过", "failed": "流水线失败", "running": "流水线运行中", "pending": "流水线等待中", "canceled": "流水线已取消", "skipped": "流水线已跳过",
        "manual": "流水线等待手动操作", "created": "流水线已创建", "scheduled": "流水线已排期", "preparing": "流水线准备中", "waiting_for_resource": "流水线等待资源",
    ]

    private var cacheKey: String { "\(issue.key)|\(issue.updated)|\(issue.comments.count)" }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 内容为空时也要执行 task
            Color.clear.frame(width: 0, height: 0)
            if let refs, !refs.isEmpty {
                BlockSection(title: "代码", icon: "chevron.left.forwardslash.chevron.right", count: "\(refs.count)") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(refs, id: \.url) { r in CodeRefItem(item: r, issueKey: issue.key, onComment: onComment) }
                    }
                }
            } else if refs == nil && AppModel.shared.isReady(.gitlab) {
                BlockSection(title: "代码", icon: "chevron.left.forwardslash.chevron.right") { ProgressView().controlSize(.small) }
            }
        }
        .task(id: cacheKey) {
            if let hit = Self.cache[cacheKey], Date().timeIntervalSince(hit.at) < 300 {
                refs = hit.refs
            } else {
                refs = nil
                var texts: [IssueText] = []
                if let d = issue.descriptionHtml { texts.append(IssueText(source: "description", author: issue.reporter, at: issue.created, html: d)) }
                for c in issue.comments { texts.append(IssueText(source: "comment", commentId: c.id, author: c.author, at: c.created, html: c.bodyHtml)) }
                let list = (try? await API.shared.issueCodeRefs(issue.key, texts: texts)) ?? []
                Self.cache[cacheKey] = (Date(), list)
                refs = list
            }
            onCount(refs?.count ?? 0)
        }
    }
}

private struct CodeRefItem: View {
    var item: CodeRef
    var issueKey: String
    var onComment: (String) -> Void
    @State private var expanded = false

    private var target: NavTarget? {
        let r = item
        guard r.unavailable == nil, r.kind != "external", let pid = r.projectId else { return nil }
        if r.kind == "mr", let iid = r.iid { return NavTarget(.gitlab, projectId: pid, mrIid: iid) }
        if r.kind == "commit", let sha = r.sha, r.state != "missing" { return NavTarget(.gitlab, projectId: pid, commitSha: sha) }
        if r.kind == "branch", let b = r.branch, r.state != "missing" { return NavTarget(.gitlab, projectId: pid, gitRef: b) }
        return nil
    }

    var body: some View {
        let r = item
        let icon = r.kind == "mr" ? "arrow.triangle.pull" : r.kind == "branch" ? "arrow.triangle.branch" : r.kind == "commit" ? "smallcircle.filled.circle" : "arrow.up.forward.square"
        let commits = expanded ? r.commits : Array(r.commits.prefix(3))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Group {
                    switch r.kind {
                    case "mr": Text("!\(r.iid ?? 0) ").foregroundStyle(.secondary) + Text(r.title.isEmpty ? (r.branch ?? "") : r.title)
                    case "commit": Text(String((r.sha ?? "").prefix(8))).font(.callout.monospaced()) + Text(" \(r.title)")
                    case "branch": Text(r.branch ?? "").font(.callout.monospaced())
                    default: Text(r.url.replacing(/^https?:\/\//, with: ""))
                    }
                }
                .lineLimit(1)
                state
                Spacer(minLength: 4)
                Text(r.kind == "external" ? "其他 GitLab" : r.projectName).font(.caption).foregroundStyle(.secondary).help(r.projectPath)
            }
            .opacity(r.unavailable != nil || r.kind == "external" ? 0.6 : 1)
            .rowTap {
                if let t = target { AppModel.shared.navigate(t) } else if r.kind == "external" || r.unavailable != nil { Links.openInBrowser(r.url) }
            }
            .contextMenu(specs: { menu })
            HStack(spacing: 4) {
                if let first = item.sources.first, first.kind == "comment", let id = first.commentId {
                    Button("来自 \(first.author ?? "某人") 的评论") { onComment(id) }.buttonStyle(.link).help("跳到这条评论")
                }
                detail
            }
            .font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            if r.kind == "branch", !commits.isEmpty, let pid = r.projectId {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(commits) { c in
                        HStack(spacing: 6) {
                            Text(c.shortId).font(.caption.monospaced())
                            Text(c.title).lineLimit(1)
                            Spacer()
                            Text("\(c.authorName) · \(Fmt.time(c.authoredDate))").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .help(c.message.isEmpty ? c.title : c.message)
                        .rowTap { AppModel.shared.navigate(NavTarget(.gitlab, projectId: pid, commitSha: c.id)) }
                    }
                    if r.commits.count > 3 {
                        Button(expanded ? "收起" : "展开全部 \(r.commits.count) 个提交") { expanded.toggle() }.buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private var state: some View {
        let r = item
        if r.kind == "mr", let s = r.state {
            if let p = r.pipeline { Circle().fill(p == "success" ? Color.green : p == "failed" ? .red : .orange).frame(width: 7, height: 7).help(IssueCodeSection.pipelineLabels[p] ?? p) }
            StatusPill(status: JiraStatus(name: IssueCodeSection.stateLabels[s] ?? s, category: s == "merged" ? "done" : s == "opened" ? "indeterminate" : "new"))
        } else if r.state == "merged" {
            Chip(text: "已合并")
        } else if r.state == "missing" {
            Chip(text: r.kind == "branch" ? "已删除" : "找不到")
        }
    }

    private var detail: some View {
        let r = item
        var parts: [String] = []
        if let first = r.sources.first {
            let more = r.sources.count > 1 ? " 等 \(r.sources.count) 处" : ""
            switch first.kind {
            // “来自某人的评论”本身是跳到评论的链接（见 body），这里只接上时间
            case "comment":
                let text = "\(first.at.map { Fmt.time($0) } ?? "")\(more)".trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { parts.append(text) }
            case "description": parts.append("描述中的链接\(more)")
            case "mrSearch": parts.append("标题或描述含 \(issueKey)\(more)")
            default: parts.append("提交说明含 \(issueKey)\(more)")
            }
        }
        if let u = r.unavailable { parts.append(u) }
        if r.kind == "external" { parts.append("不在已配置的 GitLab 中，只能在浏览器中打开") }
        if r.kind == "branch", r.commits.isEmpty, !r.title.isEmpty { parts.append("最近提交：\(r.title)\(r.author.map { " · \($0)" } ?? "")\(r.at.map { " · \(Fmt.time($0))" } ?? "")") }
        if r.kind != "branch", let a = r.author { parts.append("\(a)\(r.at.map { " · \(Fmt.time($0))" } ?? "")") }
        return Text(parts.joined(separator: " · ")).lineLimit(1)
    }

    private var menu: [MenuSpec] {
        let r = item
        var specs: [MenuSpec] = []
        if let t = target { specs.append(.action("打开") { AppModel.shared.navigate(t) }) }
        specs.append(.separator)
        if let b = r.branch, r.kind != "commit" { specs.append(.action("复制分支名", icon: "arrow.triangle.branch") { Pasteboard.copy(b); toast("已复制") }) }
        if let sha = r.sha { specs.append(.action("复制提交 SHA", icon: "doc.on.doc") { Pasteboard.copy(sha); toast("已复制") }) }
        specs.append(.action("复制链接", icon: "link") { Pasteboard.copy(r.url); toast("已复制") })
        specs.append(.separator)
        specs.append(.action("在浏览器中打开", icon: "safari") { Links.openInBrowser(r.url) })
        return specs
    }
}
