//! 从正文中提取对其他条目的引用，以及把 Markdown 转成用于搜索和摘要的纯文本。

use std::sync::LazyLock;

use regex::Regex;

/// Jira 问题键，例如 ABC-123（前后不能紧挨字母数字）。
static ISSUE_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|[^A-Za-z0-9_\-])([A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,6})(?:$|[^A-Za-z0-9_])").unwrap());
/// 工作空间内部文档链接：`ws://doc/<id>`
static DOC_LINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"ws://doc/([A-Za-z0-9\-]+)").unwrap());
/// Confluence 页面地址中的页面 id
static WIKI_PAGE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"pageId=([0-9]+)").unwrap());

static MD_IMAGE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"!\[[^\]]*\]\([^)]*\)").unwrap());
static MD_LINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[([^\]]*)\]\([^)]*\)").unwrap());
static MD_MARKS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^\s{0,3}(#{1,6}\s|>\s?|[-*+]\s(\[[ xX]\]\s)?|\d+\.\s)|[*_~`|]|^-{3,}$").unwrap());

/// 正文引用的 (系统, 键)：`jira` 问题、`doc` 内部文档、`wiki` 页面。
pub fn extract(text: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut push = |system: &str, key: &str| {
        let item = (system.to_string(), key.to_string());
        if !out.contains(&item) {
            out.push(item);
        }
    };
    // 正则的边界字符会被消耗，相邻的两个键（如“A-1 B-2”）需要逐个重新查找
    let mut rest = text;
    while let Some(caps) = ISSUE_KEY.captures(rest) {
        let m = caps.get(1).unwrap();
        push("jira", m.as_str());
        rest = &rest[m.end()..];
    }
    for caps in DOC_LINK.captures_iter(text) {
        push("doc", &caps[1]);
    }
    for caps in WIKI_PAGE.captures_iter(text) {
        push("wiki", &caps[1]);
    }
    out
}

/// Markdown 去掉标记后的纯文本（用于搜索、摘要），链接只保留文字。
pub fn plain_text(markdown: &str) -> String {
    let text = MD_IMAGE.replace_all(markdown, "");
    let text = MD_LINK.replace_all(&text, "$1");
    let text = MD_MARKS.replace_all(&text, "");
    text.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_references() {
        let refs = extract("见 PROJ-21398 和ABC-1、[说明](ws://doc/1234-ab) UTF8 x-1 http://w/pages/viewpage.action?pageId=987");
        assert!(refs.contains(&("jira".into(), "PROJ-21398".into())));
        assert!(refs.contains(&("jira".into(), "ABC-1".into())));
        assert!(refs.contains(&("doc".into(), "1234-ab".into())));
        assert!(refs.contains(&("wiki".into(), "987".into())));
        assert_eq!(refs.len(), 4);
        assert_eq!(extract("AB-1 CD-2").len(), 2);
        assert!(extract("A-1").is_empty(), "项目键至少两个字符");
    }

    #[test]
    fn strips_markdown() {
        let md = "# 标题\n\n- [x] **完成** 的 `代码`\n> 引用\n\n![图](ws://asset/1) [链接](https://x)";
        assert_eq!(plain_text(md), "标题\n完成 的 代码\n引用\n链接");
    }
}
