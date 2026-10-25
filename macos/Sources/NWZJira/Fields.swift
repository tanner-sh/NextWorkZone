import Foundation
import NWZCore

public enum JiraFields {
    static let hidden: Set<String> = ["summary", "description", "status", "issuetype", "priority", "project", "comment", "attachment", "issuelinks", "subtasks", "parent", "resolution", "watches", "votes", "worklog", "timetracking", "lastViewed", "aggregateprogress", "progress", "aggregatetimespent", "aggregatetimeestimate", "aggregatetimeoriginalestimate", "timespent", "timeestimate", "timeoriginalestimate", "workratio", "thumbnail", "creator", "statuscategorychangedate", "environment"]
    static let systemOrder = ["assignee", "reporter", "created", "updated", "duedate", "resolutiondate", "fixVersions", "versions", "components", "labels"]
    static let alwaysShown: Set<String> = ["assignee", "reporter", "created", "updated", "resolutiondate"]
    public static func text(_ raw: JSONDocument) -> String {
        switch raw.value {
        case .null: return ""
        case .bool(let flag): return flag ? "是" : "否"
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .string(let value): return value
        case .array: return raw.list.map(text).filter { !$0.isEmpty }.joined(separator: "、")
        case .object:
            let own = ["displayName", "value", "name", "key"].compactMap { raw[$0].string }.first ?? ""
            let child = text(raw["child"])
            return child.isEmpty ? own : own + " / " + child
        }
    }
    static func formatMillis(_ milliseconds: Double) -> String {
        let minutes = max(0, min(Double(Int.max / 2), (milliseconds / 60_000).rounded()))
        let value = Int(minutes)
        let parts = [(value / 1440, "天"), (value % 1440 / 60, "小时"), (value % 60, "分")].filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
        return parts.isEmpty ? "0分" : parts.joined(separator: " ")
    }
    static func display(_ fields: JSONDocument, rendered: JSONDocument, names: JSONDocument, schema: JSONDocument, screen: [String]) -> [DisplayField] {
        var result: [(Int, Int, DisplayField)] = []
        for id in fields.keys where !hidden.contains(id) {
            let raw = fields[id], custom = schema[id]["custom"].text
            let html = rendered[id].string.flatMap { $0.contains("<") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0 : nil }
            let value = custom.contains("timespan") && raw.number != nil ? formatMillis(raw.number!) : text(raw)
            if value.isEmpty && html == nil { continue }
            let name = names[id].string ?? id
            if name == "Rank" || name.contains("WBSGantt") || value.hasPrefix("{") { continue }
            let position = screen.firstIndex(of: id), hidden = !screen.isEmpty && position == nil && !alwaysShown.contains(id)
            let group: Int, order: Int
            if hidden { group = 3; order = 0 }
            else if let index = systemOrder.firstIndex(of: id) { group = 0; order = index }
            else if let position { group = 1; order = position }
            else { group = id.hasPrefix("customfield_") ? 2 : 1; order = id.hasPrefix("customfield_") ? 0 : Int.max }
            result.append((group, order, DisplayField(id: id, name: name, text: value, html: html, issueKey: custom.hasSuffix("gh-epic-link") && !value.isEmpty ? value : nil, hidden: hidden)))
        }
        return result.sorted { ($0.0, $0.1, $0.2.name) < ($1.0, $1.1, $1.2.name) }.map(\.2)
    }
    public static func parse(_ raw: JSONDocument) -> [FieldMeta] { raw.keys.compactMap { field($0, raw[$0]) } }
    static func field(_ key: String, _ raw: JSONDocument) -> FieldMeta? {
        if ["project", "issuetype", "attachment", "comment", "issuelinks", "worklog"].contains(key) { return nil }
        let options = raw["allowedValues"].list.map(option), schema = raw["schema"]
        var kind = schema["custom"].string.map(customKind) ?? systemKind(key, schema["type"].text, !options.isEmpty)
        if ["select", "multiselect", "cascading"].contains(kind) && options.isEmpty { kind = "unsupported" }
        return FieldMeta(key: key, name: text(raw["name"]), required: raw["required"].bool ?? false, kind: kind, options: options, value: raw["hasDefaultValue"].bool == true ? formValue(kind, raw["defaultValue"]) : .null)
    }
    static func option(_ raw: JSONDocument) -> FieldOption {
        FieldOption(id: text(raw["id"]), name: ["value", "name", "displayName"].compactMap { raw[$0].string }.first ?? "", children: raw["children"].list.map(option), disabled: raw["disabled"].bool == true || raw["archived"].bool == true)
    }
    static func customKind(_ type: String) -> String {
        let parts = type.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "unsupported" }
        if parts[0] == "com.pyxis.greenhopper.jira" { return ["gh-epic-link":"epic", "gh-epic-label":"text"][parts[1]] ?? "unsupported" }
        guard parts[0] == "com.atlassian.jira.plugin.system.customfieldtypes" else { return "unsupported" }
        return ["textfield":"text", "url":"text", "textarea":"textarea", "float":"number", "datepicker":"date", "datetime":"datetime", "select":"select", "radiobuttons":"select", "version":"select", "multiselect":"multiselect", "multicheckboxes":"multiselect", "multiversion":"multiselect", "cascadingselect":"cascading", "userpicker":"user", "multiuserpicker":"multiuser", "labels":"labels"][parts[1]] ?? "unsupported"
    }
    static func systemKind(_ key: String, _ type: String, _ options: Bool) -> String {
        if let kind = ["summary":"text", "description":"textarea", "environment":"textarea", "labels":"labels", "timetracking":"timetracking", "parent":"parent", "duedate":"date", "assignee":"user", "reporter":"user"][key] { return kind }
        if options { return type == "array" ? "multiselect" : "select" }
        return ["string":"text", "number":"number", "date":"date", "datetime":"datetime", "user":"user"][type] ?? "unsupported"
    }
    static func formValue(_ kind: String, _ raw: JSONDocument) -> JSONValue {
        if raw.isNull { return .null }
        func user(_ value: JSONDocument) -> JSONValue { ["name": .string(text(value["name"])), "displayName": .string(text(value))] }
        let result: JSONValue
        switch kind {
        case "text", "textarea", "date", "number": result = .string(text(raw))
        case "datetime": result = .string(String(text(raw).prefix(16)))
        case "select": result = .string(text(raw["id"]))
        case "multiselect": result = .array(raw.list.map { .string(text($0["id"])) })
        case "cascading": result = .array([JSONValue.string(text(raw["id"]))] + (raw["child"].isObject ? [.string(text(raw["child"]["id"]))] : []))
        case "user": result = user(raw)
        case "multiuser": result = .array(raw.list.map(user))
        case "labels": result = .array(raw.list.map { .string(text($0)) })
        case "timetracking": result = .object(Dictionary(uniqueKeysWithValues: ["originalEstimate", "remainingEstimate"].compactMap { key in raw[key].string.map { (key, .string($0)) } }))
        case "epic": result = ["key": .string(text(raw)), "summary": ""]
        case "parent": result = ["key": .string(text(raw["key"])), "summary": .string(text(raw["fields"]["summary"]))]
        default: result = .null
        }
        if result.string == "" || result.array?.isEmpty == true || result.object?.isEmpty == true || result["key"]?.string == "" { return .null }
        return result
    }
    static func transitions(_ raw: JSONDocument) -> [Transition] {
        raw["transitions"].list.map { item in
            let fields = parse(item["fields"])
            return Transition(id: text(item["id"]), name: text(item["name"]), to: JiraStatus(raw: item["to"]), fields: fields.filter(\.required) + fields.filter { !$0.required })
        }
    }
}
