//! 页面两个版本之间的差异：先把 storage 转成按段落分行的纯文本，再按行比较。

use similar::TextDiff;

use crate::text::readable_lines;

/// 统一 diff 格式（从 `@@` 开始，不含文件头），与 GitLab 返回的 diff 格式一致，前端可用同一个组件显示。
pub fn unified(old_storage: &str, new_storage: &str) -> String {
    let old = readable_lines(old_storage).join("\n") + "\n";
    let new = readable_lines(new_storage).join("\n") + "\n";
    text_diff(&old, &new)
}

pub fn text_diff(old: &str, new: &str) -> String {
    TextDiff::from_lines(old, new).unified_diff().context_radius(3).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diffs_paragraphs() {
        let diff = unified("<p>一</p><p>二</p><p>三</p>", "<p>一</p><p>贰</p><p>三</p>");
        assert!(diff.starts_with("@@ -1,3 +1,3 @@"), "{diff}");
        assert!(diff.contains("\n-二\n+贰\n"), "{diff}");
        assert_eq!(unified("<p>a</p>", "<p>a</p>"), "");
    }
}
