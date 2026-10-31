import NWZCore
import SwiftUI
import UniformTypeIdentifiers

/// 问题详情：标题、流转、字段、描述、子任务、关联、相似问题、代码、Wiki、工作空间、附件、评论和历史。
struct IssueView: View {
    var issueKey: String
    /// 在别处（例如列表的右键菜单）改过这个问题后递增：原地重新加载，不重建视图（滚动位置、展开状态、评论草稿保留）
    var version = 0
    var onChanged: (IssueSummary) -> Void

    static let collapsedFieldCount = 10

    @Environment(AppModel.self) private var model
    @State private var issue: IssueDetail?
    @State private var error: String?
    @State private var transitions: [Transition] = []
    @State private var activeTransition: IssueMenu.TransitionRequest?
    /// 上次查看的时间（打开时问题在那之后有更新）及之后的变更记录
    @State private var changes: (since: Int64, history: [HistoryEntry]?)?
    @State private var showAllFields = false
    @State private var editing = false
    @State private var creatingSubtask = false
    /// 克隆或创建链接的问题
    @State private var creatingFrom: CreateFrom?
    @State private var managingWatchers = false
    @State private var votes: Votes?
    @State private var watchers: Watchers?
    @State private var assigning = false
    @State private var notice: String?
    @State private var me: String?
    @State private var related: [String: Int] = [:]
    @State private var store = TemplateStore.shared
    @State private var issueMenu = IssueMenu()
    @State private var dropping = false
    @State private var uploading: String?
    @State private var pickingFiles = false
    /// 下面的区块（子任务、关联、相似问题、评论等）晚一帧再创建：先尽快显示标题、字段和描述
    @State private var showRest = false

    init(issueKey: String, version: Int = 0, onChanged: @escaping (IssueSummary) -> Void) {
        self.issueKey = issueKey
        self.version = version
        self.onChanged = onChanged
        // 看过的问题先显示上次的内容，后台再刷新：在列表里来回点时不必每次都等网络
        let cached = IssueCache.shared.get(issueKey)
        _issue = State(initialValue: cached?.detail)
        _transitions = State(initialValue: cached?.transitions ?? [])
    }

