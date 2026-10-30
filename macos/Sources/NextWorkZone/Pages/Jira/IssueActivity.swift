import SwiftUI

/// 详情底部的活动区：评论、工作日志、变更历史、流转记录。`newSince` 之后别人的评论标为新评论。
struct IssueActivity: View {
    var issue: IssueDetail
    var newSince: Int64?
    var onCommentsChanged: ([Comment]) -> Void
    var onTimeChanged: () -> Void
    @State private var tab = "comments"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("全部").tag("all")
                Text(issue.comments.isEmpty ? "评论" : "评论 \(issue.comments.count)").tag("comments")
                Text(issue.timeTracking?.timeSpent.map { "工作日志 \($0)" } ?? "工作日志").tag("worklogs")
                Text("历史记录").tag("history")
                Text("流转记录").tag("flow")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch tab {
            case "worklogs": Worklogs(issueKey: issue.key, onChanged: onTimeChanged)
            case "history": HistoryList(issueKey: issue.key, created: issue.created, reporter: issue.reporter)
            case "flow": StatusFlow(issue: issue)
            case "all": AllActivity(issue: issue, newSince: newSince, onCommentsChanged: onCommentsChanged) { tab = "comments" }
            default: Comments(issue: issue, newSince: newSince, onChange: onCommentsChanged)
            }
        }
    }
}

private struct Comments: View {
    var issue: IssueDetail
    var newSince: Int64?
    var onChange: ([Comment]) -> Void
    @State private var draft = ""
    @State private var visibility: CommentVisibility?
    @State private var sending = false
    @State private var error: String?
    @State private var images: [PendingImage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if issue.comments.isEmpty { Text("暂无评论").font(.callout).foregroundStyle(.secondary) }
            ForEach(issue.comments) { c in
                CommentItem(issueKey: issue.key, comment: c, isNew: newSince.map { !c.mine && Fmt.ms(c.created) > $0 } ?? false) {
                    quote(c)
                } onUpdated: { updated in
                    onChange(issue.comments.map { $0.id == updated.id ? updated : $0 })
                } onDeleted: {
                    onChange(issue.comments.filter { $0.id != c.id })
                }
                .id("comment-\(c.id)")
            }
            VStack(alignment: .leading, spacing: 6) {
                JiraTextEditor(text: $draft, issueKey: issue.key, onImage: { images.append($0) }, minHeight: 72, placeholder: "添加评论（⌘↵ 发送，输入 @ 提及同事）", onSubmit: send)
                HStack {
                    VisibilitySelect(issueKey: issue.key, value: $visibility)
                    CommentTemplateButton(issue: issue.summaryValue, draft: draft) { text in
                        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + text
                    }
                    Spacer()
                    Button(sending ? "发送中…" : "发送评论", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
                if let error { ErrorBox(message: error) }
            }
        }
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        error = nil
        Task {
            do {
                let used = PendingImage.referenced(images, in: [draft])
                if !used.isEmpty { _ = try await API.shared.jiraUploadAttachments(issue.key, paths: used.map(\.path)) }
                let added = try await API.shared.jiraAddComment(issue.key, body: body, visibility: visibility)
                onChange(issue.comments + [added])
                draft = ""
                images = []
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
            }
            sending = false
        }
    }

    /// 引用评论原文并提及作者。
    private func quote(_ c: Comment) {
        let quoted = "{quote}\n\(c.body.trimmingCharacters(in: .whitespacesAndNewlines))\n{quote}\n\(c.authorName.isEmpty ? "" : "[~\(c.authorName)] ")"
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? quoted : draft.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + quoted
    }
}

private struct CommentItem: View {
    var issueKey: String
    var comment: Comment
    var isNew: Bool
    var onQuote: () -> Void
    var onUpdated: (Comment) -> Void
    var onDeleted: () -> Void
    @State private var editing: String?
    @State private var images: [PendingImage] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let c = comment
        // 编辑过的评论（修改时间比创建时间晚一分钟以上）
        let edited = Fmt.ms(c.updated) - Fmt.ms(c.created) > 60_000
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: c.author, size: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(c.author).fontWeight(.semibold)
                    if isNew { Chip(text: "新", tint: .accentColor) }
                    if let v = c.visibility {
                        Chip(text: "仅 \(v.value) 可见", icon: "lock", tint: .orange).help("这条评论仅「\(v.value)」\(v.type == "role" ? "角色" : "组")的成员可见")
                    }
                    Text(Fmt.time(c.created) + (edited ? "（已编辑）" : "")).font(.caption).foregroundStyle(.secondary).help(edited ? "修改于 \(Fmt.time(c.updated))" : "")
                    Spacer()
                    if editing == nil {
                        Button(action: onQuote) { Image(systemName: "arrowshape.turn.up.left") }.buttonStyle(.borderless).help("引用回复")
                        if c.mine {
                            Button { editing = c.body } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("编辑").accessibilityLabel("编辑")
                            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除")
                        }
                    }
                }
                if let text = editing {
                    JiraTextEditor(text: Binding(get: { text }, set: { editing = $0 }), issueKey: issueKey, onImage: { images.append($0) }, minHeight: 72, onSubmit: save)
                    HStack {
                        Spacer()
                        Button("取消") { editing = nil }
                        Button(busy ? "保存中…" : "保存", action: save).buttonStyle(.borderedProminent).disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    RichHTML(html: c.bodyHtml, service: .jira)
                }
                if let error { ErrorBox(message: error) }
            }
            .padding(10)
            .groupBackground(tint: isNew ? Color.accentColor : nil)
        }
        .contextMenu(specs: { editing == nil ? menu : [] })
    }

    private var menu: [MenuSpec] {
        let c = comment
        let base = AppModel.shared.baseUrl(.jira)
        var specs: [MenuSpec] = [.action("引用回复", icon: "arrowshape.turn.up.left") { onQuote() }]
        if c.mine { specs.append(.action("编辑", icon: "pencil") { editing = c.body }) }
        specs += [
            .separator,
            .action("复制评论内容", icon: "doc.on.doc") { Pasteboard.copy(c.body); toast("已复制") },
            .action("复制评论链接", icon: "link") { Pasteboard.copy("\(base)/browse/\(issueKey)?focusedCommentId=\(c.id)#comment-\(c.id)"); toast("已复制") },
        ]
        if c.mine {
            specs.append(.separator)
            specs.append(.item("删除", icon: "trash", destructive: true, confirm: "确认删除这条评论？") { delete() })
        }
        return specs
    }

    private func remove() {
        Confirm.ask("确认删除这条评论？", then: delete)
    }

    private func delete() {
        busy = true
        Task {
            do {
                try await API.shared.jiraDeleteComment(issueKey, id: comment.id)
                onDeleted()
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
                busy = false
            }
        }
    }

    private func save() {
        guard let text = editing?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        busy = true
        error = nil
        Task {
            do {
                let used = PendingImage.referenced(images, in: [text])
                if !used.isEmpty { _ = try await API.shared.jiraUploadAttachments(issueKey, paths: used.map(\.path)) }
                // 保持原来的可见范围
                onUpdated(try await API.shared.jiraUpdateComment(issueKey, id: comment.id, body: text, visibility: comment.visibility))
                editing = nil
                images = []
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
            }
            busy = false
        }
    }
}

