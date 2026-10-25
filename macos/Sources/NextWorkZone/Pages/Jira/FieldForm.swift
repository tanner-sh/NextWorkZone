import SwiftUI

/// 编辑、创建、流转界面共用的字段表单：按字段类型生成控件，并把表单取值转换为 Jira REST API 的格式。
/// 字段元数据（editmeta / createmeta）的读取见 NWZJira 的 `Fields.swift`。
typealias FieldValues = [String: JSONValue]

/// 搜索用户、问题时需要的上下文：编辑时是当前问题，创建时是所选项目。
struct FieldContext {
    var issueKey: String?
    var projectKey: String?
    /// 在多行文本中粘贴了图片
    var onImage: ((PendingImage) -> Void)?
}

/// 粘贴到编辑器、保存时才上传的图片。
struct PendingImage: Hashable {
    var filename: String
    var path: String

    /// 仍被文本引用的待上传文件（插入后又删掉的不再上传）。
    static func referenced(_ pending: [PendingImage], in texts: [String?]) -> [PendingImage] {
        let all = texts.compactMap { $0 }.joined(separator: "\n")
        return pending.filter { all.contains("!\($0.filename)") || all.contains("[^\($0.filename)]") }
    }
}

enum FieldForm {
    /// 占满整行的字段类型
    static let fullWidth: Set<String> = ["textarea", "multiselect", "multiuser", "labels", "timetracking"]

    static func initialValues(_ fields: [FieldMeta]) -> FieldValues {
        Dictionary(fields.map { ($0.key, $0.value ?? .null) }, uniquingKeysWith: { a, _ in a })
    }

    static func isEmpty(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        switch value {
        case .null: return true
        case .string(let s): return s.trimmingCharacters(in: .whitespaces).isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o):
            if let key = o["key"] { return (key.string ?? "").isEmpty }
            if let name = o["name"] { return (name.string ?? "").isEmpty }
            return o.values.allSatisfy { ($0.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        default: return false
        }
    }

    /// 可以在工作台中填写的字段；不支持的字段（多为插件自动计算的字段）不显示。
    static func editable(_ fields: [FieldMeta]) -> [FieldMeta] { fields.filter { $0.kind != "unsupported" } }

    static func missingRequired(_ fields: [FieldMeta], _ values: FieldValues) -> [FieldMeta] {
        editable(fields).filter { $0.required && isEmpty(values[$0.key]) }
    }

    static func unsupportedRequired(_ fields: [FieldMeta]) -> [FieldMeta] {
        fields.filter { $0.required && $0.kind == "unsupported" }
    }

    /// 按 Jira REST API 的要求构造字段取值。
    /// 传入 `initial`（编辑时的原值）时只包含有变化的字段，被清空的字段显式置空；否则跳过空字段。
    static func payload(_ fields: [FieldMeta], _ values: FieldValues, initial: FieldValues? = nil) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [:]
        for field in editable(fields) {
            let value = values[field.key]
            let before = initial?[field.key]
            if initial != nil && same(value, before) { continue }
            if isEmpty(value) {
                if initial != nil && !isEmpty(before) { payload[field.key] = ["multiselect", "multiuser", "labels"].contains(field.kind) ? .array([]) : .null }
                continue
            }
            guard let value else { continue }
            if field.kind == "timetracking", initial != nil {
                // 只提交改过的估算：未改动的值可能是本地化格式（如“1小时”），回传会被拒绝
                var changed: [String: JSONValue] = [:]
                for k in ["originalEstimate", "remainingEstimate"] where (value[k]?.string ?? "") != (before?[k]?.string ?? "") {
                    changed[k] = .string(value[k]?.string ?? "")
                }
                payload[field.key] = .object(changed)
                continue
            }
            payload[field.key] = jiraValue(field, value)
        }
        return payload
    }

