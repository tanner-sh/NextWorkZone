//! 从 storage 内容中提取信息：便于阅读和比较的纯文本、引用的 Jira 问题、页面中的任务。

use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::storage::{Doc, TokKind, collapse_whitespace, decode_entities};

/// Jira 问题键，例如 ABC-123（前后不能紧挨字母数字）。
static ISSUE_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|[^A-Za-z0-9_\-])([A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,6})(?:$|[^A-Za-z0-9_])").unwrap());
static ATTR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#).unwrap());

/// 起始标签源码中某个属性的值（已解码实体）。
pub fn attr(tag: &str, name: &str) -> Option<String> {
    ATTR.captures_iter(tag)
        .find(|c| &c[1] == name)
        .map(|c| decode_entities(c.get(2).or_else(|| c.get(3)).map_or("", |m| m.as_str())))
}

/// 换行后开始新的一行的元素。
const BLOCK_TAGS: &[&str] = &[
    "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "pre", "blockquote", "table", "ul", "ol", "hr",
    "ac:task", "ac:layout-cell", "ac:layout-section", "ac:rich-text-body", "ac:plain-text-body",
];

/// 页面内容的纯文本，按段落、列表项、表格行分行，便于阅读、全文搜索和比较版本差异。
/// 宏只保留对理解内容有用的部分（Jira 问题键、代码等），宏参数不输出。
pub fn readable_lines(storage: &str) -> Vec<String> {
    let Ok(doc) = Doc::parse(storage) else {
        // 解析失败时退回到去掉标签的文本
        let stripped = Regex::new(r"<[^>]*>").unwrap().replace_all(storage, " ");
        return vec![collapse_whitespace(&decode_entities(&stripped))];
    };
    let mut out = Lines::default();
    // 当前所在的宏名称栈
    let mut macros: Vec<String> = Vec::new();
    // 表格单元格内的段落、列表不换行，一个表格行保持为一行
    let mut cells = 0usize;
    let mut i = 0;
    while i < doc.toks.len() {
        let tok = &doc.toks[i];
        let tag = &doc.src[tok.span.clone()];
        match tok.kind {
            TokKind::Start | TokKind::Empty => {
                let name = tok.name.as_str();
                if BLOCK_TAGS.contains(&name) {
                    out.newline_or_space(cells > 0);
                }
                match name {
                    "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                        let level = name[1..].parse::<usize>().unwrap_or(1);
                        out.push(&format!("{} ", "#".repeat(level)));
                    }
                    "li" => out.push("- "),
                    "td" | "th" => {
                        out.push(" | ");
                        if tok.kind == TokKind::Start {
                            cells += 1;
                        }
                    }
                    "br" => out.newline_or_space(cells > 0),
                    "ac:task-status" => {
                        let status = doc.text(doc.children(i));
                        out.push(if status == "complete" { "[x] " } else { "[ ] " });
                        i = tok.close.unwrap_or(i) + 1;
                        continue;
                    }
                    "ac:task-id" => {
                        i = tok.close.unwrap_or(i) + 1;
                        continue;
                    }
                    "ac:structured-macro" | "ac:macro" => {
                        let macro_name = attr(tag, "ac:name").unwrap_or_default();
                        if tok.kind == TokKind::Start {
                            macros.push(macro_name.clone());
                        }
                    }
                    "ac:parameter" => {
                        // 宏参数中只输出 Jira 宏的问题键
                        let param = attr(tag, "ac:name").unwrap_or_default();
                        if macros.last().map(String::as_str) == Some("jira") && param == "key" {
                            out.push(&format!(" [{}] ", doc.text(doc.children(i))));
                        }
                        i = tok.close.unwrap_or(i) + 1;
                        continue;
                    }
                    "ac:image" => {
                        let file = doc.children(i).find_map(|j| {
                            let t = &doc.toks[j];
                            (t.name == "ri:attachment").then(|| attr(&doc.src[t.span.clone()], "ri:filename")).flatten()
                        });
                        out.push(&format!("[图片{}]", file.map(|f| format!(" {f}")).unwrap_or_default()));
                        i = tok.close.unwrap_or(i) + 1;
                        continue;
                    }
                    "ri:page" => {
                        if let Some(title) = attr(tag, "ri:content-title") {
                            out.push(&title);
                        }
                    }
                    "ri:user" => out.push("@用户"),
                    _ => {}
                }
            }
            TokKind::End => {
                if tok.name == "ac:structured-macro" || tok.name == "ac:macro" {
                    macros.pop();
                }
                if tok.name == "td" || tok.name == "th" {
                    cells = cells.saturating_sub(1);
                }
                if BLOCK_TAGS.contains(&tok.name.as_str()) {
                    out.newline_or_space(cells > 0);
                }
            }
            TokKind::Text => out.push(&decode_entities(tag)),
            TokKind::Other => {
                // 代码宏的正文在 CDATA 中，保留原有换行
                if let Some(body) = tag.strip_prefix("<![CDATA[").and_then(|t| t.strip_suffix("]]>")) {
                    out.newline_or_space(cells > 0);
                    for line in body.lines() {
                        out.push(line);
                        out.newline_or_space(cells > 0);
                    }
                }
            }
        }
        i += 1;
    }
    out.finish()
}

