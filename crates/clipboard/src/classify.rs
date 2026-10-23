//! 判断一段文字的类型：链接、颜色、代码或普通文本。用于卡片的显示样式和按类型筛选。

use std::sync::LazyLock;

use regex::Regex;

pub const TEXT: &str = "text";
pub const LINK: &str = "link";
pub const CODE: &str = "code";
pub const COLOR: &str = "color";
pub const IMAGE: &str = "image";
pub const FILE: &str = "file";

pub const KINDS: &[&str] = &[TEXT, LINK, CODE, COLOR, IMAGE, FILE];

static COLOR_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})|(?:rgba?|hsla?)\(\s*[0-9.]+%?\s*[, ]\s*[0-9.]+%?\s*[, ]\s*[0-9.]+%?\s*(?:[,/]\s*[0-9.]+%?\s*)?\))$").unwrap()
});
static LINK_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^(?:(?:https?|ftp)://|www\.)\S+$").unwrap());
static SQL_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)^\s*(select\s.+\sfrom\s|insert\s+into\s|update\s+\S+\s+set\s|delete\s+from\s|create\s+(table|index|view)\s|alter\s+table\s|with\s+\w+\s+as\s*\()").unwrap());
static CODE_LINE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\s*(?:(?:pub\s+)?fn\s|function\b|def\s|class\s|import\s|from\s+\S+\s+import|export\s|const\s|let\s|var\s|return\b|public\s|private\s|protected\s|package\s|#include|using\s|if\s*\(|for\s*\(|while\s*\(|\}|//|/\*|\*|#!|<\?|<[a-zA-Z][\w-]*[\s>/])").unwrap()
});

/// 文字内容的类型。
pub fn kind_of_text(text: &str) -> &'static str {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return TEXT;
    }
    if trimmed.len() <= 40 && COLOR_RE.is_match(trimmed) {
        return COLOR;
    }
    if LINK_RE.is_match(trimmed) {
        return LINK;
    }
    if looks_like_code(trimmed) {
        return CODE;
    }
    TEXT
}

fn looks_like_code(text: &str) -> bool {
    if (text.starts_with('{') && text.ends_with('}') || text.starts_with('[') && text.ends_with(']'))
        && text.len() > 2
        && serde_json::from_str::<serde_json::Value>(text).is_ok()
    {
        return true;
    }
    if SQL_RE.is_match(text) {
        return true;
    }
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.len() < 2 {
        return false;
    }
    let codeish = lines
        .iter()
        .filter(|l| {
            let t = l.trim_end();
            CODE_LINE_RE.is_match(l) || t.ends_with(';') || t.ends_with('{') || t.ends_with("=>") || t.ends_with(')') && t.contains('(')
        })
        .count();
    // 中文段落几乎不会以分号、括号结尾；多数行像代码才算
    codeish * 2 >= lines.len() && codeish >= 2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_kinds() {
        let cases = [
            ("#fff", COLOR),
            ("#5B5BD6", COLOR),
            ("rgb(12, 34, 56)", COLOR),
            ("hsla(210 40% 50% / 0.5)", COLOR),
            ("https://example.com/a?b=1", LINK),
            ("www.example.com", LINK),
            ("https://example.com 和别的文字", TEXT),
            (r#"{"a": 1, "b": [1, 2]}"#, CODE),
            ("SELECT id, name FROM users WHERE id = 1", CODE),
            ("fn main() {\n    println!(\"hi\");\n}", CODE),
            ("const a = 1;\nconst b = 2;", CODE),
            ("今天完成了登录页面的修改。\n明天继续处理导出问题。", TEXT),
            ("PROJ-123 修复导出失败", TEXT),
            ("{不是 json}", TEXT),
            ("hello", TEXT),
        ];
        for (text, kind) in cases {
            assert_eq!(kind_of_text(text), kind, "{text}");
        }
    }
}
