import SwiftUI

/// Jira 问题的菜单及其需要的对话框（填写字段的流转、分配给其他人）。
/// 问题列表、首页、问题详情、Wiki 和笔记中的问题链接等处共用，保证同一个问题在哪里右键都是同一份菜单。
@MainActor @Observable
final class IssueMenu {
    /// 不属于某个页面的地方（富文本的右键菜单）使用的实例，对话框挂在主窗口上。
    static let shared = IssueMenu()

    enum Target {
        /// 完整的列表项
        case summary(IssueSummary)
        /// 只知道问题键（和概要）时按需查询其余字段
        case key(String, summary: String?)

        var key: String {
            switch self {
            case .summary(let s): s.key
            case .key(let k, _): k
            }
        }
    }

    struct TransitionRequest: Identifiable {
        let id = UUID()
        var issue: IssueSummary
        var transition: Transition
        var template: JiraTemplate?
        var done: ((IssueDetail) -> Void)?
    }

    struct AssignRequest: Identifiable {
        let id = UUID()
        var issue: IssueSummary
        var done: ((IssueDetail) -> Void)?
    }

    var transition: TransitionRequest?
    var assigning: AssignRequest?

    /// 按问题键查询列表项需要的字段。
    static func fetchSummary(_ key: String) async throws -> IssueSummary {
        guard let issue = try await API.shared.jiraSearch("key = \(key)", startAt: 0, maxResults: 1).issues.first else {
            throw APIError(message: "找不到问题 \(key)（可能没有权限）")
        }
        return issue
    }

    /// `current` 为真表示正在查看这个问题（不显示“打开”）；`onUpdated` 在流转、分配、改优先级成功后调用。
    func specs(_ target: Target, current: Bool = false, onUpdated: ((IssueDetail) -> Void)? = nil) -> [MenuSpec] {
        let key = target.key
        var cached: IssueSummary? = nil
        if case .summary(let s) = target { cached = s }
        let full: () async throws -> IssueSummary = {
            if let cached { return cached }
            let s = try await Self.fetchSummary(key)
            cached = s
            return s
        }
        let summary: () async throws -> String = {
            if case .key(_, let s?) = target { return s }
            return try await full().summary
        }
        let url = "\(AppModel.shared.baseUrl(.jira))/browse/\(key)"
        let updated: (IssueDetail, String) -> Void = { detail, message in
            onUpdated?(detail)
            toast(message)
        }
        let copy: (@escaping () async throws -> String) -> @MainActor () -> Void = { text in
            { guarded {
                Pasteboard.copy(try await text())
                toast("已复制")
            } }
        }
        var specs: [MenuSpec] = []
        if !current {
            specs.append(.action("打开 \(key)", icon: "smallcircle.filled.circle") { AppModel.shared.navigate(NavTarget(.jira, issueKey: key)) })
            specs.append(.separator)
        }
        specs.append(.lazy("流转", icon: "arrow.left.arrow.right") { [weak self] in
            // 先发出请求，再在主线程上取问题信息，两者同时进行
            async let available = API.shared.jiraTransitions(key)
            let info = try await full()
            let list = try await available
            TemplateStore.shared.load()
            // 流转模板打开预先填好的对话框，确认后提交
            let usable = TemplateStore.shared.list.compactMap { tpl -> (JiraTemplate, Transition)? in
                guard tpl.kind == "transition", let t = list.first(where: { $0.name == tpl.transition }) else { return nil }
                return (tpl, t)
            }
            var items: [MenuSpec] = list.map { t in
                // 需要填写字段的流转打开对话框；其余确认后直接执行，避免误点
                t.fields.isEmpty
                    ? .item(t.name, confirm: "确认「\(t.name)」？") { guarded { updated(try await API.shared.jiraTransition(key, transitionId: t.id, fields: [:], comment: nil), "\(key) 已流转到「\(t.to.name)」") } }
                    : .action("\(t.name)…") { self?.transition = TransitionRequest(issue: info, transition: t, done: onUpdated) }
            }
            if !usable.isEmpty { items.append(.separator) }
            items += usable.map { tpl, t in .action("\(tpl.name)…", icon: "bolt") { self?.transition = TransitionRequest(issue: info, transition: t, template: tpl, done: onUpdated) } }
            return items
        })
        specs.append(.lazy("分配", icon: "person") { [weak self] in
            async let meTask = API.shared.jiraMe()
            let issue = try await full()
            let me = try await meTask
            return [
                .action("分配给我", disabled: issue.assigneeName == me) { guarded { updated(try await API.shared.jiraAssign(key, assignee: me), "\(key) 已分配给你") } },
                .action("分配给…") { self?.assigning = AssignRequest(issue: issue, done: onUpdated) },
                .separator,
                .action("取消分配", disabled: issue.assigneeName == nil) { guarded { updated(try await API.shared.jiraAssign(key, assignee: nil), "\(key) 已取消分配") } },
            ]
        })
        specs.append(.lazy("优先级", icon: "flag") {
            async let listTask = API.shared.jiraPriorities()
            let issue = try await full()
            let list = try await listTask
            return list.map { p in
                let isCurrent = issue.priority?.name == p.name
                return .action(p.name, checked: isCurrent) {
                    guard !isCurrent else { return }
                    guarded { updated(try await API.shared.jiraSetPriority(key, priorityId: p.id), "\(key) 优先级已改为「\(p.name)」") }
                }
            }
        })
        specs += [
            .separator,
            .action("复制问题键", icon: "doc.on.doc", copy { key }),
            .action("复制问题键和概要", copy { "\(key) \(try await summary())" }),
            .action("复制链接", icon: "link", copy { url }),
            .action("复制为 Markdown 链接", copy { "[\(key) \(try await summary())](\(url))" }),
            .separator,
            .action("添加待办", icon: "checkmark.square") {
                guarded {
                    try await TodoActions.addIssueTodo(key: key, summary: try await summary())
                    toast("已为 \(key) 添加待办")
                }
            },
            .action("写笔记", icon: "note.text") {
                guarded { AppModel.shared.navigate(NavTarget(.notes, docId: try await DocActions.createIssueNote(key: key, summary: try await summary()).id)) }
            },
            .action("沉淀到知识库", icon: "book") {
                guarded { AppModel.shared.navigate(NavTarget(.kb, docId: try await KBImport.issueToPage(key).id)) }
            },
            .separator,
            .action("在浏览器中打开", icon: "safari") { Links.openInBrowser(url) },
        ]
        return specs
    }
}

