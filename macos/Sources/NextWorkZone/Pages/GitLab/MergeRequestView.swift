import SwiftUI

/// 合并请求详情：状态、相关问题、描述、动态和讨论；提交；改动（可以评论某一行）。
struct MergeRequestView: View {
    var project: String
    var iid: Int
    var onBack: (() -> Void)? = nil
    var onChanged: ((MergeRequest) -> Void)? = nil

    enum Tab { case overview, commits, changes }

    @Environment(AppModel.self) private var model
    @State private var mr: MergeRequest?
    @State private var approvals: Approvals?
    @State private var discussions: [Discussion]?
    @State private var me: GlUser?
    @State private var error: String?
    @State private var tab: Tab = .overview
    @State private var commits: [Commit]?
    @State private var changes: MrChanges?
    @State private var subError: String?
    @State private var merging = false
    @State private var editing = false
    @State private var busy = false
    @State private var description: RichDoc?
    @State private var openCommit: String?

    private static let draftPrefix = /(?i)^\s*(\[draft\]|\(draft\)|draft:|draft\s|\[wip\]|wip:)\s*/

    private var projectRef: String { mr.map { String($0.projectId) } ?? project }

    var body: some View {
        Group {
            if let error {
                VStack(alignment: .leading) {
                    if let onBack { Button("返回", systemImage: "chevron.left", action: onBack) }
                    ErrorBox(message: error) { Task { await load() } }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let mr {
                ScrollView {
                    content(mr)
                        .padding(24)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .contextMenu(specs: { moreEntries(mr) })
            } else {
                LoadingView()
            }
        }
        .task(id: "\(project)!\(iid)") {
            await load()
            me = await GitLab.me()
        }
        .task(id: "\(tab)|\(mr?.id ?? 0)") { await loadTab() }
        .sheet(isPresented: $merging) {
            if let mr {
                MergeSheet(mr: mr, approvals: approvals, unresolved: unresolved) { next in
                    updated(next)
                    Task { await load() }
                    toast("已合并到 \(next.targetBranch)")
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let mr {
                EditMrSheet(mr: mr) { next in
                    updated(next)
                    changes = nil
                    commits = nil
                    toast("已保存")
                }
            }
        }
    }

    private var unresolved: Int {
        (discussions ?? []).filter { $0.notes.contains { $0.resolvable && !$0.resolved } }.count
    }

    private func load() async {
        error = nil
        do {
            async let m = API.shared.glMergeRequest(project, iid: iid)
            async let d = API.shared.glMrDiscussions(project, iid: iid)
            let (detail, list) = try await (m, d)
            mr = detail
            discussions = list
            description = detail.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : await GitLab.markdown(detail.description, projectUrl: GitLab.projectUrl(detail))
            approvals = try? await API.shared.glMrApprovals(String(detail.projectId), iid: iid)
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// 提交和改动在切换到对应标签时再加载。
    private func loadTab() async {
        guard let mr else { return }
        subError = nil
        do {
            if tab == .commits && commits == nil { commits = try await API.shared.glMrCommits(String(mr.projectId), iid: iid) }
            if tab == .changes && changes == nil { changes = try await API.shared.glMrChanges(String(mr.projectId), iid: iid) }
        } catch {
            subError = errorMessage(error)
        }
    }

    private func updated(_ next: MergeRequest) {
        mr = next
        onChanged?(next)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await action() } catch { toast(errorMessage(error), error: true) }
            busy = false
        }
    }

    private func refresh() {
        commits = nil
        changes = nil
        Task { await load() }
    }

    private func setState(_ event: String) {
        guard let mr else { return }
        if event == "close" && !Confirm.ask("确定关闭合并请求 !\(mr.iid) 吗？") { return }
        run {
            updated(try await API.shared.glMrUpdate(projectRef, iid: iid, update: MrUpdate(stateEvent: event)))
            toast(event == "close" ? "已关闭" : "已重新打开")
        }
    }

    /// 更多按钮、详情空白处右键共用。
    private func moreEntries(_ mr: MergeRequest) -> [MenuSpec] {
        var specs: [MenuSpec] = []
        if mr.state == "opened" {
            specs.append(.action("编辑标题和描述", icon: "pencil") { editing = true })
            specs.append(.action(mr.draft ? "标记为就绪" : "标记为草稿") {
                run {
                    let title = mr.draft ? mr.title.replacing(Self.draftPrefix, with: "") : "Draft: \(mr.title)"
                    updated(try await API.shared.glMrUpdate(projectRef, iid: iid, update: MrUpdate(title: title)))
                    toast(mr.draft ? "已标记为就绪" : "已标记为草稿")
                }
            })
        }
        specs.append(.action("刷新", icon: "arrow.clockwise") { refresh() })
        specs.append(.separator)
        specs += GitLab.mrMenu(mr)
        if mr.state == "opened" {
            specs.append(.separator)
            specs.append(.item("关闭合并请求", icon: "xmark.circle", destructive: true) { setState("close") })
        }
        return specs
    }

    /// GitLab 只在需要时才重新检查能否合并，“未检查”时网页端也允许合并（合并时再检查），这里保持一致。
    private func mergeable(_ mr: MergeRequest) -> Bool {
        mr.canMerge && !mr.draft && !mr.hasConflicts && mr.mergeStatus != "cannot_be_merged"
    }

    @ViewBuilder
    private func content(_ mr: MergeRequest) -> some View {
        let projectPath = GitLab.projectPath(mr)
        let userDiscussions = (discussions ?? []).filter { !($0.notes.first?.system ?? false) }.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let onBack { Button("返回", systemImage: "chevron.left", action: onBack) }
                Button(projectPath) { model.navigate(NavTarget(.gitlab, projectId: mr.projectId)) }.buttonStyle(.link).help("打开项目")
                Text("!\(mr.iid)").foregroundStyle(.secondary)
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新")
                Button { Links.openInBrowser(mr.webUrl) } label: { Image(systemName: "safari") }.buttonStyle(.borderless).help("在浏览器中打开")
            }
            .font(.callout)
            HStack(spacing: 8) {
                if mr.draft { Chip(text: "草稿") }
                Text(mr.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                MrStatePill(state: mr.state)
                Avatar(name: mr.author.name, size: 18)
                Text("\(mr.author.name) 创建于 \(Fmt.time(mr.createdAt))")
                Text(mr.sourceBranch).font(.caption.monospaced()).padding(.horizontal, 6).chipBackground().help("源分支")
                Text("→")
                Text(mr.targetBranch).font(.caption.monospaced()).padding(.horizontal, 6).chipBackground().help("目标分支")
                Button { Pasteboard.copy(mr.sourceBranch); toast("已复制分支名") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制源分支名")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Picker("", selection: $tab) {
                    Text(userDiscussions > 0 ? "概览 \(userDiscussions)" : "概览").tag(Tab.overview)
                    Text(commits.map { "提交 \($0.count)" } ?? "提交").tag(Tab.commits)
                    Text(mr.changesCount.map { "改动 \($0)" } ?? "改动").tag(Tab.changes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if mr.state == "opened", let a = approvals, a.userCanApprove, !a.userHasApproved {
                    Button("批准", systemImage: "hand.thumbsup") { run { approvals = try await API.shared.glMrApprove(projectRef, iid: iid, approve: true); toast("已批准") } }.disabled(busy)
                }
                if mr.state == "opened", approvals?.userHasApproved == true {
                    Button("取消批准", systemImage: "arrow.uturn.backward") { run { approvals = try await API.shared.glMrApprove(projectRef, iid: iid, approve: false); toast("已取消批准") } }.disabled(busy)
                }
                if mr.state == "opened" && mr.canMerge {
                    Button("合并", systemImage: "arrow.triangle.merge") { merging = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !mergeable(mr))
                        .help(mergeable(mr) ? "" : mr.draft ? "草稿状态不能合并，先标记为就绪" : "有冲突，需要先解决")
                }
                if mr.state == "closed" { Button("重新打开") { setState("reopen") }.disabled(busy) }
                Button { MenuBuilder.popUp(moreEntries(mr)) } label: { Image(systemName: "ellipsis") }.help("更多")
            }
            switch tab {
            case .overview: overview(mr, projectPath: projectPath)
            case .commits:
                if let sha = openCommit {
                    CommitDetailView(projectId: mr.projectId, projectPath: projectPath, sha: sha) { openCommit = nil }.frame(minHeight: 400)
                } else {
                    if let subError { ErrorBox(message: subError) }
                    if let commits { CommitListView(commits: commits) { openCommit = $0 } } else if subError == nil { ProgressView() }
                }
            case .changes:
                if let subError { ErrorBox(message: subError) }
                if let changes {
                    if changes.overflow { Text("改动过多，只显示了部分文件。").font(.caption).foregroundStyle(.secondary) }
                    if changes.diffs.isEmpty { Text("没有改动。").foregroundStyle(.secondary) } else { DiffListView(diffs: changes.diffs, annotations: annotations(mr)) }
                } else if subError == nil {
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private func overview(_ mr: MergeRequest, projectPath: String) -> some View {
        StatusPanel(mr: mr, approvals: approvals, unresolved: unresolved)
        RelatedIssuesSection(target: CodeTarget(projectPath: projectPath, iid: mr.iid, text: "\(mr.title) \(mr.sourceBranch) \(mr.description)"))
        if let description {
            RichView(doc: description, service: .gitlab)
        } else {
            Text("没有描述").font(.callout).foregroundStyle(.secondary)
        }
        BlockSection(title: "动态", icon: "bubble.left") {
            if discussions == nil { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 10) {
                ForEach((discussions ?? []).sorted { ($0.notes.first?.createdAt ?? "") < ($1.notes.first?.createdAt ?? "") }) { d in
                    if d.notes.allSatisfy(\.system) {
                        ForEach(d.notes) { n in
                            HStack(spacing: 6) {
                                Image(systemName: "circle.fill").font(.system(size: 5))
                                Text(n.author.name).fontWeight(.medium)
                                Text(systemText(n.body)).lineLimit(1)
                                Spacer()
                                Text(Fmt.time(n.createdAt))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        ThreadView(discussion: d, actions: threadActions(mr), outdated: d.notes.first?.position.map { $0.headSha != mr.diffRefs?.headSha } ?? false) { tab = .changes }
                    }
                }
            }
            CommentBox(placeholder: "发表评论，支持 Markdown（⌘↵ 发送）") { body in
                let d = try await API.shared.glMrAddNote(projectRef, iid: iid, body: body)
                discussions = (discussions ?? []) + [d]
            }
        }
    }

    /// 讨论的操作：回复、解决、编辑、删除。
    private func threadActions(_ mr: MergeRequest) -> ThreadActions {
        let replace: (Discussion) -> Void = { d in discussions = (discussions ?? []).map { $0.id == d.id ? d : $0 } }
        return ThreadActions(
            me: me,
            projectUrl: GitLab.projectUrl(mr),
            reply: { d, body in
                let note = try await API.shared.glMrReply(projectRef, iid: iid, discussion: d.id, body: body)
                var next = d
                next.notes.append(note)
                replace(next)
            },
            resolve: { d, resolved in replace(try await API.shared.glMrResolve(projectRef, iid: iid, discussion: d.id, resolved: resolved)) },
            edit: { d, note, body in
                let next = try await API.shared.glMrEditNote(projectRef, iid: iid, note: note.id, body: body)
                var updated = d
                updated.notes = d.notes.map { $0.id == note.id ? next : $0 }
                replace(updated)
            },
            remove: { d, note in
                guard Confirm.ask("确定删除这条评论吗？") else { return }
                try await API.shared.glMrDeleteNote(projectRef, iid: iid, note: note.id)
                let notes = d.notes.filter { $0.id != note.id }
                if notes.isEmpty { discussions = (discussions ?? []).filter { $0.id != d.id } } else {
                    var next = d
                    next.notes = notes
                    replace(next)
                }
            }
        )
    }

    /// 在当前版本改动上的行内讨论；基于旧版本的只在概览中显示。
    private func annotations(_ mr: MergeRequest) -> DiffAnnotations {
        var threads: [String: [Discussion]] = [:]
        for d in discussions ?? [] {
            guard let pos = d.notes.first?.position, pos.headSha == mr.diffRefs?.headSha else { continue }
            threads[DiffLine(oldLine: pos.oldLine, newLine: pos.newLine).key(pos.newPath), default: []].append(d)
        }
        let actions = threadActions(mr)
        var result = DiffAnnotations(threads: threads, thread: { d in AnyView(ThreadView(discussion: d, actions: actions, compact: true)) })
        if let refs = mr.diffRefs, mr.state == "opened" {
            result.onComment = { diff, line, body in
                let d = try await API.shared.glMrAddNote(projectRef, iid: iid, body: body, position: NotePosition(baseSha: refs.baseSha, startSha: refs.startSha, headSha: refs.headSha, oldPath: diff.oldPath, newPath: diff.newPath, oldLine: line.oldLine, newLine: line.newLine))
                discussions = (discussions ?? []) + [d]
            }
        }
        return result
    }

    /// GitLab 系统记录的常见英文文案。
    private func systemText(_ body: String) -> String {
        let first = body.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")[0]
        let rules: [(Regex<AnyRegexOutput>, (AnyRegexOutput) -> String)] = [
            (try! Regex("^approved this merge request$"), { _ in "批准了此合并请求" }),
            (try! Regex("^unapproved this merge request$"), { _ in "取消了批准" }),
            (try! Regex("^marked this merge request as \\*\\*draft\\*\\*$"), { _ in "标记为草稿" }),
            (try! Regex("^marked this merge request as \\*\\*ready\\*\\*$"), { _ in "标记为就绪" }),
            (try! Regex("^changed the description$"), { _ in "修改了描述" }),
            (try! Regex("^changed title from (.*)$"), { m in "修改了标题：\(m[1].substring ?? "")" }),
            (try! Regex("^closed$"), { _ in "关闭了此合并请求" }),
            (try! Regex("^reopened$"), { _ in "重新打开了此合并请求" }),
            (try! Regex("^merged$"), { _ in "合并了此合并请求" }),
            (try! Regex("^mentioned in commit (\\w+)$"), { m in "在提交 \(m[1].substring ?? "") 中提及" }),
            (try! Regex("^mentioned in merge request (.*)$"), { m in "在合并请求 \(m[1].substring ?? "") 中提及" }),
            (try! Regex("^resolved all threads$"), { _ in "解决了所有讨论" }),
            (try! Regex("^added (\\d+) commits?"), { m in "推送了 \(m[1].substring ?? "") 个提交" }),
            (try! Regex("^changed target branch from (.*) to (.*)$"), { m in "目标分支从 \(m[1].substring ?? "") 改为 \(m[2].substring ?? "")" }),
            (try! Regex("^requested review from (.*)$"), { m in "请 \(m[1].substring ?? "") 审核" }),
            (try! Regex("^assigned to (.*)$"), { m in "指派给 \(m[1].substring ?? "")" }),
            (try! Regex("^enabled an automatic merge when the pipeline for (\\w+) succeeds$"), { _ in "设置了流水线通过后自动合并" }),
        ]
        for (re, text) in rules {
            if let m = try? re.firstMatch(in: first) { return text(m.output) }
        }
        return first
    }
}

private struct StatusPanel: View {
    var mr: MergeRequest
    var approvals: Approvals?
    var unresolved: Int

    var body: some View {
        var rows: [(Bool?, String)] = []
        if mr.state == "merged" {
            rows.append((true, "\(mr.mergedBy?.name ?? "") 于 \(Fmt.time(mr.mergedAt)) 合并到 \(mr.targetBranch)"))
        } else if mr.state == "closed" {
            rows.append((nil, "\(mr.closedBy?.name ?? "") 于 \(Fmt.time(mr.closedAt)) 关闭"))
        } else {
            if mr.hasConflicts { rows.append((false, "有冲突，需要在本地合并目标分支后重新推送")) }
            else if mr.mergeStatus == "can_be_merged" { rows.append((true, mr.draft ? "没有冲突（草稿状态，标记为就绪后才能合并）" : "没有冲突，可以合并")) }
            else if mr.mergeStatus == "cannot_be_merged" { rows.append((false, "无法自动合并，需要在本地合并目标分支后重新推送")) }
            else { rows.append((nil, "GitLab 尚未检查是否有冲突，合并时会再检查")) }
            if let e = mr.mergeError { rows.append((false, "上次合并失败：\(e)")) }
        }
        if let p = mr.headPipeline {
            rows.append((p.status == "success" ? true : p.status == "failed" ? false : nil, GitLab.pipelineLabels[p.status] ?? "流水线：\(p.status)"))
        }
        if let a = approvals {
            rows.append(a.approvedBy.isEmpty ? (nil, "尚未有人批准") : (true, "已由 \(a.approvedBy.map(\.name).joined(separator: "、")) 批准"))
        }
        if unresolved > 0 { rows.append((false, "\(unresolved) 个讨论未解决")) }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                let (ok, text) = rows[i]
                Label(text, systemImage: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(ok == true ? Color.green : ok == false ? Color.red : Color.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground()
    }
}

/// 讨论的操作。
struct ThreadActions {
    var me: GlUser?
    var projectUrl: String
    var reply: (Discussion, String) async throws -> Void
    var resolve: (Discussion, Bool) async throws -> Void
    var edit: (Discussion, MrNote, String) async throws -> Void
    var remove: (Discussion, MrNote) async throws -> Void
}

/// 一个讨论串。`compact` 用在改动中的行下面（不显示文件位置）。
private struct ThreadView: View {
    var discussion: Discussion
    var actions: ThreadActions
    var compact = false
    var outdated = false
    var onShowDiff: (() -> Void)? = nil
    @State private var replying = false
    @State private var editing: Int?
    @State private var busy = false
    @State private var collapsed: Bool?

    var body: some View {
        let d = discussion
        let notes = d.notes.filter { !$0.system }
        let resolvable = d.notes.contains(where: \.resolvable)
        let resolved = resolvable && d.notes.allSatisfy { !$0.resolvable || $0.resolved }
        let isCollapsed = collapsed ?? resolved
        let pos = notes.first?.position
        VStack(alignment: .leading, spacing: 8) {
            if (!compact && pos != nil) || resolvable {
                HStack(spacing: 6) {
                    if !compact, let pos {
                        Image(systemName: "doc.text.magnifyingglass")
                        Button("\(pos.newPath):\(pos.newLine ?? pos.oldLine ?? 0)") { onShowDiff?() }.buttonStyle(.link).lineLimit(1).help("查看改动")
                        if outdated { Chip(text: "旧版本") }
                    }
                    Spacer()
                    if resolved {
                        Button(isCollapsed ? "已解决 · 展开 \(notes.count) 条" : "收起") { collapsed = !isCollapsed }.buttonStyle(.link)
                    }
                    if resolvable {
                        Button(resolved ? "重新打开" : "解决", systemImage: "checkmark") { resolve(resolved) }.controlSize(.small).disabled(busy)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !isCollapsed {
                ForEach(notes) { n in note(n, resolvable: resolvable, resolved: resolved) }
                if replying {
                    CommentBox(placeholder: "回复（⌘↵ 发送，Esc 取消）", onCancel: { replying = false }) { body in
                        try await actions.reply(d, body)
                        replying = false
                    }
                } else if !d.individualNote || resolvable {
                    Button("回复", systemImage: "arrowshape.turn.up.left") { replying = true }.buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
        .padding(10)
        .groupBackground(tint: resolved ? Color.green : nil)
    }

    private func resolve(_ resolved: Bool) {
        busy = true
        Task {
            do {
                try await actions.resolve(discussion, !resolved)
                collapsed = !resolved
            } catch { toast(errorMessage(error), error: true) }
            busy = false
        }
    }

    @ViewBuilder
    private func note(_ n: MrNote, resolvable: Bool, resolved: Bool) -> some View {
        let mine = actions.me?.id == n.author.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Avatar(name: n.author.name, size: 22)
                Text(n.author.name).fontWeight(.semibold)
                Text(Fmt.time(n.createdAt)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if mine && editing != n.id {
                    Button { editing = n.id } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("编辑")
                    Button { remove(n) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除")
                }
            }
            if editing == n.id {
                EditNoteBox(initial: n.body) { editing = nil } onSave: { body in
                    try await actions.edit(discussion, n, body)
                    editing = nil
                }
            } else {
                NoteBody(body: n.body, projectUrl: actions.projectUrl)
            }
        }
        .contextMenu(specs: {
            guard editing != n.id else { return [] }
            var specs: [MenuSpec] = []
            if !discussion.individualNote || resolvable { specs.append(.action("回复", icon: "arrowshape.turn.up.left") { replying = true }) }
            if resolvable { specs.append(.action(resolved ? "重新打开讨论" : "解决讨论", icon: "checkmark") { resolve(resolved) }) }
            if mine { specs.append(.action("编辑", icon: "pencil") { editing = n.id }) }
            specs.append(.separator)
            specs.append(.action("复制评论内容", icon: "doc.on.doc") { Pasteboard.copy(n.body); toast("已复制") })
            if mine {
                specs.append(.separator)
                specs.append(.item("删除", icon: "trash", destructive: true) { remove(n) })
            }
            return specs
        })
    }

    private func remove(_ n: MrNote) {
        Task {
            do { try await actions.remove(discussion, n) } catch { toast(errorMessage(error), error: true) }
        }
    }
}

/// 评论正文（GitLab Markdown）。
private struct NoteBody: View {
    var body_: String
    var projectUrl: String
    @State private var doc: RichDoc?

    init(body: String, projectUrl: String) {
        self.body_ = body
        self.projectUrl = projectUrl
    }

    var body: some View {
        Group {
            if let doc { RichView(doc: doc, service: .gitlab) } else { Text(body_).foregroundStyle(.secondary) }
        }
        .task(id: body_) { doc = await GitLab.markdown(body_, projectUrl: projectUrl) }
    }
}

/// 编辑评论：⌘↵ 保存，Esc 取消。
private struct EditNoteBox: View {
    var initial: String
    var onCancel: () -> Void
    var onSave: (String) async throws -> Void
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text).font(.body).frame(minHeight: 80).padding(4).fieldBackground()
                .onKeyPress(.escape) { onCancel(); return .handled }
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button(saving ? "保存中…" : "保存") {
                    saving = true
                    Task {
                        do { try await onSave(text) } catch { self.error = errorMessage(error) }
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .onAppear { text = initial }
    }
}

// MARK: - 对话框

private struct MergeSheet: View {
    var mr: MergeRequest
    var approvals: Approvals?
    var unresolved: Int
    var onMerged: (MergeRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var squash = false
    @State private var removeSource = false
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("合并 !\(mr.iid)").font(.headline)
            Text("把 \(mr.sourceBranch) 合并到 \(mr.targetBranch)。")
            if let a = approvals, a.approvedBy.isEmpty { Text("提示：还没有人批准。").font(.caption).foregroundStyle(.secondary) }
            if unresolved > 0 { Text("提示：还有 \(unresolved) 个讨论未解决。").font(.caption).foregroundStyle(.secondary) }
            if let p = mr.headPipeline, p.status != "success" { Text("提示：\(GitLab.pipelineLabels[p.status] ?? p.status)。").font(.caption).foregroundStyle(.secondary) }
            Toggle("合并后删除源分支", isOn: $removeSource).toggleStyle(.checkbox)
            Toggle("压缩为一个提交（squash）", isOn: $squash).toggleStyle(.checkbox)
            Text("只在合并请求仍是当前看到的版本时合并；如果期间有人推送了新提交，会提示失败，刷新后再看。").font(.caption).foregroundStyle(.secondary)
            if mr.mergeStatus != "can_be_merged" { Text("GitLab 还没检查是否有冲突，合并时会检查；有冲突会提示失败。").font(.caption).foregroundStyle(.secondary) }
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(submitting ? "合并中…" : "合并", systemImage: "arrow.triangle.merge") {
                    submitting = true
                    error = nil
                    Task {
                        do {
                            onMerged(try await API.shared.glMrMerge(String(mr.projectId), iid: mr.iid, squash: squash, removeSourceBranch: removeSource, sha: mr.sha))
                            dismiss()
                        } catch {
                            self.error = errorMessage(error)
                            submitting = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(submitting)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            squash = mr.squash
            removeSource = mr.forceRemoveSourceBranch ?? false
        }
    }
}

private struct EditMrSheet: View {
    var mr: MergeRequest
    var onSaved: (MergeRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var target = ""
    @State private var branches: [Branch]?
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        let dirty = title != mr.title || description != mr.description || target != mr.targetBranch
        DialogFrame(title: "编辑 !\(mr.iid)", width: 640) {
            Text("标题").font(.callout).foregroundStyle(.secondary)
            TextField("", text: $title).textFieldStyle(.roundedBorder)
            Text("目标分支").font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $target) {
                if !(branches ?? []).contains(where: { $0.name == target }) { Text(target).tag(target) }
                ForEach((branches ?? []).filter { $0.name != mr.sourceBranch }) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
            Text("描述（Markdown）").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $description).font(.body).frame(minHeight: 200).padding(4).fieldBackground()
            if let error { ErrorBox(message: error) }
        } footer: {
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(submitting ? "保存中…" : "保存") {
                submitting = true
                var update = MrUpdate()
                if title != mr.title { update.title = title }
                if description != mr.description { update.description = description }
                if target != mr.targetBranch { update.targetBranch = target }
                Task {
                    do {
                        onSaved(try await API.shared.glMrUpdate(String(mr.projectId), iid: mr.iid, update: update))
                        dismiss()
                    } catch {
                        self.error = errorMessage(error)
                        submitting = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!dirty || title.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
        }
        .interactiveDismissDisabled(dirty)
        .onAppear {
            title = mr.title
            description = mr.description
            target = mr.targetBranch
        }
        .task { branches = (try? await API.shared.glBranches(mr.projectId)) ?? [] }
    }
}

/// 新建合并请求：标题按自己最近的标题格式预填，目标分支默认用最常合并到的分支。
struct NewMergeRequestSheet: View {
    var project: Project
    var branches: [Branch]
    var initialSource: String?
    var onCreated: (MergeRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var source = ""
    @State private var target = ""
    @State private var targetTouched = false
    @State private var compareError: String?
    @State private var title = ""
    @State private var titleTouched = false
    @State private var description = ""
    @State private var descTouched = false
    @State private var removeSource = true
    @State private var squash = false
    @State private var compare: Comparison?
    @State private var existing: MergeRequest?
    @State private var pattern: (prefix: String, suffix: String)?
    @State private var submitting = false
    @State private var error: String?

    /// 受保护的分支（开发、发布主干）一般是目标而不是源，排在后面。
    private var candidates: [Branch] { branches.filter { !$0.default && !$0.protected } + branches.filter { !$0.default && $0.protected } }

    var body: some View {
        let noChanges = compare.map { $0.commits.isEmpty } ?? false
        DialogFrame(title: "新建合并请求 · \(project.name)", width: 680) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("源分支").font(.callout).foregroundStyle(.secondary)
                    Picker("", selection: $source) {
                        if candidates.isEmpty { Text("没有可用的分支").tag("") }
                        ForEach(candidates) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("目标分支").font(.callout).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { target }, set: { target = $0; targetTouched = true })) {
                        ForEach(branches.filter { $0.name != source }) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                }
            }
            Text(compareError.map { "对比分支失败：\($0)" } ?? (compare == nil ? (!source.isEmpty && source != target ? "正在对比分支…" : "") : noChanges ? "「\(source)」相对「\(target)」没有新提交，无需合并。" : "\(compare!.commits.count) 个提交，\(compare!.diffs.count) 个文件有改动。"))
                .font(.caption).foregroundStyle(.secondary)
            if let existing { ErrorBox(message: "这个分支已经有打开的合并请求 !\(existing.iid)：\(existing.title)") }
            Text("标题").font(.callout).foregroundStyle(.secondary)
            TextField("", text: Binding(get: { title }, set: { title = $0; titleTouched = true })).textFieldStyle(.roundedBorder)
            if let p = pattern, !(p.prefix.isEmpty && p.suffix.isEmpty), !titleTouched { Text("已按你最近的标题格式预填。").font(.caption).foregroundStyle(.secondary) }
            Text("描述（Markdown）").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { description }, set: { description = $0; descTouched = true })).font(.body).frame(minHeight: 140).padding(4).fieldBackground()
            Toggle("合并后删除源分支", isOn: $removeSource).toggleStyle(.checkbox)
            if project.squashOption != "never" {
                Toggle("合并时压缩为一个提交（squash）", isOn: $squash).toggleStyle(.checkbox).disabled(project.squashOption == "always")
            }
            if let error { ErrorBox(message: error) }
        } footer: {
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(submitting ? "创建中…" : "创建", systemImage: "arrow.triangle.pull", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || source.isEmpty || source == target || title.trimmingCharacters(in: .whitespaces).isEmpty || existing != nil || noChanges)
        }
        .interactiveDismissDisabled(titleTouched || descTouched)
        .onAppear {
            let defaultBranch = project.defaultBranch ?? branches.first?.name ?? ""
            source = initialSource.flatMap { $0 != defaultBranch ? $0 : nil } ?? candidates.first?.name ?? ""
            target = defaultBranch
            removeSource = project.removeSourceBranchAfterMerge ?? true
            squash = project.squashOption == "default_on" || project.squashOption == "always"
        }
        .task { await learn() }
        .task(id: "\(source)|\(target)|\(pattern != nil)") { await compareBranches() }
    }

    /// 自己最近在这个项目里的合并请求：学习标题格式，目标分支默认用最常合并到的分支。
    private func learn() async {
        do {
            async let mineTask = API.shared.glMergeRequests(scope: "created_by_me", query: MrQuery(state: "all"))
            async let recentTask = API.shared.glProjectMergeRequests(String(project.id), query: MrQuery(state: "all"))
            let (allMine, recent) = try await (mineTask, recentTask)
            // 优先用这个项目里自己的；太少时用自己在所有项目里的（团队的标题格式通常一致）
            let here = allMine.filter { $0.projectId == project.id }
            let mine = Array((here.count >= 3 ? here : allMine).prefix(10))
            var counts: [String: Int] = [:]
            for m in here.isEmpty ? Array(recent.prefix(20)) : here { counts[m.targetBranch, default: 0] += 1 }
            if let usual = counts.sorted(by: { $0.value > $1.value }).map(\.key).first(where: { n in branches.contains { $0.name == n } }), !targetTouched {
                target = usual
                if source == usual { source = candidates.first { $0.name != usual }?.name ?? "" }
            }
            pattern = GitLab.learnTitlePattern(mine.map(\.title))
        } catch {
            pattern = ("", "")
        }
    }

    /// 源分支的提交、是否已有打开的合并请求；预填标题和描述（分支名里有问题号时用问题标题，否则用唯一提交的标题）。
    private func compareBranches() async {
        compare = nil
        compareError = nil
        existing = nil
        guard let pattern, !source.isEmpty, !target.isEmpty, source != target else { return }
        do {
            let c = try await API.shared.glCompare(project.id, from: target, to: source)
            compare = c
            existing = (try? await API.shared.glProjectMergeRequests(String(project.id), query: MrQuery(state: "opened", sourceBranch: source)))?.first
            let commits = c.commits
            if !descTouched {
                let only = commits.count == 1 ? commits[0].message.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : ""
                // 提交很多（通常是选错了分支）时不逐条列出
                description = commits.count > 1 && commits.count <= 30 ? commits.map { "- \($0.title)" }.joined(separator: "\n") : only
            }
            guard !titleTouched else { return }
            let fallback = commits.count == 1 ? commits[0].title : source
            title = fallback
            if let key = GitLab.issueKeys(in: source).first {
                if model.isReady(.jira), let issue = try? await API.shared.jiraIssue(key) {
                    if !titleTouched { title = "\(pattern.prefix)\(key) \(issue.summary)\(pattern.suffix)" }
                } else {
                    title = "\(pattern.prefix)\(key) \(fallback)\(pattern.suffix)"
                }
            }
        } catch {
            compareError = errorMessage(error)
        }
    }

    private func submit() {
        submitting = true
        error = nil
        Task {
            do {
                let mr = try await API.shared.glMrCreate(String(project.id), mr: NewMergeRequest(sourceBranch: source, targetBranch: target, title: title.trimmingCharacters(in: .whitespaces), description: description, removeSourceBranch: removeSource, squash: squash))
                onCreated(mr)
                dismiss()
            } catch {
                self.error = errorMessage(error)
                submitting = false
            }
        }
    }
}