// MARK: - 工作日志

private struct Worklogs: View {
    var issueKey: String
    var onChanged: () -> Void
    @State private var logs: [Worklog]?
    @State private var error: String?
    /// 正在编辑的工作日志；"new" 表示新增
    @State private var editing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error { ErrorBox(message: error) { Task { await load() } } }
            if logs == nil && error == nil { ProgressView().controlSize(.small) }
            if let logs, logs.isEmpty, editing != "new" { Text("暂无工作日志").font(.callout).foregroundStyle(.secondary) }
            ForEach(logs ?? []) { w in
                if editing == w.id {
                    WorklogForm(issueKey: issueKey, worklog: w) { editing = nil } onSaved: { list in
                        logs = list
                        editing = nil
                        onChanged()
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(name: w.author, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(w.author).bold() + Text(" 记录了 ").foregroundStyle(.secondary) + Text(Fmt.duration(w.timeSpent)).bold() + Text(" · 开始于 \(Fmt.time(w.started))").foregroundStyle(.secondary))
                            if !w.comment.isEmpty { Text(w.comment).textSelection(.enabled) }
                        }
                        Spacer()
                        if w.mine {
                            Button { editing = w.id } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("修改").accessibilityLabel("修改")
                            Button {
                                Task {
                                    guard await Confirm.ask("删除这条工作日志？") else { return }
                                    do {
                                        logs = try await API.shared.jiraDeleteWorklog(issueKey, id: w.id)
                                        onChanged()
                                    } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
                                }
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除").accessibilityLabel("删除")
                        }
                    }
                }
            }
            if editing == "new" {
                WorklogForm(issueKey: issueKey, worklog: nil) { editing = nil } onSaved: { list in
                    logs = list
                    editing = nil
                    onChanged()
                }
            } else {
                Button("记录工作", systemImage: "plus") { editing = "new" }
            }
        }
        .task { await load() }
    }

    private func load() async {
        error = nil
        do { logs = try await API.shared.jiraWorklogs(issueKey) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
    }
}

