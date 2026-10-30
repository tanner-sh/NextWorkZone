import SwiftUI

/// Jira 评论模板、流转模板。保存在工作空间中（随工作空间同步到其他设备），内容为 JSON。与 src/lib/templates.ts 相同。
struct JiraTemplate: Identifiable, Hashable {
    var id: String
    var name: String
    /// comment / transition
    var kind: String
    /// 评论内容（wiki 标记），可包含变量
    var body: String
    /// 流转模板：流转的名称（不同项目的工作流中 id 不同，按名称匹配）
    var transition: String?
    /// 流转模板：流转界面上的字段值
    var values: FieldValues?

    private struct Content: Codable {
        var kind: String
        var body: String
        var transition: String?
        var values: FieldValues?
    }

    static let docKind = "jira-template"

    /// 模板中可用的变量。
    static let variables = [("{key}", "问题键"), ("{summary}", "概要"), ("{reporter}", "提及报告人"), ("{assignee}", "经办人"), ("{today}", "今天的日期")]
    static var variablesText: String { variables.map { "\($0.0) \($0.1)" }.joined(separator: "、") }

    static func load() async throws -> [JiraTemplate] {
        try await API.shared.wsFullDocs(docKind).compactMap { d in
            guard let c = try? JSONDecoder().decode(Content.self, from: Data(d.content.utf8)) else { return nil }
            return JiraTemplate(id: d.id, name: d.title, kind: c.kind, body: c.body, transition: c.transition, values: c.values)
        }
    }

    @MainActor
    static func save(id: String?, name: String, kind: String, body: String, transition: String?, values: FieldValues?) async throws {
        let content = Content(kind: kind, body: body, transition: transition, values: values)
        let text = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        _ = try await API.shared.wsSaveDoc(DocInput(id: id, kind: docKind, title: name, content: text))
        Events.workspaceChanged()
    }

    @MainActor
    static func delete(_ id: String) async throws {
        _ = try await API.shared.wsDeleteDoc(id)
        Events.workspaceChanged()
    }

    /// 把模板中的变量替换为当前问题的内容。
    static func fill(_ body: String, key: String, summary: String, reporter: String?, reporterName: String?, assignee: String?) -> String {
        let vars = ["{key}": key, "{summary}": summary, "{reporter}": reporterName.map { "[~\($0)]" } ?? (reporter ?? ""), "{assignee}": assignee ?? "", "{today}": Fmt.today()]
        return body.replacing(/\{(key|summary|reporter|assignee|today)\}/) { m in vars[String(m.0)] ?? String(m.0) }
    }

    static func fill(_ body: String, issue: IssueSummary) -> String {
        fill(body, key: issue.key, summary: issue.summary, reporter: issue.reporter, reporterName: issue.reporterName, assignee: issue.assignee)
    }
}

/// 全部模板，工作空间数据变化（包括其他设备同步过来）时刷新。
@MainActor @Observable
final class TemplateStore {
    static let shared = TemplateStore()
    var list: [JiraTemplate] = []
    private var observing = false

    func load() {
        if !observing {
            observing = true
            for name in [AppEvent.workspaceSynced, Events.local.workspaceChanged] {
                NotificationCenter.default.addObserver(forName: Events.name(name), object: nil, queue: .main) { _ in
                    Task { @MainActor in TemplateStore.shared.reload() }
                }
            }
        }
        reload()
    }

    private func reload() {
        Task { if let l = try? await JiraTemplate.load() { list = l } }
    }
}

/// 给模板起名并保存。
struct SaveTemplateSheet: View {
    var kind: String
    var body_: String
    var transition: String?
    var values: FieldValues?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == "transition" ? "保存流转模板" : "保存评论模板").font(.headline)
            TextField("例如：已修复请验证", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if kind == "transition" {
                Text("保存「\(transition ?? "")」流转时填写的 \(values?.count ?? 0) 个字段\(body_.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "和评论")。之后在问题详情或右键菜单中选择这个模板，会打开流转对话框并预先填好，确认后提交。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("评论框的“模板”按钮中可以插入。").font(.callout).foregroundStyle(.secondary)
            }
            Text("内容中可以使用变量：\(JiraTemplate.variablesText)。").font(.callout).foregroundStyle(.secondary)
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { name = transition ?? "" }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        busy = true
        Task {
            do {
                try await JiraTemplate.save(id: nil, name: n, kind: kind, body: body_, transition: transition, values: values)
                toast("已保存模板“\(n)”")
                dismiss()
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
                busy = false
            }
        }
    }
}

/// 管理模板：修改名称和内容、删除。
struct ManageTemplatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = TemplateStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jira 模板").font(.headline)
            Text("评论模板在评论框的“模板”按钮中插入；流转模板在流转对话框中保存，之后可从问题详情、右键菜单一键打开。模板随工作空间同步到其他设备。可用变量：\(JiraTemplate.variablesText)。")
                .font(.callout).foregroundStyle(.secondary)
            if store.list.isEmpty { Text("还没有模板").foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.list) { t in TemplateRow(template: t) }
                }
            }
            .frame(maxHeight: 480)
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear { store.load() }
    }

    private struct TemplateRow: View {
        var template: JiraTemplate
        @State private var name = ""
        @State private var body_ = ""
        @State private var error: String?

        var body: some View {
            let dirty = name != template.name || body_ != template.body
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("模板名称", text: $name).textFieldStyle(.roundedBorder)
                    Chip(text: template.kind == "transition" ? "流转：\(template.transition ?? "")" : "评论")
                    if dirty {
                        Button("保存") {
                            run { try await JiraTemplate.save(id: template.id, name: name.trimmingCharacters(in: .whitespaces), kind: template.kind, body: body_, transition: template.transition, values: template.values) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("删除", systemImage: "trash") {
                        Confirm.ask("删除模板“\(template.name)”？") { run { try await JiraTemplate.delete(template.id) } }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                TextEditor(text: $body_).font(.body).frame(height: 64).padding(4).fieldBackground()
                if template.kind == "transition", let n = template.values?.count, n > 0 {
                    Text("另含 \(n) 个字段值（重新保存流转模板可更新）").font(.caption).foregroundStyle(.secondary)
                }
                if let error { ErrorBox(message: error) }
            }
            .onAppear { name = template.name; body_ = template.body }
            .onChange(of: template) { _, t in name = t.name; body_ = t.body }
        }

        private func run(_ action: @escaping () async throws -> Void) {
            Task {
                do { try await action(); error = nil } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            }
        }
    }
}

/// 评论框旁的“模板”按钮：插入评论模板、把当前内容存为模板、管理模板。
struct CommentTemplateButton: View {
    var issue: IssueSummary
    var draft: String
    var onInsert: (String) -> Void
    @State private var store = TemplateStore.shared
    @State private var saving = false
    @State private var managing = false

    var body: some View {
        Button("模板", systemImage: "list.clipboard") {
            let comments = store.list.filter { $0.kind == "comment" }
            var specs: [MenuSpec] = []
            if !comments.isEmpty {
                specs.append(.label("插入模板"))
                specs += comments.map { t in .action(t.name) { onInsert(JiraTemplate.fill(t.body, issue: issue)) } }
                specs.append(.separator)
            }
            specs.append(.action("把当前内容存为模板…", icon: "plus", disabled: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { saving = true })
            specs.append(.action("管理模板…") { managing = true })
            MenuBuilder.popUp(specs)
        }
        .onAppear { store.load() }
        .sheet(isPresented: $saving) { SaveTemplateSheet(kind: "comment", body_: draft) }
        .sheet(isPresented: $managing) { ManageTemplatesSheet() }
    }
}
