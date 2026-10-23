//! 从问题描述、评论等正文中找出指向 GitLab 的链接（分支、提交、合并请求），以及正文中的问题键。
//!
//! 只认已配置的 GitLab 地址；其他实例上形如 GitLab 的地址返回为外部链接，仅供显示。

use std::sync::LazyLock;

use percent_encoding::percent_decode_str;
use regex::Regex;
use serde::Serialize;

/// 正文中的网址（遇到空白、引号、尖括号和常见的中文标点结束）。
static URL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"https?://[^\s"'<>\]|)（），。、；]+"#).unwrap());
/// 问题键，例如 ABC-123（前后不能紧挨字母数字）。
static ISSUE_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|[^A-Za-z0-9_\-])([A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,6})(?:$|[^A-Za-z0-9_])").unwrap());

/// GitLab 地址中不是项目的路径开头。
const RESERVED: &[&str] = &["users", "dashboard", "explore", "help", "admin", "profile", "search", "-", "api", "assets", "uploads"];
/// 旧式（不带 `/-/`）的项目内页面。
const PROJECT_PAGES: &[&str] =
    &["tree", "blob", "commits", "commit", "merge_requests", "issues", "branches", "tags", "compare", "raw", "blame", "pipelines", "jobs", "wikis"];

/// 链接指向的对象。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum LinkTarget {
    /// 分支（或标签）。分支名可以含 `/`，`rest` 是 `tree/` 之后的全部路径，可能还带着目录或文件，
    /// 需要由调用方逐个尝试，见 [`branch_candidates`]。
    Branch { rest: String },
    Commit { sha: String },
    MergeRequest { iid: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitlabLink {
    /// 项目路径，例如 `group/sub/project`。
    pub project_path: String,
    pub target: LinkTarget,
}

/// 正文（纯文本或 HTML）中的网址，按出现顺序去重；HTML 中的 `&amp;` 会还原。
pub fn extract_urls(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for m in URL.find_iter(text) {
        let url = m.as_str().replace("&amp;", "&");
        let url = url.trim_end_matches(['.', ',', ';', ':', '!', '?']).to_string();
        if !out.contains(&url) {
            out.push(url);
        }
    }
    out
}

/// 正文中的问题键，按出现顺序去重。
pub fn issue_keys(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    // 正则的边界字符会被消耗，相邻的两个键（如“A-1 B-2”）需要逐个重新查找
    let mut rest = text;
    while let Some(caps) = ISSUE_KEY.captures(rest) {
        let m = caps.get(1).unwrap();
        if !out.iter().any(|k| k == m.as_str()) {
            out.push(m.as_str().to_string());
        }
        rest = &rest[m.end()..];
    }
    out
}

/// 正文是否以独立的词出现了这个问题键（`ABC-1` 不算出现在 `ABC-12` 中）。
pub fn mentions_key(text: &str, key: &str) -> bool {
    issue_keys(text).iter().any(|k| k == key)
}

/// 把属于 `base_url` 的地址解析为项目内的分支、提交或合并请求；其他地址返回 `None`。
pub fn parse_link(base_url: &str, url: &str) -> Option<GitlabLink> {
    let base = base_url.trim_end_matches('/');
    let rest = url.strip_prefix(base)?;
    if !rest.starts_with('/') {
        return None;
    }
    parse_path(rest)
}

/// 不属于已配置实例、但看起来是 GitLab 项目内页面的地址（其他 GitLab 实例）。
pub fn looks_like_gitlab(url: &str) -> bool {
    let Some(path) = url.split_once("://").and_then(|(_, rest)| rest.find('/').map(|i| &rest[i..])) else {
        return false;
    };
    path.contains("/-/") && parse_path(path).is_some()
}

fn parse_path(path: &str) -> Option<GitlabLink> {
    let path = path.split(['?', '#']).next().unwrap_or_default();
    let segments: Vec<String> =
        path.split('/').filter(|s| !s.is_empty()).map(|s| percent_decode_str(s).decode_utf8_lossy().into_owned()).collect();
    if segments.len() < 3 || RESERVED.contains(&segments[0].as_str()) {
        return None;
    }
    // 项目可以在多级群组下；项目内页面以 /-/ 分隔，旧式地址直接跟 tree、commit 等
    let (project_end, page) = match segments.iter().position(|s| s == "-") {
        Some(dash) if dash >= 2 => (dash, dash + 1),
        Some(_) => return None,
        None => {
            let i = segments.iter().enumerate().position(|(i, s)| i >= 2 && PROJECT_PAGES.contains(&s.as_str()))?;
            (i, i)
        }
    };
    let project_path = segments[..project_end].join("/");
    let kind = segments.get(page)?.as_str();
    let args = &segments[page + 1..];
    let target = match kind {
        "tree" | "commits" | "blob" if !args.is_empty() => LinkTarget::Branch { rest: args.join("/") },
        "commit" => {
            let sha = args.first()?;
            if sha.len() < 7 || !sha.chars().all(|c| c.is_ascii_hexdigit()) {
                return None;
            }
            LinkTarget::Commit { sha: sha.to_lowercase() }
        }
        "merge_requests" => LinkTarget::MergeRequest { iid: args.first()?.parse().ok().filter(|n| *n > 0)? },
        _ => return None,
    };
    Some(GitlabLink { project_path, target })
}

/// `tree/` 之后的路径可能是“分支名/目录”：从长到短列出可能的分支名，最多 `limit` 个。
pub fn branch_candidates(rest: &str, limit: usize) -> Vec<String> {
    let parts: Vec<&str> = rest.split('/').filter(|s| !s.is_empty()).collect();
    (1..=parts.len()).rev().take(limit).map(|n| parts[..n].join("/")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "https://git.example.com";

    fn target(url: &str) -> Option<(String, LinkTarget)> {
        parse_link(BASE, url).map(|l| (l.project_path, l.target))
    }

    #[test]
    fn parses_branch_commit_and_merge_request_links() {
        assert_eq!(
            target("https://git.example.com/group/sub/app-fe/-/tree/release_1113"),
            Some(("group/sub/app-fe".into(), LinkTarget::Branch { rest: "release_1113".into() }))
        );
        assert_eq!(
            target("https://git.example.com/group/app/-/tree/feature/PROJ-1/src/main.ts?ref_type=heads"),
            Some(("group/app".into(), LinkTarget::Branch { rest: "feature/PROJ-1/src/main.ts".into() }))
        );
        assert_eq!(
            target("https://git.example.com/group/app/-/commit/B96FC36F76BFFE99B07F9D643283959F01314866"),
            Some(("group/app".into(), LinkTarget::Commit { sha: "b96fc36f76bffe99b07f9d643283959f01314866".into() }))
        );
        assert_eq!(target("https://git.example.com/group/app/-/merge_requests/42#note_1"), Some(("group/app".into(), LinkTarget::MergeRequest { iid: 42 })));
        // 旧式地址、编码过的分支名
        assert_eq!(target("https://git.example.com/group/app/commit/abcdef1"), Some(("group/app".into(), LinkTarget::Commit { sha: "abcdef1".into() })));
        assert_eq!(
            target("https://git.example.com/group/app/-/commits/%E4%BF%AE%E5%A4%8D"),
            Some(("group/app".into(), LinkTarget::Branch { rest: "修复".into() }))
        );
    }

    #[test]
    fn ignores_other_pages_and_hosts() {
        assert_eq!(target("https://git.example.com/group/app"), None);
        assert_eq!(target("https://git.example.com/group/app/-/issues/3"), None);
        assert_eq!(target("https://git.example.com/group/app/-/commit/xyz"), None);
        assert_eq!(target("https://git.example.com/dashboard/merge_requests/1"), None);
        assert_eq!(target("https://git.example.com.evil.org/group/app/-/merge_requests/1"), None);
        assert_eq!(target("https://other.example.com/group/app/-/merge_requests/1"), None);
        assert!(looks_like_gitlab("https://other.example.com/group/app/-/tree/dev"));
        assert!(!looks_like_gitlab("https://other.example.com/browse/PROJ-1"));
        assert!(!looks_like_gitlab("https://github.com/org/repo/commit/abcdef1"), "只认带 /-/ 的地址");
    }

    #[test]
    fn extracts_urls_from_html_and_text() {
        let html = r#"已提交至 <a href="https://git.example.com/g/app/-/tree/dev?a=1&amp;b=2">https://git.example.com/g/app/-/tree/dev?a=1&amp;b=2</a>。另见 https://x.example.com/a，谢谢"#;
        assert_eq!(extract_urls(html), vec!["https://git.example.com/g/app/-/tree/dev?a=1&b=2".to_string(), "https://x.example.com/a".to_string()]);
    }

    #[test]
    fn finds_issue_keys() {
        assert_eq!(issue_keys("jira=PROJ-12 修复 feature/ABC-3"), vec!["PROJ-12".to_string(), "ABC-3".to_string()]);
        assert!(mentions_key("bugfix/PROJ-12", "PROJ-12"));
        assert!(!mentions_key("PROJ-123 修复", "PROJ-12"));
        assert!(!mentions_key("XPROJ-12", "PROJ-12"));
    }

    #[test]
    fn lists_branch_candidates_longest_first() {
        assert_eq!(branch_candidates("feature/x/src/a.ts", 3), vec!["feature/x/src/a.ts", "feature/x/src", "feature/x"]);
        assert_eq!(branch_candidates("dev", 6), vec!["dev"]);
    }
}