private struct WorklogForm: View {
    var issueKey: String
    var worklog: Worklog?
    var onCancel: () -> Void
    var onSaved: ([Worklog]) -> Void
    @State private var started = Date()
    @State private var timeSpent = ""
    @State private var comment = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("耗费时间 *").font(.callout).foregroundStyle(.secondary)
                    TextField("例如 3h 30m、1d", text: $timeSpent).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始时间 *").font(.callout).foregroundStyle(.secondary)
                    DatePicker("", selection: $started, displayedComponents: [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.field)
                }
            }
            Text("工作描述").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $comment).frame(height: 54).padding(4).fieldBackground()
            Text("时间单位：w 周、d 天、h 小时、m 分钟。剩余估算会自动扣减。").font(.caption).foregroundStyle(.secondary)
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button(saving ? "保存中…" : worklog == nil ? "记录" : "保存修改") {
                    saving = true
                    error = nil
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
                    let input = WorklogInput(started: FieldForm.jiraDateTime(f.string(from: started)), timeSpent: timeSpent.trimmingCharacters(in: .whitespaces), comment: comment)
                    Task {
                        do { onSaved(try await API.shared.jiraSaveWorklog(issueKey, id: worklog?.id, input: input)) } catch {
                            guard !isCancellation(error) else { return }
                            self.error = errorMessage(error)
                            saving = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(timeSpent.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(12)
        .groupBackground()
        .onAppear {
            if let w = worklog {
                started = Fmt.parse(w.started) ?? Date()
                timeSpent = w.timeSpent
                comment = w.comment
            }
        }
    }
}

// MARK: - 流转记录

/// 时长显示为“3天 4小时 5分”；不足一分钟显示秒。
private func formatSpan(_ ms: Int64) -> String {
    let s = max(0, Int((Double(ms) / 1000).rounded()))
    if s < 60 { return "\(s)秒" }
    let (d, h, m) = (s / 86400, (s % 86400) / 3600, (s % 3600) / 60)
    let parts = [d > 0 ? "\(d)天" : nil, h > 0 ? "\(h)小时" : nil, m > 0 ? "\(m)分" : nil].compactMap { $0 }
    return parts.isEmpty ? "0分" : parts.joined(separator: " ")
}

/// 状态流转记录：每次流转、执行人，以及在原状态停留的时间；下面汇总每个状态累计停留的时间。
private struct StatusFlow: View {
    var issue: IssueDetail
    @State private var entries: [HistoryEntry]?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ErrorBox(message: error) { Task { await load() } }
            } else if let entries {
                let steps = entries.flatMap { h in h.items.filter { $0.fieldId == "status" }.map { (id: h.id, author: h.author, at: h.created, from: $0.from ?? "", to: $0.to ?? "") } }
                if steps.isEmpty {
                    Text("还没有状态流转，一直处于「\(issue.status.name)」，已 \(formatSpan(Fmt.nowMs() - Fmt.ms(issue.created)))。").font(.callout).foregroundStyle(.secondary)
                } else {
                    let rows = steps.enumerated().map { i, s in (s, Fmt.ms(s.at) - Fmt.ms(i == 0 ? issue.created : steps[i - 1].at)) }
                    let current = Fmt.nowMs() - Fmt.ms(steps.last!.at)
                    let totals: [(String, Int64)] = {
                        var map: [String: Int64] = [:]
                        for (s, stay) in rows { map[s.from, default: 0] += stay }
                        map[issue.status.name, default: 0] += current
                        return map.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
                    }()
                    VStack(alignment: .leading, spacing: 10) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow {
                                Text("流转"); Text("在原状态停留"); Text("执行人"); Text("时间")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                GridRow {
                                    Text("\(row.0.from) → \(row.0.to)")
                                    Text(formatSpan(row.1))
                                    Text(row.0.author)
                                    Text(Fmt.time(row.0.at)).foregroundStyle(.secondary)
                                }
                            }
                            GridRow {
                                Text("当前：\(issue.status.name)")
                                Text(formatSpan(current))
                                Text("")
                                Text("")
                            }
                            .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        FlowLayout(spacing: 6) {
                            ForEach(totals, id: \.0) { status, ms in
                                (Text(status + " ").foregroundStyle(.secondary) + Text(formatSpan(ms)))
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .chipBackground()
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { await load() }
    }

    private func load() async {
        error = nil
        do { entries = try await API.shared.jiraHistory(issue.key) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
    }
}

// MARK: - 变更历史

private struct HistoryList: View {
    var issueKey: String
    var created: String
    var reporter: String?
    @State private var entries: [HistoryEntry]?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ErrorBox(message: error) { Task { await load() } }
            } else if let entries {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { h in HistoryRow(entry: h) }
                    // 与网页一致，最后一条是创建问题
                    HStack(spacing: 10) {
                        Avatar(name: reporter ?? "?", size: 24)
                        Text(reporter ?? "未知").fontWeight(.semibold)
                        Text("创建了问题 · \(Fmt.time(created))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { await load() }
    }

    private func load() async {
        error = nil
        // 最近的变更排在前面
        do { entries = try await API.shared.jiraHistory(issueKey).reversed() } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
    }
}

/// 一次变更：谁在什么时候改了哪些字段。
private struct HistoryRow: View {
    var entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: entry.author, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.author).fontWeight(.semibold)
                    Text("修改了 · \(Fmt.time(entry.created))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.field).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                        if let f = item.from { HistoryValue(text: f, old: true) } else { Text("无").foregroundStyle(.tertiary) }
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        if let t = item.to { HistoryValue(text: t, old: false) } else { Text("无").foregroundStyle(.tertiary) }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
    }
}

/// 变更前后的值：完整显示（多行的解决方案、描述等），很长时先折叠。
private struct HistoryValue: View {
    var text: String
    var old: Bool
    @State private var expanded = false

    private static let foldedLines = 6
    private var long: Bool { text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.foldedLines || text.count > 400 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .strikethrough(old)
                .foregroundStyle(old ? .secondary : .primary)
                .lineLimit(long && !expanded ? Self.foldedLines : nil)
                .fixedSize(horizontal: false, vertical: true)
            if long {
                Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

// MARK: - 全部

/// 与网页“全部”标签一致：评论和变更按时间先后排在一起。
private struct AllActivity: View {
    var issue: IssueDetail
    var newSince: Int64?
    var onCommentsChanged: ([Comment]) -> Void
    /// 引用回复在评论标签中进行
    var onQuote: () -> Void
    @State private var history: [HistoryEntry]?
    @State private var error: String?

    private enum Item: Identifiable {
        case comment(Comment)
        case change(HistoryEntry)
        var id: String { switch self { case .comment(let c): "c\(c.id)"; case .change(let h): "h\(h.id)" } }
        var time: Int64 { switch self { case .comment(let c): Fmt.ms(c.created); case .change(let h): Fmt.ms(h.created) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error { ErrorBox(message: error) }
            HStack(spacing: 10) {
                Avatar(name: issue.reporter ?? "?", size: 24)
                Text(issue.reporter ?? "未知").fontWeight(.semibold)
                Text("创建了问题 · \(Fmt.time(issue.created))").font(.caption).foregroundStyle(.secondary)
            }
            if history == nil && error == nil { ProgressView().controlSize(.small) }
            let items = (issue.comments.map(Item.comment) + (history ?? []).map(Item.change)).sorted { $0.time < $1.time }
            ForEach(items) { item in
                switch item {
                case .comment(let c):
                    CommentItem(issueKey: issue.key, comment: c, isNew: newSince.map { !c.mine && Fmt.ms(c.created) > $0 } ?? false, onQuote: onQuote) { updated in
                        onCommentsChanged(issue.comments.map { $0.id == updated.id ? updated : $0 })
                    } onDeleted: {
                        onCommentsChanged(issue.comments.filter { $0.id != c.id })
                    }
                case .change(let h): HistoryRow(entry: h)
                }
            }
        }
        .task(id: issue.updated) {
            do { history = try await API.shared.jiraHistory(issue.key) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
        }
    }
}