    var body: some View {
        Group {
            if let error {
                VStack { ErrorBox(message: error) { Task { await load() } } }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else if let issue {
                ScrollViewReader { proxy in
                    ScrollView {
                        content(issue, proxy: proxy)
                            .padding(24)
                            .frame(maxWidth: 980, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                }
                .contextMenu(specs: { issueActions(issue) })
                .pageToolbar { toolbar(issue) }
                // 把文件拖进详情即可上传到当前问题
                .dropDestination(for: URL.self) { urls, _ in
                    let paths = urls.filter(\.isFileURL).map(\.path)
                    upload(paths)
                    return !paths.isEmpty
                } isTargeted: { dropping = $0 }
                .overlay { if dropping { DropHighlight(text: "上传到 \(issue.key) 的附件") } }
            } else {
                LoadingView()
            }
        }
        .task(id: issueKey) {
            store.load()
            if me == nil { me = try? await API.shared.jiraMe() }
            await load()
        }
        .onChange(of: version) { Task { await load() } }
        // 这个问题有了新动态（评论、流转等）：重新加载
        .onEvent(Events.local.jiraActivity) { n in
            let keys = (n.userInfo?["payload"] as? String).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            if keys.contains(issueKey) { Task { await load() } }
        }
        .issueMenuDialogs(issueMenu)
        .filePicker(isPresented: $pickingFiles) { upload($0) }
        .sheet(item: $activeTransition) { req in
            TransitionSheet(issueKey: req.issue.key, transition: req.transition, issue: req.issue, template: req.template) { apply($0) }
        }
        .sheet(isPresented: $editing) { EditIssueSheet(issueKey: issueKey) { apply($0) } }
        .sheet(isPresented: $assigning) { AssignSheet(key: issueKey, assignee: issue?.assignee) { apply($0) } }
        .sheet(item: $creatingFrom) { from in
            CreateIssueSheet(source: from.source) { model.navigate(NavTarget(.jira, issueKey: $0)) }
        }
        .sheet(isPresented: $managingWatchers) { WatchersSheet(issueKey: issueKey, watchers: $watchers) }
        .task(id: issueKey) {
            async let v = try? API.shared.jiraVotes(issueKey)
            async let w = try? API.shared.jiraWatchers(issueKey)
            (votes, watchers) = await (v, w)
        }
        .sheet(isPresented: $creatingSubtask) {
            if let issue {
                CreateIssueSheet(parent: IssueRef(key: issue.key, summary: issue.summary, status: issue.status, issueType: issue.issueType)) { _ in reload() }
            }
        }
    }

    // MARK: 工具栏

    /// 可以一步流转的模板（模板指定的流转当前可用）
    private var quickTemplates: [(JiraTemplate, Transition)] {
        store.list.compactMap { tpl -> (JiraTemplate, Transition)? in
            guard tpl.kind == "transition", let t = transitions.first(where: { $0.name == tpl.transition }) else { return nil }
            return (tpl, t)
        }
    }

    /// 问题的操作放在窗口工具栏右侧（列表的操作在左侧）：流转、编辑、关注。
    @ToolbarContentBuilder
    private func toolbar(_ issue: IssueDetail) -> some ToolbarContent {
        if !transitions.isEmpty || !quickTemplates.isEmpty {
            ToolbarItemGroup {
                // 前两个流转直接显示（与 Jira 网页一致），其余和模板收进“更多”
                ForEach(transitions.prefix(2)) { t in
                    Button(t.name) { activeTransition = .init(issue: issue.summaryValue, transition: t) }.help("流转到「\(t.to.name)」")
                }
                if transitions.count + quickTemplates.count > 2 {
                    Button {
                        let templates = quickTemplates
                        var specs: [MenuSpec] = transitions.dropFirst(2).map { t in .action(t.name) { activeTransition = .init(issue: issue.summaryValue, transition: t) } }
                        if !templates.isEmpty && transitions.count > 2 { specs.append(.separator) }
                        specs += templates.map { tpl, t in .action("\(tpl.name)（\(t.name)）", icon: "bolt") { activeTransition = .init(issue: issue.summaryValue, transition: t, template: tpl) } }
                        MenuBuilder.popUp(specs)
                    } label: {
                        Label("更多", systemImage: "chevron.down").labelStyle(.titleAndIcon)
                    }
                    .help("更多流转和流转模板")
                }
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItemGroup {
            Button("编辑", systemImage: "pencil") { editing = true }.help("编辑问题")
            WatchButton(issueKey: issue.key, watchers: $watchers)
            Button("更多操作", systemImage: "ellipsis") { MenuBuilder.popUp(issueActions(issue)) }.help("更多操作（与网页的“更多”一致）")
        }
    }

    // MARK: 加载与更新

    private func load() async {
        error = nil
        do {
            async let detailTask = API.shared.jiraIssue(issueKey)
            async let transitionsTask = try? API.shared.jiraTransitions(issueKey)
            let (detail, available) = try await (detailTask, transitionsTask)
            issue = detail
            transitions = available ?? []
            IssueCache.shared.put(detail, transitions: transitions)
            // 在别处（如网页）改过的问题，到期提醒可能已过时
            if let r = model.reminders?.items.first(where: { $0.key == detail.key }), r.updated != detail.updated { model.issueChanged() }
            // 记录查看；上次查看之后有更新时找出具体变化
            let previous = await ViewedStore.shared.markViewed(key: detail.key, updated: detail.updated)
            if let since = ViewedStore.lastSeen(local: previous, issue: detail.summaryValue), Fmt.ms(detail.updated) > since {
                changes = (since, nil)
                let list = (try? await API.shared.jiraHistory(issueKey)) ?? []
                changes = (since, list.filter { Fmt.ms($0.created) > since })
            }
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
    }

    private func apply(_ detail: IssueDetail) {
        issue = detail
        onChanged(detail.summaryValue)
        IssueCache.shared.put(detail, transitions: transitions)
        model.issueChanged()
        // 自己的修改不算新变化
        Task {
            await ViewedStore.shared.markViewed(key: detail.key, updated: detail.updated)
            transitions = (try? await API.shared.jiraTransitions(issueKey)) ?? []
            IssueCache.shared.put(detail, transitions: transitions)
        }
    }

    private func toggleVote() {
        guard let votes else { return }
        Task {
            do { self.votes = try await API.shared.jiraSetVote(issueKey, voted: !votes.voted) } catch {
                // Jira 不允许给自己报告的问题投票，错误原文已能说明原因
                if !isCancellation(error) { toast("投票失败：\(errorMessage(error))", error: true) }
            }
        }
    }

    /// 工作日志变化后刷新耗费时间、剩余估算。
    private func reload() {
        Task { if let d = try? await API.shared.jiraIssue(issueKey) { apply(d) } }
    }

    private func upload(_ paths: [String]) {
        guard !paths.isEmpty, let issue else { return }
        let size = Fmt.size(paths.map(UploadProgress.fileSize).reduce(0, +))
        let label = "正在上传 \(paths.count) 个文件（\(size)）"
        uploading = label + "…"
        Task {
            do {
                let added = try await withUploadProgress("\(label)到 \(issue.key)", onProgress: { uploading = "\(label)… \(Int($0 * 100))%" }) {
                    try await API.shared.jiraUploadAttachments(issue.key, paths: paths)
                }
                self.issue?.attachments += added
                toast("已上传 \(added.count) 个附件到 \(issue.key)")
            } catch {
                guard !isCancellation(error) else { return }
                toast("上传失败：\(errorMessage(error))", error: true)
            }
            uploading = nil
        }
    }

    private func deleteAttachment(_ a: Attachment) {
        guard let issue else { return }
        uploading = "正在删除 \(a.filename)…"
        Task {
            do {
                try await API.shared.jiraDeleteAttachment(id: a.id)
                self.issue?.attachments.removeAll { $0.id == a.id }
                toast("已从 \(issue.key) 删除附件 \(a.filename)")
            } catch {
                guard !isCancellation(error) else { uploading = nil; return }
                toast("删除失败：\(errorMessage(error))", error: true)
            }
            uploading = nil
        }
    }

    /// 问题详情空白处右键：编辑、新建子任务、刷新，以及与问题列表相同的问题菜单。
    private func issueActions(_ issue: IssueDetail) -> [MenuSpec] {
        var specs: [MenuSpec] = [
            .action("编辑…", icon: "pencil") { editing = true },
            .action("分配…", icon: "person") { assigning = true },
            .action("上传附件…", icon: "paperclip") { pickingFiles = true },
            .separator,
        ]
        if let votes {
            specs.append(.action(votes.voted ? "取消投票" : "投票", icon: votes.voted ? "hand.thumbsup.fill" : "hand.thumbsup") { toggleVote() })
        }
        specs.append(.action("管理关注者…", icon: "eye") { managingWatchers = true })
        specs.append(.separator)
        if issue.parent == nil { specs.append(.action("新建子任务…", icon: "plus") { creatingSubtask = true }) }
        specs.append(.action("创建链接的问题…", icon: "link.badge.plus") { creatingFrom = CreateFrom(source: .linked(issue)) })
        specs.append(.action("克隆…", icon: "plus.square.on.square") { creatingFrom = CreateFrom(source: .clone(issue)) })
        specs.append(.action("打印…", icon: "printer") { IssuePrint.print(issue) })
        specs.append(.separator)
        specs.append(.action("刷新", icon: "arrow.clockwise") { reload() })
        specs.append(.separator)
        return specs + issueMenu.specs(.summary(issue.summaryValue), current: true, onUpdated: apply)
    }

    // MARK: 内容

    @ViewBuilder
    private func content(_ issue: IssueDetail, proxy: ScrollViewProxy) -> some View {
        let reminder = model.reminders?.items.first { $0.key == issue.key }
        // 别人在上次查看之后修改的字段（按显示名称），在字段列表中高亮
        let othersChanges = (changes?.history ?? []).filter { me == nil || $0.authorName != me }
        let changed = Set(othersChanges.flatMap { $0.items.map(\.field) })
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let parent = issue.parent {
                        SysImage(service: .jira, src: parent.issueType?.iconUrl, size: 16)
                        Button("\(parent.key) \(parent.summary)") { model.navigate(NavTarget(.jira, issueKey: parent.key)) }
                            .buttonStyle(.link).lineLimit(1)
                            .contextMenu(specs: { issueMenu.specs(.key(parent.key, summary: parent.summary)) })
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    SysImage(service: .jira, src: issue.issueType.iconUrl, size: 16)
                    Button(issue.key) { Links.openInBrowser("\(model.baseUrl(.jira))/browse/\(issue.key)") }.buttonStyle(.link).help("在浏览器中打开")
                    Text("·").foregroundStyle(.secondary)
                    Text(issue.project.name).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.callout)
                Text(issue.summary).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 8) {
                    StatusPill(status: issue.status)
                    if let r = issue.resolution { Text("解决结果：\(r)").font(.callout).foregroundStyle(.secondary) }
                    if let r = reminder, issue.resolution == nil { Chip(text: AppModel.reminderLabel(r.kind, r.days), tint: r.kind == "overdue" ? .red : .orange) }
                }
                // 代码、Wiki、工作空间中的关联数，点击滚动到对应区块
                let items = [("code", "代码"), ("wiki", "Wiki"), ("workspace", "工作空间")].filter { (related[$0.0] ?? 0) > 0 }
                if !items.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            if i > 0 { Text("·") }
                            Button("\(item.1) \(related[item.0] ?? 0)") { withAnimation { proxy.scrollTo(item.0, anchor: .top) } }.buttonStyle(.plain)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)

            if let notice {
                HStack {
                    Text(notice)
                    Spacer()
                    Button("知道了") { self.notice = nil }
                }
                .padding(10)
                .noticeBackground(.orange)
                .padding(.bottom, 16)
            }

            if let changes {
                ChangesSince(since: changes.since, history: othersChanges, loading: changes.history == nil, issue: issue) { self.changes = nil } onComment: { id in
                    withAnimation { proxy.scrollTo("comment-\(id)", anchor: .center) }
                }
                .padding(.bottom, 16)
            }

            if !issue.attachments.isEmpty || (issue.descriptionHtml?.contains("<img") ?? false) { WebLoginHint(service: .jira).padding(.bottom, 16) }

            fieldsSection(issue, changed: changed).padding(.bottom, 22)

            BlockSection(title: "描述", icon: "doc.text", highlighted: changed.contains("描述") || changed.contains("Description")) {
                if let d = issue.descriptionHtml { RichHTML(html: d, service: .jira) } else { Text("无描述").foregroundStyle(.secondary) }
            }

            ForEach(fieldsShown(issue).filter { $0.html != nil }) { f in
                BlockSection(title: f.name) { RichHTML(html: f.html!, service: .jira) }
            }

            if showRest { rest(issue, proxy: proxy) }
        }
        .controlSize(.regular)
        .task { showRest = true }
    }

    @ViewBuilder
    private func rest(_ issue: IssueDetail, proxy: ScrollViewProxy) -> some View {
        SubtasksSection(issue: issue, menu: issueMenu) { creatingSubtask = true }
        if let jql = issue.epicIssuesJql { EpicIssuesSection(jql: jql, menu: issueMenu) }
        LinksSection(issue: issue, menu: issueMenu, onChanged: apply)
        SimilarSection(issue: issue, menu: issueMenu)
        WikiPagesSection(issueKey: issue.key) { related["wiki"] = $0 }.id("wiki")
        IssueCodeSection(issue: issue, onCount: { related["code"] = $0 }, onComment: { id in withAnimation { proxy.scrollTo("comment-\(id)", anchor: .center) } }).id("code")
        BacklinksSection(system: "jira", itemKey: issue.key, title: "工作空间", onCount: { related["workspace"] = $0 }) {
            Button("添加待办", systemImage: "checkmark.square") {
                Task {
                    do {
                        try await TodoActions.addIssueTodo(key: issue.key, summary: issue.summary)
                        toast("已添加待办")
                    } catch { if !isCancellation(error) { notice = errorMessage(error) } }
                }
            }
            Button("写笔记", systemImage: "note.text") {
                Task {
                    do { model.navigate(NavTarget(.notes, docId: try await DocActions.createIssueNote(key: issue.key, summary: issue.summary).id)) } catch { if !isCancellation(error) { notice = errorMessage(error) } }
                }
            }
            Button("沉淀到知识库", systemImage: "book") {
                Task {
                    do { model.navigate(NavTarget(.kb, docId: try await KBImport.issueToPage(issue.key).id)) } catch { if !isCancellation(error) { notice = errorMessage(error) } }
                }
            }
        }
        .id("workspace")
        AttachmentsSection(issueKey: issue.key, attachments: issue.attachments, busy: uploading, onPick: { pickingFiles = true }, onDelete: deleteAttachment)
        IssueActivity(issue: issue, newSince: changes?.since, onCommentsChanged: { self.issue?.comments = $0 }, onTimeChanged: reload)
    }

    /// 与网页一致只显示问题界面上的字段；“显示全部”时再加上界面外的隐藏字段。
    private func fieldsShown(_ issue: IssueDetail) -> [DisplayField] {
        let screen = issue.fields.filter { !$0.hidden }
        return showAllFields ? issue.fields : Array(screen.prefix(Self.collapsedFieldCount))
    }

    @ViewBuilder
    private func fieldsSection(_ issue: IssueDetail, changed: Set<String>) -> some View {
        let screen = issue.fields.filter { !$0.hidden }
        let hiddenCount = issue.fields.count - screen.count
        // 经办人单独显示在第一行（带分配操作）
        let inline = fieldsShown(issue).filter { $0.html == nil && $0.id != "assignee" }
        let assigneeName = issue.fields.first { $0.id == "assignee" }?.name ?? ""
        VStack(alignment: .leading, spacing: 8) {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
            GridRow {
                FieldName(name: "经办人", changed: changed.contains("经办人") || changed.contains("Assignee") || changed.contains(assigneeName))
                HStack(spacing: 6) {
                    if let a = issue.assignee {
                        Avatar(name: a, size: 20)
                        Text(a)
                    } else {
                        Text("未分配").foregroundStyle(.secondary)
                    }
                    if let me, issue.assigneeName != me {
                        Button("分配给我") { guarded { apply(try await API.shared.jiraAssign(issue.key, assignee: me)) } }.buttonStyle(.borderless)
                    }
                    Button("更改") { assigning = true }.buttonStyle(.borderless)
                }
            }
            GridRow {
                FieldName(name: "优先级", changed: changed.contains("优先级") || changed.contains("Priority"))
                Button {
                    Task {
                        let list = (try? await API.shared.jiraPriorities()) ?? []
                        MenuBuilder.popUp(list.map { p in
                            .action(p.name, checked: issue.priority?.name == p.name) {
                                guard issue.priority?.name != p.name else { return }
                                guarded { apply(try await API.shared.jiraSetPriority(issue.key, priorityId: p.id)) }
                            }
                        })
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let p = issue.priority {
                            SysImage(service: .jira, src: p.iconUrl, size: 16)
                            Text(p.name)
                        } else {
                            Text("无").foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .help("修改优先级")
            }
            ForEach(inline) { f in
                GridRow {
                    FieldName(name: f.name, changed: changed.contains(f.name))
                    HStack(spacing: 6) {
                        if f.id == "assignee" || f.id == "reporter" { Avatar(name: f.text, size: 20) }
                        if let key = f.issueKey {
                            IssueKeyValue(issueKey: key, menu: issueMenu)
                        } else {
                            Text(f.text.firstMatch(of: /^\d{4}-\d{2}-\d{2}T/) != nil ? Fmt.time(f.text) : f.text).textSelection(.enabled)
                        }
                    }
                    .opacity(f.hidden ? 0.6 : 1)
                    .help(f.hidden ? "不在问题界面上（网页中不显示）" : "")
                }
            }
            // 与网页“人员”一栏一致：投票、关注
            if let votes {
                GridRow {
                    FieldName(name: "投票")
                    HStack(spacing: 6) {
                        Text("\(votes.count)").monospacedDigit().padding(.horizontal, 6).chipBackground()
                        Button(votes.voted ? "取消投票" : "为此问题投票") { toggleVote() }.buttonStyle(.borderless)
                    }
                    .help(votes.voters.isEmpty ? "" : "投票人：\(votes.voters.joined(separator: "、"))")
                }
            }
            if let watchers {
                GridRow {
                    FieldName(name: "关注")
                    HStack(spacing: 6) {
                        Text("\(watchers.count)").monospacedDigit().padding(.horizontal, 6).chipBackground()
                        Button(watchers.watching ? "停止关注" : "开始关注此问题") {
                            guarded { self.watchers = try await API.shared.jiraSetWatching(issue.key, watching: !watchers.watching) }
                        }
                        .buttonStyle(.borderless)
                        Button("管理") { managingWatchers = true }.buttonStyle(.borderless)
                    }
                    .help(watchers.users.isEmpty ? "" : "关注者：\(watchers.users.map(\.displayName).joined(separator: "、"))")
                }
            }
            if let tt = issue.timeTracking {
                GridRow {
                    FieldName(name: "时间跟踪")
                    TimeTrackingValue(tt: tt)
                }
            }
        }
        if screen.count > Self.collapsedFieldCount || hiddenCount > 0 {
            Button(showAllFields ? "收起字段" : screen.count > Self.collapsedFieldCount ? "显示全部 \(screen.count) 个字段\(hiddenCount > 0 ? "（另有 \(hiddenCount) 个界面外字段）" : "")" : "显示 \(hiddenCount) 个界面外字段") {
                showAllFields.toggle()
            }
            .buttonStyle(.borderless)
        }
        }
    }
}

/// 字段名：别人刚修改过的标为橙色。
private struct FieldName: View {
    var name: String
    var changed = false

    var body: some View {
        Text(name)
            .foregroundStyle(changed ? Color.orange : Color.secondary)
            .fontWeight(changed ? .semibold : .regular)
            .frame(width: 110, alignment: .leading)
            .help(changed ? "上次查看之后有人修改了这个字段" : "")
    }
}

/// 详情中的一个区块：标题和内容。
struct BlockSection<Content: View, Actions: View>: View {
    var title: String
    var icon: String? = nil
    var count: String? = nil
    var highlighted = false
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                Text(title).font(.headline)
                if let count { Text(count).foregroundStyle(.secondary) }
                Spacer()
                actions()
            }
            content()
        }
        .padding(highlighted ? 10 : 0)
        .background(highlighted ? Color.orange.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 22)
    }
}

extension BlockSection where Actions == EmptyView {
    init(title: String, icon: String? = nil, count: String? = nil, highlighted: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, icon: icon, count: count, highlighted: highlighted, actions: { EmptyView() }, content: content)
    }
}

/// 指向另一个问题的字段值（例如 Epic 链接）：显示概要，点击在应用内打开。
private struct IssueKeyValue: View {
    var issueKey: String
    var menu: IssueMenu
    @State private var summary: String?