extension View {
    /// 问题菜单需要的对话框。
    func issueMenuDialogs(_ menu: IssueMenu) -> some View {
        modifier(IssueMenuDialogs(menu: menu))
    }
}

private struct IssueMenuDialogs: ViewModifier {
    @Bindable var menu: IssueMenu

    func body(content: Content) -> some View {
        content
            .sheet(item: $menu.transition) { req in
                TransitionSheet(issueKey: req.issue.key, transition: req.transition, issue: req.issue, template: req.template) { detail in
                    req.done?(detail)
                    toast("\(detail.key) 已流转到「\(detail.status.name)」")
                }
            }
            .sheet(item: $menu.assigning) { req in
                AssignSheet(key: req.issue.key, assignee: req.issue.assignee) { detail in
                    req.done?(detail)
                    toast("\(detail.key) 已分配给 \(detail.assignee ?? "未分配")")
                }
            }
    }
}

/// 状态流转对话框：根据流转界面上的字段动态生成表单。`template` 为预先选择的流转模板。
struct TransitionSheet: View {
    var issueKey: String
    var transition: Transition
    var issue: IssueSummary?
    var template: JiraTemplate?
    var onDone: (IssueDetail) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: FieldValues = [:]
    @State private var comment = ""
    @State private var visibility: CommentVisibility?
    @State private var applied: String?
    @State private var savingTemplate = false
    @State private var submitting = false
    @State private var problem: SubmitProblem?
    @State private var images: [PendingImage] = []
    @State private var store = TemplateStore.shared

    private func templateValues(_ t: JiraTemplate?) -> FieldValues {
        let keys = Set(transition.fields.map(\.key))
        return (t?.values ?? [:]).filter { keys.contains($0.key) }
    }

    private func fill(_ body: String) -> String { issue.map { JiraTemplate.fill(body, issue: $0) } ?? body }

    var body: some View {
        let templates = store.list.filter { $0.kind == "transition" && $0.transition == transition.name }
        let blocked = !FieldForm.unsupportedRequired(transition.fields).isEmpty
        let missing = FieldForm.missingRequired(transition.fields, values)
        DialogFrame(title: "\(issueKey) · \(transition.name)", width: 620, problem: problem) {
            HStack {
                Text("流转后状态：").foregroundStyle(.secondary)
                StatusPill(status: transition.to)
            }
            if !templates.isEmpty {
                HStack {
                    Text("模板").font(.caption).foregroundStyle(.secondary)
                    ForEach(templates) { t in
                        Button(t.name) {
                            values = templateValues(t)
                            comment = fill(t.body)
                            applied = t.id
                        }
                        .buttonStyle(.bordered)
                        .tint(applied == t.id ? .accentColor : nil)
                    }
                }
            }
            UnsupportedNotice(fields: transition.fields, issueKey: issueKey)
            FieldList(fields: transition.fields, values: $values, context: FieldContext(issueKey: issueKey, projectKey: JQL.projectKey(of: issueKey), onImage: { images.append($0) }), errors: problem?.fields ?? [:])
            VStack(alignment: .leading, spacing: 4) {
                Text("评论（可选）").font(.callout).foregroundStyle(.secondary)
                JiraTextEditor(text: $comment, issueKey: issueKey, onImage: { images.append($0) }, minHeight: 80)
                VisibilitySelect(issueKey: issueKey, value: $visibility)
            }
        } footer: {
            Button("存为模板") { savingTemplate = true }.help("保存这次填写的字段和评论，下次一键填好")
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(submitting ? "提交中…" : "确认\(transition.name)", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || !missing.isEmpty || blocked)
        }
        .onChange(of: values) { old, new in problem = problem?.clearing(from: old, to: new) }
        .onAppear {
            store.load()
            values = templateValues(template)
            comment = fill(template?.body ?? "")
            applied = template?.id
        }
        .sheet(isPresented: $savingTemplate) {
            SaveTemplateSheet(kind: "transition", body_: comment, transition: transition.name, values: values)
        }
    }