    private static func jiraValue(_ field: FieldMeta, _ value: JSONValue) -> JSONValue {
        switch field.kind {
        case "number": return .number(Double(value.string ?? "") ?? value.number ?? 0)
        case "datetime": return .string(jiraDateTime(value.string ?? ""))
        case "select": return ["id": value]
        case "multiselect": return .array((value.array ?? []).map { ["id": $0] })
        case "cascading":
            let ids = value.array ?? []
            if ids.count > 1 { return ["id": ids[0], "child": ["id": ids[1]]] }
            return ["id": ids.first ?? .null]
        case "user": return ["name": value["name"] ?? .null]
        case "multiuser": return .array((value.array ?? []).map { ["name": $0["name"] ?? .null] })
        case "epic": return value["key"] ?? .null
        case "parent": return ["key": value["key"] ?? .null]
        case "timetracking":
            return .object((value.object ?? [:]).filter { !($0.value.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
        default: return value
        }
    }

    private static func same(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        if isEmpty(a) && isEmpty(b) { return true }
        return (a ?? .null) == (b ?? .null)
    }

    /// `2026-10-22T09:30`（本地时间）→ `2026-10-22T09:30:00.000+0800`
    static func jiraDateTime(_ local: String) -> String {
        let offset = TimeZone.current.secondsFromGMT() / 60
        let sign = offset >= 0 ? "+" : "-"
        return "\(local.prefix(16)):00.000\(sign)\(String(format: "%02d%02d", abs(offset) / 60, abs(offset) % 60))"
    }

    /// 把 Jira 错误信息中的字段 id（如 customfield_10002）替换为字段名称。
    static func explain(_ message: String, _ fields: [FieldMeta]) -> String {
        fields.reduce(message) { $0.replacingOccurrences(of: "\($1.key)：", with: "\($1.name)：") }
    }
}

// MARK: - 表单

struct FieldList: View {
    var fields: [FieldMeta]
    @Binding var values: FieldValues
    var context: FieldContext

    var body: some View {
        let list = FieldForm.editable(fields)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(list) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        Text(field.name).font(.callout).foregroundStyle(.secondary)
                        if field.required { Text("*").foregroundStyle(.red) }
                    }
                    FieldInput(field: field, value: Binding(get: { values[field.key] ?? .null }, set: { values[field.key] = $0 }), context: context)
                }
            }
        }
    }
}

struct FieldInput: View {
    var field: FieldMeta
    @Binding var value: JSONValue
    var context: FieldContext

    private var str: Binding<String> {
        Binding(get: { value.string ?? "" }, set: { value = .string($0) })
    }

    var body: some View {
        switch field.kind {
        case "text":
            TextField("", text: str).textFieldStyle(.roundedBorder)
        case "textarea":
            JiraTextEditor(text: str, issueKey: context.issueKey, onImage: context.onImage, minHeight: field.key == "description" ? 180 : 80)
        case "number":
            TextField("", text: str).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
        case "date":
            OptionalDatePicker(day: Binding(get: { (value.string ?? "").isEmpty ? nil : value.string }, set: { value = $0.map { .string($0) } ?? .null }))
        case "datetime":
            DateTimeField(value: str)
        case "select":
            OptionSelect(options: field.options, value: Binding(get: { value.string }, set: { value = $0.map { .string($0) } ?? .null }))
        case "multiselect":
            let ids = (value.array ?? []).compactMap(\.string)
            let byId = Dictionary(field.options.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            SearchPicker<FieldOption>(
                selected: ids.map { byId[$0] ?? FieldOption(id: $0, name: $0, children: nil, disabled: true) },
                onChange: { value = .array($0.map { .string($0.id) }) },
                search: { q in field.options.filter { !$0.disabled && Self.matches($0.name, q) } },
                label: { $0.name },
                placeholder: "输入以搜索",
                multiple: true,
                searchOnFocus: true
            )
        case "cascading":
            let ids = (value.array ?? []).compactMap(\.string)
            let parent = field.options.first { $0.id == ids.first }
            HStack {
                OptionSelect(options: field.options, value: Binding(get: { ids.first }, set: { value = $0.map { .array([.string($0)]) } ?? .null }))
                if let children = parent?.children, !children.isEmpty {
                    OptionSelect(options: children, value: Binding(get: { ids.count > 1 ? ids[1] : nil }, set: { child in
                        guard let p = ids.first else { return }
                        value = .array([.string(p)] + (child.map { [.string($0)] } ?? []))
                    }))
                }
            }
        case "user", "multiuser":
            let multiple = field.kind == "multiuser"
            let users: [UserRef] = multiple ? ((value.array ?? []).compactMap { $0.decode(UserRef.self) }) : (value.decode(UserRef.self).map { [$0] } ?? [])
            SearchPicker<UserRef>(
                selected: users,
                onChange: { list in value = multiple ? .array(list.map { JSONValue.from($0) }) : (list.first.map { JSONValue.from($0) } ?? .null) },
                search: { q in q.isEmpty ? [] : try await API.shared.jiraFindUsers(q, field: field.key, issueKey: context.issueKey, projectKey: context.projectKey) },
                label: { $0.displayName },
                detail: { $0.name },
                placeholder: "输入姓名或用户名搜索",
                multiple: multiple
            )
        case "labels":
            SearchPicker<String>(
                selected: (value.array ?? []).compactMap(\.string),
                onChange: { value = .array($0.map { .string($0) }) },
                search: { q in try await API.shared.jiraSuggestLabels(q) },
                label: { $0 },
                placeholder: "输入标签，回车添加（不能含空格）",
                multiple: true,
                allowCustom: { $0.contains(" ") ? $0.replacingOccurrences(of: " ", with: "") : $0 }
            )
        case "timetracking":
            HStack {
                TextField("初始估算，例如 2d 4h", text: Binding(get: { value["originalEstimate"]?.string ?? "" }, set: { set("originalEstimate", $0) })).textFieldStyle(.roundedBorder)
                TextField("剩余估算，例如 1d", text: Binding(get: { value["remainingEstimate"]?.string ?? "" }, set: { set("remainingEstimate", $0) })).textFieldStyle(.roundedBorder)
            }
        case "epic", "parent":
            let choice = value.decode(IssueChoice.self)
            SearchPicker<IssueChoice>(
                selected: choice.map { [$0] } ?? [],
                onChange: { list in value = list.first.map { JSONValue.from($0) } ?? .null },
                search: { q in
                    if field.kind == "epic" {
                        guard let p = context.projectKey else { return [] }
                        return try await API.shared.jiraSearchEpics(q, projectKey: p).map { IssueChoice(key: $0.key, summary: $0.summary) }
                    }
                    if q.isEmpty { return [] }
                    return try await API.shared.jiraPickIssues(q, projectKey: context.projectKey, standardOnly: true).map { IssueChoice(key: $0.key, summary: $0.summary) }
                },
                label: { $0.summary.isEmpty ? $0.key : "\($0.key) \($0.summary)" },
                placeholder: field.kind == "epic" ? "搜索 Epic 名称" : "输入问题键或概要搜索",
                searchOnFocus: field.kind == "epic"
            )
        default:
            EmptyView()
        }
    }

    private func set(_ key: String, _ v: String) {
        var o = value.object ?? [:]
        o[key] = .string(v)
        value = .object(o)
    }

    static func matches(_ text: String, _ query: String) -> Bool {
        query.isEmpty || text.lowercased().contains(query.lowercased())
    }
}

/// 日期时间（本地时间，`YYYY-MM-DDTHH:mm`）。
private struct DateTimeField: View {
    @Binding var value: String

