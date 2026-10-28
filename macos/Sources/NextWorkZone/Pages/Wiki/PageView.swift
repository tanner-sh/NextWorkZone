import NWZCore
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
    @State private var doc: RichDoc? { didSet { sections = doc?.sections() ?? [] } }
    /// 正文按顶层标题分段显示（见 RichDoc.sections）：只有滚到附近的段才创建和排版
    @State private var sections: [(doc: RichDoc, headingStart: Int)] = []
    /// 目录跳转到段内的标题（段中第几个标题，0 为段首，滚到段的顶部即可）
    @State private var sectionTarget: (section: Int, local: Int)?
    /// 页面中的标题和引用的问题：长页面遍历一遍要十几毫秒，载入时算好，不在 body 中每次重算
    @State private var headings: [(level: Int, text: String, index: Int)] = []
    @State private var issueKeys: [String] = []
    @State private var error: String?
    @State private var history = false
    @State private var scrollTo: Int?
    @State private var favorites = WikiFavorites.shared
    @State private var issues: [String: IssueSummary] = [:]
    @State private var issueMenu = IssueMenu()
    @State private var width: CGFloat = 0
    /// 观看、点赞、访问限制
    @State private var meta: WikiPageMeta?
    @State private var info = false
    @State private var source: String?
    @State private var copying = false
    @State private var attachmentsVersion = 0

    var body: some View {
        Group {
            if let error {
                VStack { ErrorBox(message: error) { Task { await load() } } }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else if let page {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            content(page)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 24)
                                .frame(maxWidth: 1000, alignment: .leading)
                                .frame(maxWidth: .infinity)
                        }
                        .onChange(of: scrollTo) { _, index in
                            if let index { jump(to: index, proxy: proxy) }
                        }
                    }
                    .contextMenu(specs: { pageActions(page) })
                    .pageToolbar { toolbar(page) }
                    // 正文太窄时不显示目录，留给正文
                    if headings.count >= Self.tocMin && width >= 700 {
                        Divider()
                        TableOfContents(items: headings) { scrollTo = $0 }
                            .frame(width: 220)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            } else {
                LoadingView()
            }
        }
        .task(id: pageId) { await load() }
        .sheet(isPresented: $history) { if let page { HistorySheet(page: page) } }
        .sheet(isPresented: $info) { if let page { PageInfoSheet(page: page, meta: meta) } }
        .sheet(isPresented: $copying) { if let page { CopyPageSheet(page: page) { onOpen($0) } } }
        .sheet(item: Binding(get: { source.map { SourceText(text: $0) } }, set: { source = $0?.text })) { s in
            DialogFrame(title: "存储格式", width: 820) {
                CodeView(code: s.text, path: "page.xml").frame(height: 520)
            } footer: {
                Button("复制") { Pasteboard.copy(s.text); toast("已复制") }
                Spacer()
                Button("关闭") { source = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .task(id: pageId) { meta = try? await API.shared.wikiPageMeta(pageId) }
        .issueMenuDialogs(issueMenu)
    }

    /// 跳到第 index 个标题：先滚到所在的段，标题不在段首时再由这一段滚到标题处。
    private func jump(to index: Int, proxy: ScrollViewProxy) {
        guard let i = sections.lastIndex(where: { $0.headingStart <= index }) else { return }
        let local = index - sections[i].headingStart
        sectionTarget = nil
        proxy.scrollTo("section-\(i)", anchor: .top)
        scrollTo = nil
        guard local > 0 else { return }
        // 段的视图滚到附近才创建，等它排好再滚到段内的标题
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            sectionTarget = (i, local)
        }
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
            headings = d.headings
            issueKeys = keys
            if let anchor, let i = headings.firstIndex(where: { $0.text == anchor || anchor.hasSuffix($0.text.replacingOccurrences(of: " ", with: "")) }) { scrollTo = headings[i].index }
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
    }

    /// 页面的操作放在窗口工具栏右侧：收藏；编辑、新建子页面、历史版本、更多。
    @ToolbarContentBuilder
    private func toolbar(_ page: WikiPageDetail) -> some ToolbarContent {
        let favorite = favorites.contains(page.id)
        ToolbarItem {
            Button(favorite ? "取消收藏" : "收藏", systemImage: favorite ? "star.fill" : "star") {
                favorites.toggle(FavoritePage(id: page.id, title: page.title, space: page.spaceName))
            }
            .tint(favorite ? .yellow : nil)
            .help(favorite ? "取消收藏" : "收藏")
        }
        ToolbarItem {
            Button(meta?.watching == true ? "停止观看" : "观看", systemImage: meta?.watching == true ? "eye.fill" : "eye") { toggleWatch() }
                .disabled(meta == nil)
                .help(meta?.watching == true ? "停止观看（不再收到这个页面的更新通知）" : "观看（页面更新时通知我）")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            if page.canEdit { Button("编辑", systemImage: "pencil", action: onEdit).help("编辑页面") }
            Button("新建子页面", systemImage: "doc.badge.plus") { onNewChild() }.help("新建子页面")
            Button("历史版本", systemImage: "clock.arrow.circlepath") { history = true }.help("历史版本")
            Button("更多", systemImage: "ellipsis") { MenuBuilder.popUp(pageActions(page)) }.help("更多")
        }
    }

    /// 更多按钮、页面空白处右键共用。
    private func pageActions(_ page: WikiPageDetail) -> [MenuSpec] {
        var specs: [MenuSpec] = []
        if page.canEdit { specs.append(.action("编辑", icon: "pencil") { onEdit() }) }
        specs.append(.action("历史版本", icon: "clock.arrow.circlepath") { history = true })
        if let meta {
            specs.append(.action(meta.liked ? "取消赞" : "赞", icon: meta.liked ? "hand.thumbsup.fill" : "hand.thumbsup") { toggleLike() })
            specs.append(.action(meta.watching ? "停止观看" : "观看", icon: meta.watching ? "eye.slash" : "eye") { toggleWatch() })
        }
        specs.append(.action("上传附件…", icon: "paperclip") { upload(FilePicker.pick()) })
        specs.append(.action("页面信息…", icon: "info.circle") { info = true })
        specs.append(.action("复制页面…", icon: "plus.square.on.square") { copying = true })
        specs.append(.separator)
        specs.append(.action("导出为 PDF", icon: "doc.richtext") { export(page, word: false) })
        specs.append(.action("导出为 Word", icon: "doc") { export(page, word: true) })
        specs.append(.action("查看存储格式", icon: "chevron.left.forwardslash.chevron.right") { guarded { source = try await API.shared.wikiStorage(page.id) } })
        specs.append(.separator)
        specs.append(.action("刷新", icon: "arrow.clockwise") { Task { await load() } })
        specs.append(.separator)
        return specs + WikiMenus.page(id: page.id, title: page.title, space: page.spaceName, current: true, onNewChild: { onNewChild() })
    }

    private func toggleWatch() {
        guard let meta else { return }
        guarded {
            try await API.shared.wikiSetWatching(pageId, watching: !meta.watching)
            self.meta?.watching = !meta.watching
            toast(meta.watching ? "已停止观看" : "已开始观看，页面更新时会通知你")
        }
    }

    private func toggleLike() {
        guard meta != nil else { return }
        guarded {
            try await API.shared.wikiSetLiked(pageId, liked: !(meta?.liked ?? false))
            meta = try await API.shared.wikiPageMeta(pageId)
        }
    }

    private func upload(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let size = Fmt.size(paths.map(UploadProgress.fileSize).reduce(0, +))
        guarded {
            try await withUploadProgress("正在上传 \(paths.count) 个文件（\(size)）") { try await API.shared.wikiUpload(pageId, paths: paths) }
            attachmentsVersion += 1
            toast("已上传 \(paths.count) 个附件")
        }
    }

    private func export(_ page: WikiPageDetail, word: Bool) {
        toast(word ? "正在导出 Word…" : "正在导出 PDF（页面较长时需要一会儿）…")
        guarded { toast("已保存到 \(try await API.shared.wikiExport(page, word: word))") }
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
                guard !isCancellation(error) else { return }
                self.doc = self.doc?.settingTask(id, done: !done)
                toast("修改任务失败：\(errorMessage(error))", error: true)
            }
        }
    }

    @ViewBuilder
    private func content(_ page: WikiPageDetail) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
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
            Text(page.title).font(.title.weight(.semibold)).textSelection(.enabled)
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

            if doc != nil {
                ForEach(sections.indices, id: \.self) { i in
                    let local = sectionTarget.flatMap { $0.section == i && $0.local > 0 ? $0.local : nil }
                    RichView(doc: sections[i].doc, service: .confluence, onTask: { toggleTask($0) }, scrollToHeading: local)
                        .padding(.bottom, i == sections.count - 1 ? 24 : 8)
                        .id("section-\(i)")
                }
            } else {
                ProgressView().padding(.bottom, 24)
            }

            let keys = issueKeys
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
            PageFooter(page: page, meta: meta, onLike: toggleLike) { await load() }
                .padding(.bottom, 22)
            ChildPages(pageId: page.id, onOpen: onOpen)
            WikiAttachments(pageId: page.id, version: attachmentsVersion) { upload(FilePicker.pick()) }
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
    var version: Int
    var onUpload: () -> Void
    @State private var list: [Attachment]?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0)
            if let list, !list.isEmpty {
                let sorted = list.sorted { $0.created > $1.created }
                BlockSection(title: "附件", icon: "paperclip", count: "\(list.count)") {
                    Button("上传附件", systemImage: "square.and.arrow.up", action: onUpload)
                } content: {
                    VStack(spacing: 6) {
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { i, a in
                            WikiAttachmentRow(attachment: a)
                            .rowTap { AttachmentViewer.show(sorted, index: i, service: .confluence) }
                            .contextMenu(specs: { AttachmentViewer.menu(a, preview: { AttachmentViewer.show(sorted, index: i, service: .confluence) }, service: .confluence) })
                        }
                    }
                }
            }
        }
        .task(id: "\(pageId)|\(version)") { list = (try? await API.shared.wikiAttachments(pageId)) ?? [] }
    }
}