    var body: some View {
        Button(summary ?? issueKey) { AppModel.shared.navigate(NavTarget(.jira, issueKey: issueKey)) }
            .buttonStyle(.link)
            .lineLimit(1)
            .help(summary.map { "\(issueKey) \($0)" } ?? issueKey)
            .contextMenu(specs: { menu.specs(.key(issueKey, summary: summary)) })
            .task { summary = (try? await API.shared.jiraPickIssues(issueKey, projectKey: nil, standardOnly: false))?.first { $0.key == issueKey }?.summary }
    }
}

/// 关注 / 取消关注，显示关注人数（与详情中的“关注”一行共用数据）。
private struct WatchButton: View {
    var issueKey: String
    @Binding var watchers: Watchers?
    @State private var busy = false

    var body: some View {
        Button {
            guard let w = watchers else { return }
            busy = true
            Task {
                do { watchers = try await API.shared.jiraSetWatching(issueKey, watching: !w.watching) } catch { toast("操作失败：\(errorMessage(error))", error: true) }
                busy = false
            }
        } label: {
            Label(watchers?.watching == true ? "取消关注" : "关注", systemImage: watchers?.watching == true ? "eye.fill" : "eye")
        }
        .disabled(busy || watchers == nil)
        .help(watchers.map { "\($0.watching ? "取消关注（不再收到这个问题的动态）" : "关注（问题有变化时提醒我）")\($0.count > 0 ? "\n\($0.count) 人关注" : "")" } ?? "")
    }
}

/// 克隆、创建链接的问题（sheet 的标识）。
private struct CreateFrom: Identifiable {
    var source: CreateIssueSheet.Source
    var id: String { source.issue.key }
}

/// 管理关注者：列出关注者，添加、移除。
private struct WatchersSheet: View {
    var issueKey: String
    @Binding var watchers: Watchers?
    @Environment(\.dismiss) private var dismiss
    @State private var adding: [UserRef] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        DialogFrame(title: "\(issueKey) 的关注者", width: 460) {
            VStack(alignment: .leading, spacing: 6) {
                Text("添加关注者").font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    SearchPicker<UserRef>(selected: adding, onChange: { adding = $0 }, search: { q in
                        q.isEmpty ? [] : try await API.shared.jiraFindUsers(q, field: "watcher", issueKey: issueKey, projectKey: nil)
                    }, label: { $0.displayName }, detail: { $0.name }, placeholder: "输入姓名或用户名搜索", multiple: true)
                    Button("添加") { add() }.disabled(adding.isEmpty || busy)
                }
            }
            if let error { ErrorBox(message: error) }
            if let w = watchers {
                if w.users.isEmpty {
                    Text(w.count > 0 ? "共 \(w.count) 人关注（没有查看关注者的权限）" : "还没有人关注").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(w.users) { u in
                            HStack(spacing: 8) {
                                Avatar(name: u.displayName, size: 20)
                                Text(u.displayName)
                                Text(u.name).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { remove(u) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("移除").accessibilityLabel("移除").disabled(busy)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            } else {
                LoadingView()
            }
        } footer: {
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .task { if let w = try? await API.shared.jiraWatchers(issueKey) { watchers = w } }
    }

    private func add() {
        busy = true
        error = nil
        Task {
            do {
                for u in adding { watchers = try await API.shared.jiraSetWatcher(issueKey, username: u.name, watching: true) }
                adding = []
            } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            busy = false
        }
    }

    private func remove(_ u: UserRef) {
        busy = true
        error = nil
        Task {
            do { watchers = try await API.shared.jiraSetWatcher(issueKey, username: u.name, watching: false) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            busy = false
        }
    }
}

/// 时间跟踪：耗费 / 剩余 / 初始估算，以及进度条。
private struct TimeTrackingValue: View {
    var tt: TimeTracking

    var body: some View {
        let spent = Double(tt.timeSpentSeconds ?? 0)
        let remaining = Double(tt.remainingEstimateSeconds ?? 0)
        let total = max(spent + remaining, Double(tt.originalEstimateSeconds ?? 0), 1)
        HStack(spacing: 8) {
            ProgressView(value: spent / total).frame(width: 120)
            Text("已耗费 \(tt.timeSpent ?? "0") · 剩余 \(tt.remainingEstimate ?? "0")").font(.callout)
            if let o = tt.originalEstimate { Text("· 初始估算 \(o)").font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// 上次查看之后别人做的修改：每次修改的字段，以及新评论（点击跳到评论）。
private struct ChangesSince: View {
    var since: Int64
    var history: [HistoryEntry]
    var loading: Bool
    var issue: IssueDetail
    var onDismiss: () -> Void
    var onComment: (String) -> Void

    var body: some View {
        let comments = issue.comments.filter { !$0.mine && Fmt.ms($0.created) > since }
        var commenters: [String] = []
        for c in comments where !commenters.contains(c.author) { commenters.append(c.author) }
        let recent = Array(history.reversed().prefix(6))
        return Group {
            if loading || !history.isEmpty || !comments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("上次查看（\(Fmt.time(ms: since))）之后\(loading ? "，正在查找变化…" : "的变化")").fontWeight(.medium)
                        Spacer()
                        Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("知道了")
                    }
                    ForEach(recent) { h in
                        (Text(h.author).bold() + Text(" 修改了 ") + Text(h.items.map { item in
                            // 状态这类短值直接显示变化
                            let short = (item.to?.count ?? 99) <= 16 && (item.from ?? "").count <= 16 && item.to != nil
                            return short ? "\(item.field)（\(item.from ?? "无") → \(item.to!)）" : item.field
                        }.joined(separator: "、")) + Text(" · \(Fmt.time(h.created))").foregroundStyle(.secondary))
                            .font(.callout)
                    }
                    if history.count > recent.count { Text("还有 \(history.count - recent.count) 次修改，见“历史记录”").font(.caption).foregroundStyle(.secondary) }
                    if !comments.isEmpty {
                        Button("\(commenters.joined(separator: "、")) 添加了 \(comments.count) 条评论") { onComment(comments[0].id) }.buttonStyle(.link)
                    }
                }
                .padding(12)
                .noticeBackground(.accentColor)
            }
        }
    }
}

/// 最近看过的问题详情（只在内存中，最多几十个），切换问题时先显示，再从服务器刷新。
@MainActor
final class IssueCache {
    static let shared = IssueCache()
    private var entries: [String: (detail: IssueDetail, transitions: [Transition])] = [:]
    private var order: [String] = []
    private let limit = 40

    func get(_ key: String) -> (detail: IssueDetail, transitions: [Transition])? { entries[key] }

    func put(_ detail: IssueDetail, transitions: [Transition]) {
        entries[detail.key] = (detail, transitions)
        order.removeAll { $0 == detail.key }
        order.append(detail.key)
        if order.count > limit { entries[order.removeFirst()] = nil }
    }
}

/// 打印问题（网页“导出 → 打印”）：概要、字段、描述和评论。图片需要网页登录，打印时不显示。
@MainActor
enum IssuePrint {
    static func print(_ issue: IssueDetail) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var html = "<html><body style=\"font-family: -apple-system; font-size: 11pt\">"
        html += "<p style=\"color:#666\">\(esc(issue.key)) · \(esc(issue.project.name))</p><h2>\(esc(issue.summary))</h2>"
        html += "<table cellpadding=3>"
        var rows = [("状态", issue.status.name), ("类型", issue.issueType.name), ("优先级", issue.priority?.name ?? "无"), ("经办人", issue.assignee ?? "未分配"), ("报告人", issue.reporter ?? ""), ("创建", Fmt.time(issue.created)), ("更新", Fmt.time(issue.updated))]
        if let r = issue.resolution { rows.append(("解决结果", r)) }
        rows += issue.fields.filter { !$0.hidden && $0.html == nil && !["assignee", "reporter", "priority"].contains($0.id) }.map { ($0.name, $0.text) }
        for (k, v) in rows where !v.isEmpty { html += "<tr><td style=\"color:#666\" valign=top>\(esc(k))</td><td>\(esc(v))</td></tr>" }
        html += "</table><h3>描述</h3>\(issue.descriptionHtml ?? "<p>无描述</p>")"
        for f in issue.fields where !f.hidden { if let h = f.html { html += "<h3>\(esc(f.name))</h3>\(h)" } }
        if !issue.comments.isEmpty {
            html += "<h3>评论（\(issue.comments.count)）</h3>"
            for c in issue.comments { html += "<p style=\"color:#666\"><b>\(esc(c.author))</b> · \(esc(Fmt.time(c.created)))</p>\(c.bodyHtml)<hr>" }
        }
        html += "</body></html>"
        // 去掉图片：附件地址需要网页登录，打印时取不到
        html = html.replacing(/<img[^>]*>/, with: "")
        guard let text = try? NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = "\(issue.key) \(issue.summary)"
        op.runModal(for: MainWindow.window ?? NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
}