    var body: some View {
        if let date = Self.parse(value) {
            DatePicker("", selection: Binding(get: { date }, set: { value = Self.format($0) }), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.field)
        } else {
            Button("设置时间") { value = Self.format(Date()) }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    static func parse(_ s: String) -> Date? { s.count >= 16 ? formatter.date(from: String(s.prefix(16))) : nil }
    static func format(_ d: Date) -> String { formatter.string(from: d) }
}

/// 单选：选项少时用下拉框，选项多时用可搜索的选择器。
struct OptionSelect: View {
    var options: [FieldOption]
    @Binding var value: String?

    var body: some View {
        let visible = options.filter { !$0.disabled || $0.id == value }
        if visible.count <= 12 {
            Picker("", selection: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 })) {
                Text("请选择").tag("")
                ForEach(visible) { o in Text(o.name).tag(o.id) }
            }
            .labelsHidden()
            .fixedSize()
        } else {
            let selected = options.first { $0.id == value }
            SearchPicker<FieldOption>(
                selected: selected.map { [$0] } ?? [],
                onChange: { value = $0.first?.id },
                search: { q in visible.filter { !$0.disabled && FieldInput.matches($0.name, q) } },
                label: { $0.name },
                searchOnFocus: true
            )
        }
    }
}

/// 表单底部的提示：必填但不支持的字段需要到网页处理。
struct UnsupportedNotice: View {
    var fields: [FieldMeta]
    var issueKey: String?

    var body: some View {
        let blocked = FieldForm.unsupportedRequired(fields)
        if !blocked.isEmpty {
            HStack(spacing: 4) {
                Text("必填字段「\(blocked.map(\.name).joined(separator: "、"))」暂不支持在工作台中填写，").foregroundStyle(.red)
                Button("请在网页中处理。") {
                    let base = AppModel.shared.baseUrl(.jira)
                    Links.openInBrowser(issueKey.map { "\(base)/browse/\($0)" } ?? base)
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
    }
}
