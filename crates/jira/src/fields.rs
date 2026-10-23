//! Jira 字段的通用处理：把各种结构的字段值转成可读文本，以及解析流转界面。

use serde_json::Value;

use crate::meta::parse_fields;
use crate::model::{DisplayField, Status, Transition};

/// 详情页顶部已经单独展示、或对用户没有意义的字段。
const HIDDEN_FIELDS: &[&str] = &[
    "summary", "description", "status", "issuetype", "priority", "project", "comment",
    "attachment", "issuelinks", "subtasks", "parent", "resolution", "watches", "votes",
    "worklog", "timetracking", "lastViewed", "aggregateprogress", "progress",
    "aggregatetimespent", "aggregatetimeestimate", "aggregatetimeoriginalestimate",
    "timespent", "timeestimate", "timeoriginalestimate", "workratio", "thumbnail", "creator",
    "statuscategorychangedate", "environment",
];

/// 系统字段的展示顺序；未列出的系统字段排在自定义字段之前、按名称排序。
const SYSTEM_ORDER: &[&str] = &[
    "assignee", "reporter", "created", "updated", "duedate", "resolutiondate", "fixVersions",
    "versions", "components", "labels",
];

/// 网页上总是显示的系统字段（“人员”“日期”栏），不论是否在界面配置中。
const ALWAYS_SHOWN: &[&str] = &["assignee", "reporter", "created", "updated", "resolutiondate"];

/// 详情中显示的字段。`screen` 为问题界面上的字段（按界面顺序）：不在界面上的字段标为隐藏、排在最后；
/// 为空表示不知道界面配置，全部显示。
pub(crate) fn display_fields(fields: &Value, rendered: &Value, names: &Value, schema: &Value, screen: &[String]) -> Vec<DisplayField> {
    let Some(map) = fields.as_object() else { return Vec::new() };
    let mut out: Vec<(u8, usize, DisplayField)> = Vec::new();
    for (id, value) in map {
        if HIDDEN_FIELDS.contains(&id.as_str()) {
            continue;
        }
        let html = rendered[id.as_str()]
            .as_str()
            .filter(|s| s.contains('<') && !s.trim().is_empty())
            .map(str::to_string);
        let custom = schema[id.as_str()]["custom"].as_str().unwrap_or_default();
        let text = match value.as_f64() {
            // 插件计算的时长字段（例如解决用时）以毫秒存储
            Some(ms) if custom.contains("timespan") => format_millis(ms),
            _ => value_text(value),
        };
        let issue_key = custom.ends_with("gh-epic-link").then(|| text.clone()).filter(|k| !k.is_empty());
        if text.is_empty() && html.is_none() {
            continue;
        }
        let name = names[id.as_str()].as_str().unwrap_or(id).to_string();
        if is_noise(&name, &text) {
            continue;
        }
        let on_screen = screen.iter().position(|f| f == id);
        let hidden = !screen.is_empty() && on_screen.is_none() && !ALWAYS_SHOWN.contains(&id.as_str());
        let (group, order) = match (SYSTEM_ORDER.iter().position(|f| f == id), on_screen) {
            _ if hidden => (3, 0),
            (Some(i), _) => (0, i),
            // 其余字段按界面上的顺序
            (None, Some(i)) => (1, i),
            (None, None) if id.starts_with("customfield_") => (2, 0),
            (None, None) => (1, usize::MAX),
        };
        out.push((group, order, DisplayField { id: id.clone(), name, text, html, issue_key, hidden }));
    }
    out.sort_by(|a, b| (a.0, a.1, &a.2.name).cmp(&(b.0, b.1, &b.2.name)));
    out.into_iter().map(|(_, _, f)| f).collect()
}

/// 毫秒数显示为“8天 18小时 27分”。
fn format_millis(ms: f64) -> String {
    let minutes = (ms / 60000.0).round() as u64;
    let (days, hours, mins) = (minutes / 1440, minutes % 1440 / 60, minutes % 60);
    let parts: Vec<String> = [(days, "天"), (hours, "小时"), (mins, "分")].iter().filter(|(n, _)| *n > 0).map(|(n, u)| format!("{n}{u}")).collect();
    if parts.is_empty() { "0分".into() } else { parts.join(" ") }
}

