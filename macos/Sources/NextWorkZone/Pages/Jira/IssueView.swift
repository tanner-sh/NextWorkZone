import os
import SwiftUI
import UniformTypeIdentifiers

/// 问题详情：标题、流转、字段、描述、子任务、关联、相似问题、代码、Wiki、工作空间、附件、评论和历史。
struct IssueView: View {
    var issueKey: String
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
    @State private var assigning = false
    @State private var notice: String?
    @State private var me: String?
    @State private var related: [String: Int] = [:]
    @State private var store = TemplateStore.shared
    @State private var issueMenu = IssueMenu()
    @State private var dropping = false
    @State private var uploading: String?

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
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    // 把文件拖进详情即可上传到当前问题
                    loadURLs(providers) { paths in upload(paths) }
                    return true
                }
                .overlay {
                    if dropping {
                        RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .overlay(Text("上传到 \(issue.key) 的附件").font(.headline).padding(10).glassEffect())
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                LoadingView()
            }
        }
        .task(id: issueKey) {
            store.load()
            if me == nil { me = try? await API.shared.jiraMe() }
            await load()
        }
        .issueMenuDialogs(issueMenu)
        .sheet(item: $activeTransition) { req in
            TransitionSheet(issueKey: req.issue.key, transition: req.transition, issue: req.issue, template: req.template) { apply($0) }
        }
        .sheet(isPresented: $editing) { EditIssueSheet(issueKey: issueKey) { apply($0) } }
        .sheet(isPresented: $assigning) { AssignSheet(key: issueKey, assignee: issue?.assignee) { apply($0) } }
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
            WatchButton(issueKey: issue.key)
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
            // 记录查看；上次查看之后有更新时找出具体变化
            let previous = await ViewedStore.shared.markViewed(key: detail.key, updated: detail.updated)
            if let since = ViewedStore.lastSeen(local: previous, issue: detail.summaryValue), Fmt.ms(detail.updated) > since {
                changes = (since, nil)
                let list = (try? await API.shared.jiraHistory(issueKey)) ?? []
                changes = (since, list.filter { Fmt.ms($0.created) > since })
            }
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func apply(_ detail: IssueDetail) {
        issue = detail
        onChanged(detail.summaryValue)
        // 自己的修改不算新变化
        Task {
            await ViewedStore.shared.markViewed(key: detail.key, updated: detail.updated)
            transitions = (try? await API.shared.jiraTransitions(issueKey)) ?? []
        }
    }

    /// 工作日志变化后刷新耗费时间、剩余估算。
    private func reload() {
        Task { if let d = try? await API.shared.jiraIssue(issueKey) { apply(d) } }
    }

    private func upload(_ paths: [String]) {
        guard !paths.isEmpty, let issue else { return }
        uploading = "正在上传 \(paths.count) 个文件…"
        toast("正在上传 \(paths.count) 个文件到 \(issue.key)…")
        Task {
            do {
                let added = try await API.shared.jiraUploadAttachments(issue.key, paths: paths)
                self.issue?.attachments += added
                toast("已上传 \(added.count) 个附件到 \(issue.key)")
            } catch {
                toast("上传失败：\(errorMessage(error))", error: true)
            }
            uploading = nil
        }
    }

    /// 问题详情空白处右键：编辑、新建子任务、刷新，以及与问题列表相同的问题菜单。
    private func issueActions(_ issue: IssueDetail) -> [MenuSpec] {
        var specs: [MenuSpec] = [.action("编辑…", icon: "pencil") { editing = true }]
        if issue.parent == nil { specs.append(.action("新建子任务…", icon: "plus") { creatingSubtask = true }) }
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

            SubtasksSection(issue: issue, menu: issueMenu) { creatingSubtask = true }
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
                        } catch { notice = errorMessage(error) }
                    }
                }
                Button("写笔记", systemImage: "note.text") {
                    Task {
                        do { model.navigate(NavTarget(.notes, docId: try await DocActions.createIssueNote(key: issue.key, summary: issue.summary).id)) } catch { notice = errorMessage(error) }
                    }
                }
                Button("沉淀到知识库", systemImage: "book") {
                    Task {
                        do { model.navigate(NavTarget(.kb, docId: try await KBImport.issueToPage(issue.key).id)) } catch { notice = errorMessage(error) }
                    }
                }
            }
            .id("workspace")
            AttachmentsSection(issueKey: issue.key, attachments: issue.attachments, busy: uploading) {
                upload(FilePicker.pick())
            }
            IssueActivity(issue: issue, newSince: changes?.since, onCommentsChanged: { self.issue?.comments = $0 }, onTimeChanged: reload)
        }
        .controlSize(.regular)
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

/// 关注 / 取消关注，显示关注人数。
private struct WatchButton: View {
    var issueKey: String
    @State private var watchers: Watchers?
    @State private var busy = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 内容为空时也要执行 task
            Color.clear.frame(width: 0, height: 0)
            if let w = watchers {
                Button {
                    busy = true
                    Task {
                        do { watchers = try await API.shared.jiraSetWatching(issueKey, watching: !w.watching) } catch { toast("操作失败：\(errorMessage(error))", error: true) }
                        busy = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: w.watching ? "eye.fill" : "eye")
                        if w.count > 0 { Text("\(w.count)").foregroundStyle(.secondary) }
                    }
                }
                .disabled(busy)
                .help("\(w.watching ? "取消关注（不再收到这个问题的动态）" : "关注（问题有变化时提醒我）")\(w.count > 0 ? "\n\(w.count) 人关注" : "")")
            }
        }
        .task(id: issueKey) { watchers = try? await API.shared.jiraWatchers(issueKey) }
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

/// 从拖入的项目中取出文件路径。
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([String]) -> Void) {
    let group = DispatchGroup()
    // 各个回调在不同线程上执行
    let paths = OSAllocatedUnfairLock<[String]>(initialState: [])
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL { paths.withLock { $0.append(url.path) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { completion(paths.withLock { $0 }) } }
}
