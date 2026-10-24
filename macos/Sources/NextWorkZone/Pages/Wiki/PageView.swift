import SwiftUI

/// 阅读 Wiki 页面：面包屑、标题、正文（Jira 宏实时状态、任务可勾选）、目录、引用的问题、子页面、附件、工作空间引用、评论。
struct PageView: View {
    var pageId: String
    var anchor: String?
    var onOpen: (String) -> Void
    var onLoaded: (WikiPageDetail) -> Void
    var onEdit: () -> Void
    var onNewChild: () -> Void

    /// 目录至少有这么多标题时才显示。
    static let tocMin = 3

    @Environment(AppModel.self) private var model
    @State private var page: WikiPageDetail?
    @State private var doc: RichDoc?
    @State private var error: String?
    @State private var history = false
    @State private var scrollTo: Int?
    @State private var favorites = WikiFavorites.shared
    @State private var issues: [String: IssueSummary] = [:]
    @State private var issueMenu = IssueMenu()

    var body: some View {
        Group {
            if let error {
                VStack { ErrorBox(message: error) { Task { await load() } } }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else if let page {
                let headings = doc?.headings ?? []
                HStack(spacing: 0) {
                    ScrollView {
                        content(page)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: 1000, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                    .contextMenu(specs: { pageActions(page) })
                    if headings.count >= Self.tocMin {
                        Divider()
                        TableOfContents(items: headings) { scrollTo = $0 }
                            .frame(width: 220)
                    }
                }
            } else {
                LoadingView()
            }
        }
        .task(id: pageId) { await load() }
        .sheet(isPresented: $history) { if let page { HistorySheet(page: page) } }
        .issueMenuDialogs(issueMenu)
    }

    private func load() async {
        error = nil
        do {
            let detail = try await API.shared.wikiPage(pageId)
            page = detail
            onLoaded(detail)
            favorites.refresh(FavoritePage(id: detail.id, title: detail.title, space: detail.spaceName))
            let d = try await Rich.fromHTML(detail.html)
            // 先查好页面中的 Jira 问题再显示：长页面只排版一次
            let keys = d.issueKeys(jiraBase: model.baseUrl(.jira))
            if !keys.isEmpty && model.isReady(.jira) { issues = await IssueLookup.fetch(keys) }
            doc = d
            if let anchor, let i = d.headings.firstIndex(where: { $0.text == anchor || anchor.hasSuffix($0.text.replacingOccurrences(of: " ", with: "")) }) { scrollTo = d.headings[i].index }
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// 更多按钮、页面空白处右键共用。
    private func pageActions(_ page: WikiPageDetail) -> [MenuSpec] {
        var specs: [MenuSpec] = []
        if page.canEdit { specs.append(.action("编辑", icon: "pencil", onEdit)) }
        specs.append(.action("历史版本", icon: "clock.arrow.circlepath") { history = true })
        specs.append(.action("刷新", icon: "arrow.clockwise") { Task { await load() } })
        specs.append(.separator)
        return specs + WikiMenus.page(id: page.id, title: page.title, space: page.spaceName, current: true, onNewChild: onNewChild)
    }

    /// 点击任务的勾选框：勾选或取消（写入 Wiki）。
    private func toggleTask(_ task: RichTask) {
        guard let id = task.id, let page, let doc else { return }
        let done = !task.done
        self.doc = doc.settingTask(id, done: done)
        Task {
            do {
                try await API.shared.wikiSetTask(page.id, task: id, done: done)
                toast(done ? "已完成任务" : "已取消完成")
            } catch {
                self.doc = self.doc?.settingTask(id, done: !done)
                toast("修改任务失败：\(errorMessage(error))", error: true)
            }
        }
    }

    @ViewBuilder
    private func content(_ page: WikiPageDetail) -> some View {
        let favorite = favorites.contains(page.id)
        VStack(alignment: .leading, spacing: 0) {
            // 面包屑
            HStack(spacing: 4) {
                Text(page.spaceName)
                ForEach(page.ancestors) { a in
                    Image(systemName: "chevron.right").font(.caption2)
                    Button(a.title) { onOpen(a.id) }.buttonStyle(.link).lineLimit(1)
                        .contextMenu(specs: { WikiMenus.page(id: a.id, title: a.title) })
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(page.title).font(.title.weight(.semibold)).textSelection(.enabled)
                Button {
                    favorites.toggle(FavoritePage(id: page.id, title: page.title, space: page.spaceName))
                } label: {
                    Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(favorite ? "取消收藏" : "收藏")
                Spacer()
                if page.canEdit { Button("编辑", systemImage: "pencil", action: onEdit) }
                Button { onNewChild() } label: { Image(systemName: "doc.badge.plus") }.help("新建子页面")
                Button { history = true } label: { Image(systemName: "clock.arrow.circlepath") }.help("历史版本")
                Button { MenuBuilder.popUp(pageActions(page)) } label: { Image(systemName: "ellipsis") }.help("更多")
            }
            HStack(spacing: 6) {
                Text("\(page.modifiedBy) 修改于 \(Fmt.time(page.modified)) · 第 \(page.version) 版")
                if !page.createdBy.isEmpty { Text("· \(page.createdBy) 创建于 \(Fmt.time(page.created))") }
                ForEach(page.labels, id: \.self) { Chip(text: $0, icon: "tag") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.bottom, 18)

            WebLoginHint(service: .confluence).padding(.bottom, 10)

            if let doc {
                RichView(doc: doc, service: .confluence, onTask: { toggleTask($0) }, scrollToHeading: scrollTo)
                    .padding(.bottom, 24)
            } else {
                ProgressView().padding(.bottom, 24)
            }

            let keys = doc?.issueKeys(jiraBase: model.baseUrl(.jira)) ?? []
            if !keys.isEmpty {
                BlockSection(title: "引用的问题", icon: "smallcircle.filled.circle", count: "\(keys.count)") {
                    VStack(spacing: 6) {
                        ForEach(keys, id: \.self) { key in
                            let issue = issues[key]
                            HStack(spacing: 6) {
                                Text(key).font(.callout.monospaced()).foregroundStyle(.secondary)
                                Text(issue?.summary ?? (model.isReady(.jira) ? "无法获取（可能没有权限）" : "")).lineLimit(1)
                                Spacer()
                                if let issue { StatusPill(status: issue.status) }
                            }
                            .rowTap { if model.isReady(.jira) { model.navigate(NavTarget(.jira, issueKey: key)) } }
                            .contextMenu(specs: { model.isReady(.jira) ? issueMenu.specs(issue.map { .summary($0) } ?? .key(key, summary: nil)) : [] })
                        }
                    }
                }
            }
            ChildPages(pageId: page.id, onOpen: onOpen)
            WikiAttachments(pageId: page.id)
            BacklinksSection(system: "wiki", itemKey: page.id, title: "工作空间", hideEmpty: true)
            WikiComments(pageId: page.id)
        }
    }
}

private struct TableOfContents: View {
    var items: [(level: Int, text: String, index: Int)]
    var onSelect: (Int) -> Void

    var body: some View {
        let minLevel = items.map(\.level).min() ?? 1
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("目录").font(.caption).foregroundStyle(.secondary).padding(.bottom, 2)
                ForEach(items, id: \.index) { item in
                    Button(item.text) { onSelect(item.index) }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .lineLimit(2)
                        .padding(.leading, CGFloat(item.level - minLevel) * 12)
                        .help(item.text)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChildPages: View {
    var pageId: String
    var onOpen: (String) -> Void
    @State private var children: [WikiNode]?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0)
            if let children, !children.isEmpty {
                BlockSection(title: "子页面", icon: "doc.text", count: "\(children.count)") {
                    FlowLayout(spacing: 6) {
                        ForEach(children) { c in
                            Button { onOpen(c.id) } label: { Label(c.title, systemImage: "doc.text") }
                                .contextMenu(specs: { WikiMenus.page(id: c.id, title: c.title) })
                        }
                    }
                }
            }
        }
        .task(id: pageId) { children = (try? await API.shared.wikiChildren(pageId)) ?? [] }
    }
}

private struct WikiAttachments: View {
    var pageId: String
    @State private var list: [Attachment]?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0)
            if let list, !list.isEmpty {
                let sorted = list.sorted { $0.created > $1.created }
                BlockSection(title: "附件", icon: "paperclip", count: "\(list.count)") {
                    VStack(spacing: 6) {
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { i, a in
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip").foregroundStyle(.secondary)
                                Text(a.filename).lineLimit(1)
                                Spacer()
                                Text("\(Fmt.size(a.size)) · \(a.author) · \(Fmt.time(a.created))").font(.caption).foregroundStyle(.secondary)
                            }
                            .help("在应用内预览")
                            .rowTap { AttachmentViewer.show(sorted, index: i, service: .confluence) }
                            .contextMenu(specs: { AttachmentViewer.menu(a, preview: { AttachmentViewer.show(sorted, index: i, service: .confluence) }, service: .confluence) })
                        }
                    }
                }
            }
        }
        .task(id: pageId) { list = (try? await API.shared.wikiAttachments(pageId)) ?? [] }
    }
}

/// 页面评论：页面底部的评论和行内评论，按回复关系缩进显示；可以发表评论和回复。
private struct WikiComments: View {
    var pageId: String
    @State private var comments: [WikiComment]?
    @State private var error: String?
    @State private var replyTo: String?

    /// 按回复关系排成树：顶层评论按时间，回复跟在被回复的评论后面。
    private var ordered: [(WikiComment, Int)] {
        let list = comments ?? []
        let ids = Set(list.map(\.id))
        var byParent: [String: [WikiComment]] = [:]
        for c in list { byParent[c.parentId.flatMap { ids.contains($0) ? $0 : nil } ?? "", default: []].append(c) }
        var out: [(WikiComment, Int)] = []
        func walk(_ parent: String, _ depth: Int) {
            for c in byParent[parent] ?? [] {
                out.append((c, depth))
                walk(c.id, depth + 1)
            }
        }
        walk("", 0)
        return out
    }

    var body: some View {
        BlockSection(title: "评论", icon: "bubble.left", count: (comments?.isEmpty ?? true) ? nil : "\(comments!.count)") {
            if let error { ErrorBox(message: error) { Task { await load() } } }
            if comments == nil && error == nil { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ordered, id: \.0.id) { c, depth in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Avatar(name: c.author, size: 22)
                            Text(c.author).fontWeight(.semibold)
                            Text(Fmt.time(c.created)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("回复", systemImage: "arrowshape.turn.up.left") { replyTo = replyTo == c.id ? nil : c.id }.buttonStyle(.borderless).controlSize(.small)
                        }
                        if let inline = c.inlineText {
                            Text("行内评论：\(inline)").font(.caption).foregroundStyle(.secondary).padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                        }
                        RichHTML(html: c.html, service: .confluence)
                        if replyTo == c.id {
                            CommentBox(placeholder: "回复 \(c.author)", onCancel: { replyTo = nil }) { text in
                                comments = try await API.shared.wikiAddComment(pageId, parent: c.id, text: text)
                                replyTo = nil
                            }
                        }
                    }
                    .padding(.leading, CGFloat(min(depth, 4)) * 24)
                }
            }
            if comments?.isEmpty == true { Text("还没有评论").font(.callout).foregroundStyle(.secondary) }
            CommentBox(placeholder: "发表评论（⌘↵ 发送）") { text in
                comments = try await API.shared.wikiAddComment(pageId, parent: nil, text: text)
            }
        }
        .task(id: pageId) { await load() }
    }

    private func load() async {
        error = nil
        do { comments = try await API.shared.wikiComments(pageId) } catch { self.error = errorMessage(error) }
    }
}

/// 页面的历史版本：选择一个版本查看它与上一版（或任意版本）的差异，也可以查看当时的完整内容。
struct HistorySheet: View {
    var page: WikiPageDetail
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [WikiVersion]?
    @State private var error: String?
    @State private var selected = 0
    /// 比较的基准版本；为空时与上一版比较
    @State private var base: Int?
    @State private var mode = "diff"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("历史版本 · \(page.title)").font(.headline).lineLimit(1)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let error { ErrorBox(message: error).padding() }
            if let versions {
                HSplitView {
                    List(selection: Binding(get: { selected }, set: { if let v = $0 { selected = v } })) {
                        ForEach(versions) { v in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(v.number) 版\(v.number == page.version ? " · 当前" : "")\(v.minorEdit ? " · 小修改" : "")")
                                Text("\(v.by) · \(Fmt.time(v.when))\(v.message.isEmpty ? "" : " · \(v.message)")").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .tag(v.number)
                        }
                    }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("", selection: $mode) {
                                Text("变化").tag("diff")
                                Text("完整内容").tag("view")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            if mode == "diff" {
                                Picker("对比", selection: Binding(get: { base ?? 0 }, set: { base = $0 == 0 ? nil : $0 })) {
                                    Text("上一版").tag(0)
                                    ForEach(versions.filter { $0.number != selected }) { v in Text("第 \(v.number) 版（\(v.by)）").tag(v.number) }
                                }
                                .fixedSize()
                            }
                        }
                        let from = base ?? versions.first { $0.number < selected }?.number
                        ScrollView {
                            Group {
                                if mode == "diff" {
                                    if let from {
                                        VersionDiff(pageId: page.id, from: min(from, selected), to: max(from, selected))
                                    } else {
                                        Text("这是第一个版本。").foregroundStyle(.secondary)
                                    }
                                } else {
                                    VersionContent(pageId: page.id, version: selected)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .frame(minWidth: 480)
                }
            } else if error == nil {
                LoadingView()
            }
        }
        .frame(width: 980, height: 680)
        .task {
            selected = page.version
            do { versions = try await API.shared.wikiVersions(page.id) } catch { self.error = errorMessage(error) }
        }
    }
}

struct VersionDiff: View {
    var pageId: String
    var from: Int
    var to: Int
    @State private var diff: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { ErrorBox(message: error) }
            if let diff {
                Text("第 \(from) 版 → 第 \(to) 版（按段落比较文字内容，格式变化不显示）").font(.caption).foregroundStyle(.secondary)
                TextDiffView(diff: diff)
            } else if error == nil {
                ProgressView()
            }
        }
        .task(id: "\(from)-\(to)") {
            diff = nil
            error = nil
            do { diff = try await API.shared.wikiDiff(pageId, from: from, to: to) } catch { self.error = errorMessage(error) }
        }
    }
}

private struct VersionContent: View {
    var pageId: String
    var version: Int
    @State private var html: String?
    @State private var error: String?

    var body: some View {
        VStack {
            if let error { ErrorBox(message: error) }
            if let html { RichHTML(html: html, service: .confluence) } else if error == nil { ProgressView() }
        }
        .task(id: version) {
            html = nil
            do { html = try await API.shared.wikiVersionHtml(pageId, version: version) } catch { self.error = errorMessage(error) }
        }
    }
}