/// 附件的一行：悬停时显示复制按钮。
private struct WikiAttachmentRow: View {
    var attachment: Attachment
    @State private var hover = false

    var body: some View {
        let a = attachment
        HStack(spacing: 6) {
            Image(systemName: "paperclip").foregroundStyle(.secondary)
            Text(a.filename).lineLimit(1)
            Spacer()
            Text("\(Fmt.size(a.size)) · \(a.author) · \(Fmt.time(a.created))").font(.caption).foregroundStyle(.secondary)
            Button { AttachmentViewer.copy(a, service: .confluence) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .opacity(hover ? 1 : 0)
                .help("复制文件，可以粘贴到访达、聊天或邮件中")
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help("点击在应用内预览，右键可复制、用系统应用打开")
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
        do { comments = try await API.shared.wikiComments(pageId) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
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
            do { versions = try await API.shared.wikiVersions(page.id) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
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
            do { diff = try await API.shared.wikiDiff(pageId, from: from, to: to) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
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
            do { html = try await API.shared.wikiVersionHtml(pageId, version: version) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
        }
    }
}

private struct SourceText: Identifiable {
    var text: String
    var id: Int { text.hashValue }
}

/// 页面底部（与网页一致）：点赞和标签。
private struct PageFooter: View {
    var page: WikiPageDetail
    var meta: WikiPageMeta?
    var onLike: () -> Void
    var onChanged: () async -> Void
    @State private var adding = false
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let meta {
                HStack(spacing: 8) {
                    Button(meta.liked ? "已赞" : "赞", systemImage: meta.liked ? "hand.thumbsup.fill" : "hand.thumbsup", action: onLike)
                        .controlSize(.small)
                    Text(meta.likes.isEmpty ? "成为第一个赞同者" : meta.likes.count <= 3 ? "\(meta.likes.joined(separator: "、")) 赞了" : "\(meta.likes.prefix(3).joined(separator: "、")) 等 \(meta.likes.count) 人赞了")
                        .font(.callout).foregroundStyle(.secondary)
                        .help(meta.likes.joined(separator: "、"))
                }
            }
            FlowLayout(spacing: 6) {
                Image(systemName: "tag").foregroundStyle(.secondary)
                if page.labels.isEmpty && !adding { Text("无标签").font(.callout).foregroundStyle(.secondary) }
                ForEach(page.labels, id: \.self) { label in
                    HStack(spacing: 3) {
                        Button(label) { AppModel.shared.navigate(NavTarget(.wiki, wikiSearch: "label:\(label)")) }.buttonStyle(.plain).help("查看带这个标签的页面")
                        if page.canEdit {
                            Button { remove(label) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).help("移除标签")
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 3).chipBackground()
                }
                if page.canEdit {
                    if adding {
                        TextField("标签，空格分隔，回车添加", text: $input)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .onSubmit(add)
                            .onExitCommand { adding = false; input = "" }
                    } else {
                        Button("编辑标签", systemImage: "plus") { adding = true }.buttonStyle(.borderless).font(.callout)
                    }
                }
            }
        }
    }

    private func add() {
        // Wiki 标签不能有空格，统一小写（与网页一致）
        let names = input.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "，" }).map { $0.lowercased() }.filter { !$0.isEmpty && !page.labels.contains($0) }
        adding = false
        input = ""
        guard !names.isEmpty else { return }
        guarded {
            try await API.shared.wikiAddLabels(page.id, names: names)
            await onChanged()
        }
    }

    private func remove(_ label: String) {
        guarded {
            try await API.shared.wikiRemoveLabel(page.id, name: label)
            await onChanged()
        }
    }
}

/// 页面信息（网页“更多 → 页面信息”）：创建、修改、版本、标签、访问限制、链接。
private struct PageInfoSheet: View {
    var page: WikiPageDetail
    var meta: WikiPageMeta?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogFrame(title: "页面信息", width: 520) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                row("标题", page.title)
                row("空间", "\(page.spaceName)（\(page.spaceKey)）")
                row("位置", ([page.spaceName] + page.ancestors.map(\.title)).joined(separator: " / "))
                row("创建", "\(page.createdBy) · \(Fmt.time(page.created))")
                row("最后修改", "\(page.modifiedBy) · \(Fmt.time(page.modified))")
                row("版本", "第 \(page.version) 版\(page.versionMessage.isEmpty ? "" : "：\(page.versionMessage)")")
                row("标签", page.labels.isEmpty ? "无" : page.labels.joined(separator: "、"))
                if let meta {
                    row("查看限制", meta.readRestrictions.isEmpty ? "无限制" : meta.readRestrictions.joined(separator: "、"))
                    row("编辑限制", meta.updateRestrictions.isEmpty ? "无限制" : meta.updateRestrictions.joined(separator: "、"))
                    row("赞", meta.likes.isEmpty ? "无" : meta.likes.joined(separator: "、"))
                    row("观看", meta.watching ? "正在观看" : "未观看")
                }
                row("页面 ID", page.id)
                row("链接", page.url)
            }
        } footer: {
            Button("复制链接") { Pasteboard.copy(page.url); toast("已复制") }
            Spacer()
            Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}

/// 复制页面（网页“更多 → 复制”）：正文复制到同一位置下的新页面，附件不复制。
private struct CopyPageSheet: View {
    var page: WikiPageDetail
    var onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        DialogFrame(title: "复制页面", width: 480) {
            Text("在「\(page.ancestors.last?.title ?? page.spaceName)」下创建一份正文相同的新页面（不复制附件和评论）。").font(.callout).foregroundStyle(.secondary)
            TextField("新页面标题", text: $title).textFieldStyle(.roundedBorder)
            if let error { ErrorBox(message: error) }
        } footer: {
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(busy ? "复制中…" : "复制") {
                busy = true
                error = nil
                Task {
                    do {
                        let id = try await API.shared.wikiCopyPage(page, title: title.trimmingCharacters(in: .whitespaces))
                        toast("已复制为「\(title)」")
                        dismiss()
                        onCreated(id)
                    } catch {
                        guard !isCancellation(error) else { return }
                        self.error = errorMessage(error)
                        busy = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { title = "\(page.title) 的副本" }
    }
}
