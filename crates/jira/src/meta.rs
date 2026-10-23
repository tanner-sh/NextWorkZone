//! 字段元数据（editmeta / createmeta / 流转界面）的解析：判断每个字段该用什么控件编辑，
//! 并把字段的当前值或默认值转换成前端表单使用的形式。
//!
//! 表单取值的形式（与前端 `fieldForm.tsx` 对应）：
//! - `text` / `textarea` / `number` / `date` / `datetime`：字符串（日期时间为 `YYYY-MM-DDTHH:MM`）
//! - `select`：选项 id；`multiselect`：选项 id 数组；`cascading`：`[父选项 id, 子选项 id?]`
//! - `user`：`{ name, displayName }`；`multiuser`：其数组；`labels`：字符串数组
//! - `timetracking`：`{ originalEstimate, remainingEstimate }`
//! - `epic` / `parent`：`{ key, summary }`

use serde_json::{Map, Value, json};

use crate::fields::value_text;
use crate::model::{FieldMeta, FieldOption};

/// 由界面上的其他部分单独处理的字段：创建时的项目和问题类型、附件、评论等。
const SEPARATELY_HANDLED: &[&str] =
    &["project", "issuetype", "attachment", "comment", "issuelinks", "worklog"];

/// Jira 自带的自定义字段类型（`com.atlassian.jira.plugin.system.customfieldtypes:*`）对应的控件。
/// 第三方插件的字段类型无法通用地编辑（多为自动计算的字段），归为 `unsupported`。
fn custom_kind(custom: &str) -> &'static str {
    let Some((plugin, name)) = custom.split_once(':') else { return "unsupported" };
    match (plugin, name) {
        ("com.atlassian.jira.plugin.system.customfieldtypes", name) => match name {
            "textfield" | "url" => "text",
            "textarea" => "textarea",
            "float" => "number",
            "datepicker" => "date",
            "datetime" => "datetime",
            "select" | "radiobuttons" | "version" => "select",
            "multiselect" | "multicheckboxes" | "multiversion" => "multiselect",
            "cascadingselect" => "cascading",
            "userpicker" => "user",
            "multiuserpicker" => "multiuser",
            "labels" => "labels",
            _ => "unsupported",
        },
        // Jira Software（敏捷）插件的 Epic 字段
        ("com.pyxis.greenhopper.jira", "gh-epic-link") => "epic",
        ("com.pyxis.greenhopper.jira", "gh-epic-label") => "text",
        _ => "unsupported",
    }
}

fn system_kind(key: &str, schema_type: &str, has_options: bool) -> &'static str {
    match key {
        "summary" => "text",
        "description" | "environment" => "textarea",
        "labels" => "labels",
        "timetracking" => "timetracking",
        "parent" => "parent",
        "duedate" => "date",
        "assignee" | "reporter" => "user",
        _ if has_options => if schema_type == "array" { "multiselect" } else { "select" },
        _ => match schema_type {
            "string" => "text",
            "number" => "number",
            "date" => "date",
            "datetime" => "datetime",
            "user" => "user",
            _ => "unsupported",
        },
    }
}

/// 解析一个字段的元数据；由界面其他部分单独处理的字段返回 `None`。
pub(crate) fn parse_field(key: &str, meta: &Value) -> Option<FieldMeta> {
    if SEPARATELY_HANDLED.contains(&key) {
        return None;
    }
    let schema = &meta["schema"];
    let options: Vec<FieldOption> = meta["allowedValues"]
        .as_array()
        .into_iter()
        .flatten()
        .map(parse_option)
        .collect();
    let kind = match schema["custom"].as_str() {
        Some(custom) => custom_kind(custom),
        None => system_kind(key, schema["type"].as_str().unwrap_or_default(), !options.is_empty()),
    };
    // 选择类字段却没有可选项时无法填写
    let kind = if matches!(kind, "select" | "multiselect" | "cascading") && options.is_empty() {
        "unsupported"
    } else {
        kind
    };
    let default = if meta["hasDefaultValue"].as_bool().unwrap_or(false) {
        form_value(kind, &meta["defaultValue"])
    } else {
        Value::Null
    };
    Some(FieldMeta {
        key: key.to_string(),
        name: value_text(&meta["name"]),
        required: meta["required"].as_bool().unwrap_or(false),
        kind: kind.to_string(),
        options,
        value: default,
    })
}

fn parse_option(v: &Value) -> FieldOption {
    FieldOption {
        id: value_text(&v["id"]),
        name: ["value", "name", "displayName"]
            .iter()
            .find_map(|k| v[*k].as_str())
            .unwrap_or_default()
            .to_string(),
        children: v["children"].as_array().into_iter().flatten().map(parse_option).collect(),
        // 已停用的选项、已归档的版本不能再选，但仍可能是字段的当前值
        disabled: v["disabled"].as_bool().unwrap_or(false) || v["archived"].as_bool().unwrap_or(false),
    }
}

/// 解析一组字段元数据（JSON 对象，键为字段 id），保持 Jira 返回的界面顺序。
pub(crate) fn parse_fields(map: &Value) -> Vec<FieldMeta> {
    map.as_object()
        .into_iter()
        .flatten()
        .filter_map(|(key, meta)| parse_field(key, meta))
        .collect()
}

