import AppKit
import SwiftUI

/// 编辑问题：字段来自问题的编辑界面（editmeta），只提交改动过的字段。
struct EditIssueSheet: View {
    var issueKey: String
    var onDone: (IssueDetail) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [FieldMeta]?
    @State private var initial: FieldValues = [:]
    @State private var values: FieldValues = [:]
    @State private var loadError: String?
    @State private var saving = false
    @State private var error: String?
    @State private var images: [PendingImage] = []

    var body: some View {
        let changes = fields.map { FieldForm.payload($0, values, initial: initial) } ?? [:]
        let missing = fields.map { FieldForm.missingRequired($0, values) } ?? []
        DialogFrame(title: "编辑 \(issueKey)", width: 720) {
            if let loadError { ErrorBox(message: loadError) { Task { await load() } } }
            if fields == nil && loadError == nil { LoadingView().frame(height: 200) }
            if let fields {
                // 必填但无法编辑的字段并不妨碍修改其他字段，这里只做提示
                UnsupportedNotice(fields: fields, issueKey: issueKey)
                FieldList(fields: fields, values: $values, context: FieldContext(issueKey: issueKey, projectKey: JQL.projectKey(of: issueKey), onImage: { images.append($0) }))
            }
            if let error { ErrorBox(message: error) }
        } footer: {
            if !changes.isEmpty { Text("已修改 \(changes.count) 个字段").font(.caption).foregroundStyle(.secondary) }
            if !missing.isEmpty { Text("请填写：\(missing.map(\.name).joined(separator: "、"))").font(.caption).foregroundStyle(.red) }
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(saving ? "保存中…" : "保存") { save(changes) }.keyboardShortcut(.defaultAction).disabled(fields == nil || saving || !missing.isEmpty)
        }
        .interactiveDismissDisabled(!changes.isEmpty)
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            let meta = try await API.shared.jiraEditFields(issueKey)
            fields = meta
            initial = FieldForm.initialValues(meta)
            values = initial
        } catch {
            guard !isCancellation(error) else { return }
            loadError = errorMessage(error)
        }
    }

    private func save(_ changes: [String: JSONValue]) {
        guard let fields else { return }
        if changes.isEmpty { dismiss(); return }
        saving = true
        error = nil
        Task {
            do {
                // 先上传正文中引用的粘贴图片，保存后 !文件名! 才能显示
                let used = PendingImage.referenced(images, in: changes.values.compactMap(\.string))
                if !used.isEmpty { _ = try await API.shared.jiraUploadAttachments(issueKey, paths: used.map(\.path)) }
                onDone(try await API.shared.jiraUpdateIssue(issueKey, fields: changes))
                dismiss()
            } catch {
                guard !isCancellation(error) else { return }
                self.error = FieldForm.explain(errorMessage(error), fields)
                saving = false
            }
        }
    }
}

/// 新建问题。字段随所选项目和问题类型的创建界面动态生成。
/// 传入 `parent` 时创建该问题的子任务：项目固定，只能选择子任务类型。
struct CreateIssueSheet: View {
    var parent: IssueRef? = nil
    /// 预先填好的概要和描述（例如从待办、笔记创建）
    var initialSummary = ""
    var initialDescription = ""
    /// 从已有问题出发：克隆（复制字段并加“克隆”链接），或创建与它链接的问题
    var source: Source? = nil
    var onCreated: (String) -> Void

    enum Source {
        case clone(IssueDetail)
        case linked(IssueDetail)
        var issue: IssueDetail { switch self { case .clone(let i), .linked(let i): i } }
    }

    private static let lastKey = "nextworkzone.jira.lastCreate"

    @Environment(\.dismiss) private var dismiss
    @State private var projects: [CreateProject]?
    @State private var projectsError: String?
    @State private var projectKey: String?
    @State private var issueTypeId: String?
    @State private var fields: [FieldMeta]?
    @State private var fieldsError: String?
    @State private var values: FieldValues = [:]
    @State private var files: [String] = []
    @State private var images: [PendingImage] = []
    @State private var submitting = false
    @State private var error: String?
    /// 克隆时源问题的字段值
    @State private var sourceValues: FieldValues?
    @State private var linkTypes: [LinkType]?
    @State private var relation: LinkRelation?

    init(parent: IssueRef? = nil, initialSummary: String = "", initialDescription: String = "", source: Source? = nil, onCreated: @escaping (String) -> Void) {
        self.parent = parent
        self.initialSummary = initialSummary
        self.initialDescription = initialDescription
        self.source = source
        self.onCreated = onCreated
    }

    private var title: String {
        switch source {
        case .clone(let i): "克隆 \(i.key)"
        case .linked(let i): "创建与 \(i.key) 链接的问题"
        case nil: parent.map { "为 \($0.key) 新建子任务" } ?? "新建问题"
        }
    }