/// 插件写入的内部字段（排序键、甘特图参数、开发面板摘要等）对阅读没有帮助。
fn is_noise(name: &str, text: &str) -> bool {
    name == "Rank" || name.contains("WBSGantt") || text.starts_with('{')
}

/// 把任意结构的字段值转为一行可读文本。
pub(crate) fn value_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::Bool(b) => if *b { "是" } else { "否" }.into(),
        // 整数值的浮点数（例如次数 0.0）不显示小数点
        Value::Number(n) => match n.as_f64() {
            Some(f) if !n.is_i64() && !n.is_u64() && f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", f as i64),
            _ => n.to_string(),
        },
        Value::String(s) => s.clone(),
        Value::Array(items) => items
            .iter()
            .map(value_text)
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("、"),
        Value::Object(obj) => {
            let own = ["displayName", "value", "name", "key"]
                .iter()
                .find_map(|k| obj.get(*k).and_then(Value::as_str))
                .unwrap_or_default()
                .to_string();
            // 级联选择字段：{ value, child: { value } }
            match obj.get("child").map(value_text).filter(|c| !c.is_empty()) {
                Some(child) => format!("{own} / {child}"),
                None => own,
            }
        }
    }
}

pub(crate) fn parse_transitions(raw: &Value) -> Vec<Transition> {
    raw["transitions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|t| {
            let to = serde_json::from_value(t["to"].clone()).ok();
            // 评论统一由界面上的评论框处理，流转成功后单独提交。
            let mut fields = parse_fields(&t["fields"]);
            fields.sort_by_key(|f| !f.required);
            Transition {
                id: value_text(&t["id"]),
                name: value_text(&t["name"]),
                to: Status::from_raw(to),
                fields,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn value_text_handles_common_shapes() {
        assert_eq!(value_text(&json!({"value": "上海", "child": {"value": "浦东"}})), "上海 / 浦东");
        assert_eq!(value_text(&json!([{"name": "v1"}, {"name": "v2"}])), "v1、v2");
        assert_eq!(value_text(&json!({"displayName": "张三", "name": "zs"})), "张三");
        assert_eq!(value_text(&json!(null)), "");
        assert_eq!(value_text(&json!(0.0)), "0");
        assert_eq!(value_text(&json!(2.5)), "2.5");
        assert_eq!(format_millis(757650000.0), "8天 18小时 28分");
    }

    #[test]
    fn follows_screen_configuration() {
        let fields = json!({
            "assignee": {"displayName": "张三"},
            "customfield_2": "界面上的第二个",
            "customfield_1": "界面上的第一个",
            "customfield_9": "隐藏字段的默认值",
        });
        let names = json!({"assignee": "经办人", "customfield_1": "甲", "customfield_2": "乙", "customfield_9": "丙"});
        let screen = vec!["customfield_1".to_string(), "customfield_2".to_string()];
        let list = display_fields(&fields, &json!({}), &names, &json!({}), &screen);
        let shown: Vec<(&str, bool)> = list.iter().map(|f| (f.name.as_str(), f.hidden)).collect();
        assert_eq!(shown, vec![("经办人", false), ("甲", false), ("乙", false), ("丙", true)]);
        // 不知道界面配置时全部显示
        assert!(display_fields(&fields, &json!({}), &names, &json!({}), &[]).iter().all(|f| !f.hidden));
    }

    #[test]
    fn parses_transition_fields() {
        let raw = json!({"transitions": [{
            "id": "5", "name": "解决",
            "to": {"name": "已解决", "statusCategory": {"key": "done"}},
            "fields": {
                "resolution": {"required": true, "name": "解决结果", "schema": {"type": "resolution"},
                               "allowedValues": [{"id": "1", "name": "已修复"}]},
                "comment": {"required": false, "name": "备注", "schema": {"type": "comments-page"}}
            }
        }]});
        let t = &parse_transitions(&raw)[0];
        assert_eq!(t.to.category, "done");
        assert_eq!(t.fields[0].key, "resolution");
        assert_eq!(t.fields[0].kind, "select");
        assert_eq!(t.fields.len(), 1);
    }
}