/// 把 Jira 返回的字段值转换为表单取值；空值返回 `Null`。
pub(crate) fn form_value(kind: &str, raw: &Value) -> Value {
    if raw.is_null() {
        return Value::Null;
    }
    let id = |v: &Value| value_text(&v["id"]);
    let user = |v: &Value| json!({ "name": value_text(&v["name"]), "displayName": value_text(v) });
    let items = || raw.as_array().cloned().unwrap_or_default();
    let value = match kind {
        "text" | "textarea" | "date" => Value::String(value_text(raw)),
        "number" => Value::String(value_text(raw)),
        // 2026-09-21T15:00:00.000+0800 → 2026-09-21T15:00（datetime-local 输入框的格式）
        "datetime" => Value::String(value_text(raw).chars().take(16).collect()),
        "select" => Value::String(id(raw)),
        "multiselect" => items().iter().map(id).map(Value::String).collect(),
        "cascading" => {
            let mut ids = vec![Value::String(id(raw))];
            if raw["child"].is_object() {
                ids.push(Value::String(id(&raw["child"])));
            }
            Value::Array(ids)
        }
        "user" => user(raw),
        "multiuser" => items().iter().map(user).collect(),
        "labels" => items().iter().map(|v| Value::String(value_text(v))).collect(),
        "timetracking" => {
            let mut obj = Map::new();
            for k in ["originalEstimate", "remainingEstimate"] {
                if let Some(s) = raw[k].as_str() {
                    obj.insert(k.into(), Value::String(s.into()));
                }
            }
            Value::Object(obj)
        }
        // Epic 链接的值是 Epic 的问题键
        "epic" => json!({ "key": value_text(raw), "summary": "" }),
        "parent" => json!({ "key": value_text(&raw["key"]), "summary": value_text(&raw["fields"]["summary"]) }),
        _ => Value::Null,
    };
    let empty = match &value {
        Value::String(s) => s.is_empty(),
        Value::Array(a) => a.is_empty(),
        Value::Object(o) => o.is_empty() || o.get("key").is_some_and(|k| k == ""),
        _ => false,
    };
    if empty { Value::Null } else { value }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn classifies_fields_and_skips_separately_handled() {
        let meta = json!({
            "summary": {"required": true, "name": "概要", "schema": {"type": "string", "system": "summary"}},
            "issuetype": {"required": true, "name": "问题类型", "schema": {"type": "issuetype", "system": "issuetype"}},
            "customfield_1": {"required": true, "name": "区域", "allowedValues": [{"id": "10", "value": "华东"}],
                              "schema": {"type": "option", "custom": "com.atlassian.jira.plugin.system.customfieldtypes:select"}},
            "customfield_2": {"required": false, "name": "重开次数",
                              "schema": {"type": "number", "custom": "plugin.jep:generic-counter"}},
            "components": {"required": true, "name": "模块", "allowedValues": [{"id": "1", "name": "核心"}],
                           "schema": {"type": "array", "items": "component", "system": "components"}},
            "customfield_3": {"required": false, "name": "Epic 链接",
                              "schema": {"type": "any", "custom": "com.pyxis.greenhopper.jira:gh-epic-link"}},
            "priority": {"required": false, "name": "优先级", "hasDefaultValue": true, "defaultValue": {"id": "3", "name": "中"},
                         "allowedValues": [{"id": "3", "name": "中"}], "schema": {"type": "priority", "system": "priority"}}
        });
        let fields = parse_fields(&meta);
        let kinds: Vec<(&str, &str)> = fields.iter().map(|f| (f.key.as_str(), f.kind.as_str())).collect();
        assert_eq!(
            kinds,
            [
                ("summary", "text"),
                ("customfield_1", "select"),
                ("customfield_2", "unsupported"),
                ("components", "multiselect"),
                ("customfield_3", "epic"),
                ("priority", "select"),
            ]
        );
        assert_eq!(fields[1].options[0].name, "华东");
        assert_eq!(fields[5].value, json!("3"));
    }

    #[test]
    fn converts_current_values() {
        assert_eq!(form_value("cascading", &json!({"id": "1", "value": "上海", "child": {"id": "2", "value": "浦东"}})), json!(["1", "2"]));
        assert_eq!(form_value("multiselect", &json!([{"id": "5"}, {"id": "6"}])), json!(["5", "6"]));
        assert_eq!(form_value("user", &json!({"name": "zs", "displayName": "张三"})), json!({"name": "zs", "displayName": "张三"}));
        assert_eq!(form_value("datetime", &json!("2026-09-21T15:00:00.000+0800")), json!("2026-09-21T15:00"));
        assert_eq!(form_value("number", &json!(3.5)), json!("3.5"));
        assert_eq!(form_value("labels", &json!([])), Value::Null);
        assert_eq!(form_value("epic", &json!("ABC-1")), json!({"key": "ABC-1", "summary": ""}));
        assert_eq!(form_value("timetracking", &json!({"originalEstimate": "2d"})), json!({"originalEstimate": "2d"}));
        assert_eq!(form_value("text", &json!(null)), Value::Null);
    }
}