#[derive(Default)]
struct Lines {
    lines: Vec<String>,
    current: String,
}

impl Lines {
    fn push(&mut self, text: &str) {
        self.current.push_str(text);
    }

    fn newline_or_space(&mut self, space: bool) {
        if space { self.push(" ") } else { self.newline() }
    }

    fn newline(&mut self) {
        let line = collapse_whitespace(&self.current);
        // 表格行以分隔符开头，去掉多余的开头分隔符
        let line = line.strip_prefix("| ").map(str::to_string).unwrap_or(line);
        if !line.is_empty() && line != "-" && line != "|" {
            self.lines.push(line);
        }
        self.current.clear();
    }

    fn finish(mut self) -> Vec<String> {
        self.newline();
        self.lines
    }
}

/// 页面引用的 Jira 问题：Jira 宏中的问题键，以及正文中出现的问题键。按出现顺序去重。
pub fn jira_keys(storage: &str, text: &str) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    if let Ok(doc) = Doc::parse(storage) {
        let mut in_jira = false;
        for (i, tok) in doc.toks.iter().enumerate() {
            let tag = &doc.src[tok.span.clone()];
            match (tok.kind, tok.name.as_str()) {
                (TokKind::Start, "ac:structured-macro") => in_jira = attr(tag, "ac:name").as_deref() == Some("jira"),
                (TokKind::End, "ac:structured-macro") => in_jira = false,
                (TokKind::Start, "ac:parameter") if in_jira && attr(tag, "ac:name").as_deref() == Some("key") => {
                    let key = doc.text(doc.children(i));
                    if !key.is_empty() && !keys.contains(&key) {
                        keys.push(key);
                    }
                }
                _ => {}
            }
        }
    }
    let mut rest = text;
    while let Some(caps) = ISSUE_KEY.captures(rest) {
        let m = caps.get(1).unwrap();
        if !keys.iter().any(|k| k == m.as_str()) {
            keys.push(m.as_str().to_string());
        }
        rest = &rest[m.end()..];
    }
    keys
}

/// 页面中的一个任务（`ac:task`）。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InlineTask {
    pub task_id: String,
    pub done: bool,
    pub text: String,
    /// 任务中提到的用户（userkey）。
    pub assignees: Vec<String>,
    /// 任务中的日期 `YYYY-MM-DD`。
    pub due: Option<String>,
}