    private var project: CreateProject? { projects?.first { $0.key == projectKey } }
    private var isLinked: Bool { if case .linked = source { true } else { false } }
    private var issueTypes: [CreateIssueType] { project?.issueTypes.filter { $0.subtask == (parent != nil) } ?? [] }

    var body: some View {
        let missing = fields.map { FieldForm.missingRequired($0, values) } ?? []
        let blocked = fields.map { !FieldForm.unsupportedRequired($0).isEmpty } ?? false
        DialogFrame(title: title, width: 720) {
            if let projectsError, projects == nil { ErrorBox(message: projectsError) }
            if case .linked(let i) = source {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(i.key) 与新问题的关系").font(.callout).foregroundStyle(.secondary)
                    SearchPicker<LinkRelation>(selected: relation.map { [$0] } ?? [], onChange: { relation = $0.first }, search: { q in LinkRelation.all(linkTypes ?? []).filter { q.isEmpty || $0.label.lowercased().contains(q.lowercased()) } }, label: { $0.label }, detail: { $0.typeName }, placeholder: linkTypes == nil ? "正在加载链接类型…" : "搜索关系，例如“阻塞”", searchOnFocus: true, sourceVersion: linkTypes?.count ?? -1)
                }
            }
            if case .clone = source {
                Text("复制原问题的字段（不含附件和评论），创建后与原问题建立“克隆”链接。").font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label { Text("项目") } icon: { Text("*").foregroundStyle(.red) }.labelStyle(.titleOnly).font(.callout).foregroundStyle(.secondary)
                    if parent != nil {
                        Text(project.map { "\($0.name)（\($0.key)）" } ?? (projectKey ?? "")).foregroundStyle(.secondary)
                    } else {
                        SearchPicker<CreateProject>(
                            selected: project.map { [$0] } ?? [],
                            onChange: { projectKey = $0.first?.key },
                            search: { q in (projects ?? []).filter { "\($0.key) \($0.name)".lowercased().contains(q.lowercased()) || q.isEmpty } },
                            label: { "\($0.name)（\($0.key)）" },
                            placeholder: projects == nil ? "正在加载项目…" : "搜索项目名称或键",
                            searchOnFocus: true,
                            sourceVersion: projects?.count ?? -1
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("问题类型").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        SysImage(service: .jira, src: issueTypes.first { $0.id == issueTypeId }?.iconUrl, size: 16)
                        Picker("", selection: Binding(get: { issueTypeId ?? "" }, set: { issueTypeId = $0 })) {
                            if issueTypes.isEmpty { Text(project == nil ? "请先选择项目" : "该项目没有可用的类型").tag("") }
                            ForEach(issueTypes) { t in Text(t.name).tag(t.id) }
                        }
                        .labelsHidden()
                        .disabled(issueTypes.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let fieldsError { ErrorBox(message: fieldsError) }
            if projectKey != nil && issueTypeId != nil && fields == nil && fieldsError == nil { LoadingView().frame(height: 160) }
            if let fields {
                UnsupportedNotice(fields: fields)
                FieldList(fields: fields, values: $values, context: FieldContext(issueKey: nil, projectKey: projectKey, onImage: { images.append($0) }))
                // 附件在问题创建成功后再上传
                VStack(alignment: .leading, spacing: 4) {
                    Text("附件").font(.callout).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(files, id: \.self) { path in
                            HStack(spacing: 3) {
                                Text((path as NSString).lastPathComponent)
                                Button { files.removeAll { $0 == path } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3).chipBackground()
                            .help(path)
                        }
                        Button("选择文件", systemImage: "paperclip") {
                            for p in FilePicker.pick() where !files.contains(p) { files.append(p) }
                        }
                    }
                }
            }
            if let error { ErrorBox(message: error) }
        } footer: {
            if !missing.isEmpty { Text("请填写：\(missing.map(\.name).joined(separator: "、"))").font(.caption).foregroundStyle(.red) }
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(submitting ? "创建中…" : "创建", action: submit).keyboardShortcut(.defaultAction).disabled(fields == nil || submitting || !missing.isEmpty || blocked || (isLinked && relation == nil))
        }
        .task {
            if projectKey == nil {
                projectKey = parent.map { JQL.projectKey(of: $0.key) } ?? source.map { JQL.projectKey(of: $0.issue.key) } ?? AppPreferences.shared.dictionary(forKey: Self.lastKey)?["project"] as? String
            }
            if source != nil {
                async let types = try? API.shared.jiraLinkTypes()
                if case .clone(let i) = source, let meta = try? await API.shared.jiraEditFields(i.key) { sourceValues = FieldForm.initialValues(meta) }
                linkTypes = await types ?? []
                if case .linked = source { relation = LinkRelation.all(linkTypes ?? []).first }
            }
            if let cached = try? await API.shared.jiraCachedCreateProjects(), projects == nil { projects = cached }
            do { projects = try await API.shared.jiraCreateProjects() } catch { if !isCancellation(error) { projectsError = errorMessage(error) } }
            chooseType()
        }
        .onChange(of: projectKey) { chooseType() }
        .task(id: "\(projectKey ?? "")|\(issueTypeId ?? "")|\(sourceValues?.count ?? -1)") { await loadFields() }
    }

    /// 项目变化后选择问题类型：优先沿用上次的类型。
    private func chooseType() {
        guard !issueTypes.isEmpty else { return }
        if let current = issueTypeId, issueTypes.contains(where: { $0.id == current }) { return }
        // 克隆、创建链接的问题时沿用原问题的类型
        if let name = source?.issue.issueType.name, let t = issueTypes.first(where: { $0.name == name }) {
            issueTypeId = t.id
            return
        }
        let last = AppPreferences.shared.dictionary(forKey: Self.lastKey)?["issueType"] as? String
        issueTypeId = issueTypes.first { $0.id == last }?.id ?? issueTypes[0].id
    }

    private func loadFields() async {
        guard let projectKey, let issueTypeId else { return }
        fields = nil
        fieldsError = nil
        do {
            let meta = try await API.shared.jiraCreateFields(projectKey: projectKey, issueTypeId: issueTypeId)
            // 切换问题类型时保留已填写的内容
            var next = FieldForm.initialValues(meta)
            for f in meta where !FieldForm.isEmpty(values[f.key]) { next[f.key] = values[f.key] }
            if let parent, meta.contains(where: { $0.key == "parent" }) { next["parent"] = ["key": .string(parent.key), "summary": .string(parent.summary)] }
            if FieldForm.isEmpty(next["summary"]), !initialSummary.isEmpty, meta.contains(where: { $0.key == "summary" }) { next["summary"] = .string(initialSummary) }
            if FieldForm.isEmpty(next["description"]), !initialDescription.isEmpty, meta.contains(where: { $0.key == "description" }) { next["description"] = .string(initialDescription) }
            if case .clone(let i) = source, let sourceValues {
                for f in meta where !["attachment", "issuelinks", "comment", "worklog", "parent", "project", "issuetype"].contains(f.key) && !FieldForm.isEmpty(sourceValues[f.key]) {
                    next[f.key] = sourceValues[f.key]
                }
                next["summary"] = .string("克隆 - \(i.summary)")
            }
            fields = meta
            values = next
        } catch {
            guard !isCancellation(error) else { return }
            fieldsError = errorMessage(error)
        }
    }

    private func submit() {
        guard let fields, let projectKey, let issueTypeId else { return }
        submitting = true
        error = nil
        Task {
            do {
                var payload = FieldForm.payload(fields, values)
                let pasted = PendingImage.referenced(images, in: payload.values.compactMap(\.string)).map(\.path)
                payload["project"] = ["key": .string(projectKey)]
                payload["issuetype"] = ["id": .string(issueTypeId)]
                // 正文中粘贴的图片随附件一起在创建后上传
                let created = try await API.shared.jiraCreateIssue(fields: payload, attachments: files + pasted)
                AppPreferences.shared.set(["project": projectKey, "issueType": issueTypeId], forKey: Self.lastKey)
                var linkError: String?
                do {
                    switch source {
                    case .linked(let i):
                        if let relation { _ = try await API.shared.jiraAddLink(i.key, typeId: relation.typeId, other: created.key, outward: relation.outward) }
                    case .clone(let i):
                        // 与网页一致：新问题“克隆”原问题（找不到这种链接类型时不加）
                        if let t = linkTypes?.first(where: { $0.name.lowercased() == "cloners" || $0.outward.lowercased() == "clones" }) {
                            _ = try await API.shared.jiraAddLink(created.key, typeId: t.id, other: i.key, outward: true)
                        }
                    case nil: break
                    }
                } catch { linkError = errorMessage(error) }
                if let warn = created.attachmentError { toast("已创建 \(created.key)，但附件上传失败：\(warn)", error: true) }
                else if let linkError { toast("已创建 \(created.key)，但添加链接失败：\(linkError)", error: true) }
                else { toast("已创建 \(created.key)") }
                onCreated(created.key)
                dismiss()
            } catch {
                guard !isCancellation(error) else { return }
                self.error = FieldForm.explain(errorMessage(error), fields)
                submitting = false
            }
        }
    }
}

/// 对话框的通用布局：标题、可滚动的内容、底部按钮。
struct DialogFrame<Content: View, Footer: View>: View {
    var title: String
    var width: CGFloat = 520
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) { footer() }.padding(14)
        }
        .frame(width: width)
        .frame(minHeight: 260, idealHeight: 640, maxHeight: 820)
    }
}

/// 选择文件（打开面板）。
@MainActor
enum FilePicker {
    static func pick(multiple: Bool = true) -> [String] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    static func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