    private func submit() {
        submitting = true
        problem = nil
        Task {
            do {
                let payload = FieldForm.payload(transition.fields, values)
                let used = PendingImage.referenced(images, in: [comment] + payload.values.compactMap(\.string))
                if !used.isEmpty { _ = try await API.shared.jiraUploadAttachments(issueKey, paths: used.map(\.path)) }
                let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = try await API.shared.jiraTransition(issueKey, transitionId: transition.id, fields: payload, comment: trimmed.isEmpty ? nil : trimmed, visibility: visibility)
                onDone(detail)
                dismiss()
            } catch {
                guard !isCancellation(error) else { return }
                problem = FieldForm.problem(error, transition.fields)
                submitting = false
            }
        }
    }
}

/// 评论的可见范围（项目角色或用户组）；没有网页登录时不显示。
struct VisibilitySelect: View {
    var issueKey: String
    @Binding var value: CommentVisibility?
    @State private var levels: [CommentLevel] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 内容为空时也要执行 task
            Color.clear.frame(width: 0, height: 0)
            if !levels.isEmpty {
                Picker("", selection: Binding(get: { levels.firstIndex { $0.visibility == value } ?? -1 }, set: { value = $0 >= 0 ? levels[$0].visibility : nil })) {
                    Text("所有用户可见").tag(-1)
                    ForEach(levels.indices, id: \.self) { i in Text("仅 \(levels[i].label) 可见").tag(i) }
                }
                .labelsHidden()
                .fixedSize()
                .help("评论的可见范围")
            }
        }
        .task(id: issueKey) { levels = (try? await API.shared.jiraCommentLevels(issueKey)) ?? [] }
    }
}

/// 把问题分配给某个可分配的用户。
struct AssignSheet: View {
    var key: String
    var assignee: String?
    var onDone: (IssueDetail) -> Void

    // 分配对话框中的两个特殊选项；“自动”交给 Jira 按项目的默认经办人分配
    private static let unassigned = UserRef(name: "", displayName: "未分配")
    private static let automatic = UserRef(name: "-1", displayName: "自动")

    @Environment(\.dismiss) private var dismiss
    @State private var user: UserRef?
    @State private var busy = false
    @State private var error: String?
    @State private var suggested: [UserRef]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分配 \(key)").font(.headline)
            Text("当前经办人：\(assignee ?? "未分配")").font(.callout).foregroundStyle(.secondary)
            Text("分配给").font(.callout).foregroundStyle(.secondary)
            // 与网页一致：未输入时列出“建议”（最近分配过的人等），再加上“未分配”“自动”
            SearchPicker<UserRef>(
                selected: user.map { [$0] } ?? [],
                onChange: { user = $0.first },
                search: { q in
                    if !q.isEmpty { return try await API.shared.jiraFindUsers(q, field: "assignee", issueKey: key, projectKey: nil) }
                    if suggested == nil { suggested = (try? await API.shared.jiraSuggestedAssignees(key)) ?? [] }
                    return (suggested ?? []) + [Self.unassigned, Self.automatic]
                },
                label: { $0.displayName },
                detail: { $0 == Self.unassigned || $0 == Self.automatic ? "" : $0.name },
                placeholder: "输入姓名或用户名搜索",
                searchOnFocus: true,
                idleHeading: "建议"
            )
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "分配中…" : "分配") {
                    guard let user else { return }
                    busy = true
                    Task {
                        do {
                            onDone(try await API.shared.jiraAssign(key, assignee: user == Self.unassigned ? nil : user.name))
                            dismiss()
                        } catch {
                            guard !isCancellation(error) else { return }
                            self.error = errorMessage(error)
                            busy = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(user == nil || busy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