/// 页面中全部的任务。
pub fn inline_tasks(storage: &str) -> Vec<InlineTask> {
    let Ok(doc) = Doc::parse(storage) else { return Vec::new() };
    let mut tasks = Vec::new();
    for (i, tok) in doc.toks.iter().enumerate() {
        if tok.kind != TokKind::Start || tok.name != "ac:task" {
            continue;
        }
        let mut task = InlineTask { task_id: String::new(), done: false, text: String::new(), assignees: Vec::new(), due: None };
        let mut body = None;
        for j in doc.children(i) {
            let t = &doc.toks[j];
            let tag = &doc.src[t.span.clone()];
            match (t.kind, t.name.as_str()) {
                (TokKind::Start, "ac:task-id") => task.task_id = doc.text(doc.children(j)),
                (TokKind::Start, "ac:task-status") => task.done = doc.text(doc.children(j)) == "complete",
                (TokKind::Start, "ac:task-body") => body = Some(j),
                (TokKind::Start | TokKind::Empty, "ri:user") => {
                    if let Some(key) = attr(tag, "ri:userkey").or_else(|| attr(tag, "ri:username"))
                        && !task.assignees.contains(&key) {
                            task.assignees.push(key);
                        }
                }
                (TokKind::Start | TokKind::Empty, "time")
                    if task.due.is_none() => {
                        task.due = attr(tag, "datetime");
                    }
                _ => {}
            }
        }
        if let Some(b) = body {
            task.text = readable_lines(&doc.src[doc.inner(b)]).join(" ");
        }
        if !task.task_id.is_empty() {
            tasks.push(task);
        }
    }
    tasks
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<h1>标题</h1><p>说明&nbsp;文字 FYX-12 见<ac:structured-macro ac:name="jira" ac:schema-version="1"><ac:parameter ac:name="server">JIRA</ac:parameter><ac:parameter ac:name="key">GLIUAP-1646</ac:parameter></ac:structured-macro></p><table><tbody><tr><th>A</th><th>B</th></tr><tr><td>1</td><td><p>2</p></td></tr></tbody></table><ac:structured-macro ac:name="code"><ac:parameter ac:name="language">java</ac:parameter><ac:plain-text-body><![CDATA[int a = 1;
int b = 2;]]></ac:plain-text-body></ac:structured-macro><ac:task-list><ac:task><ac:task-id>3</ac:task-id><ac:task-status>incomplete</ac:task-status><ac:task-body>写文档 <ac:link><ri:user ri:userkey="abc" /></ac:link> <time datetime="2026-10-30" /></ac:task-body></ac:task></ac:task-list><p><ac:image><ri:attachment ri:filename="a.png" /></ac:image></p>"#;

    #[test]
    fn readable_text() {
        let lines = readable_lines(SAMPLE);
        assert_eq!(lines[0], "# 标题");
        assert_eq!(lines[1], "说明 文字 FYX-12 见 [GLIUAP-1646]");
        assert!(lines.contains(&"A | B".to_string()), "{lines:?}");
        assert!(lines.contains(&"1 | 2".to_string()), "{lines:?}");
        assert!(lines.contains(&"int a = 1;".to_string()));
        assert!(lines.contains(&"int b = 2;".to_string()));
        assert!(lines.iter().any(|l| l.starts_with("[ ] 写文档")), "{lines:?}");
        assert!(lines.contains(&"[图片 a.png]".to_string()));
        assert!(!lines.iter().any(|l| l.contains("java") || l.contains("JIRA")), "宏参数不输出：{lines:?}");
    }

    #[test]
    fn finds_jira_keys() {
        let text = readable_lines(SAMPLE).join("\n");
        assert_eq!(jira_keys(SAMPLE, &text), vec!["GLIUAP-1646", "FYX-12"]);
    }

    #[test]
    fn finds_tasks() {
        let tasks = inline_tasks(SAMPLE);
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task_id, "3");
        assert!(!tasks[0].done);
        assert_eq!(tasks[0].assignees, vec!["abc"]);
        assert_eq!(tasks[0].due.as_deref(), Some("2026-10-30"));
        assert!(tasks[0].text.starts_with("写文档"));
    }
}
