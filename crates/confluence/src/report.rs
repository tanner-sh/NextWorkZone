//! 周报草稿的文字处理：拆出条目末尾的进度（“修复导入 --100%”），在往周条目中找同一件事，
//! 学习往周使用的分组标题和进度写法。

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::weekly::OutlineItem;

/// 条目末尾的进度：`--100%`、`------90%`、`– 100%`、`--转开发解决`（最多 12 个字）。
static PROGRESS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(.*?\S)(\s*(?:-{2,}|–|—)\s*)([^\s\-–—][^\-–—]{0,11})\s*$").unwrap());

/// 没有往周记录时使用的进度写法。
pub const DEFAULT_SEPARATOR: &str = " --";
/// 判断为同一件事的相似度。
const SAME_ITEM: f64 = 0.6;

/// 拆出条目末尾的进度：`(内容, 进度)`。
pub fn split_progress(text: &str) -> (&str, Option<&str>) {
    match PROGRESS.captures(text) {
        Some(c) => (c.get(1).unwrap().as_str(), Some(c.get(3).unwrap().as_str().trim())),
        None => (text.trim(), None),
    }
}

/// 进度是否表示已完成。
pub fn is_finished(progress: Option<&str>) -> bool {
    progress.is_some_and(|p| p.trim() == "100%" || p.contains("完成"))
}

/// 比较用的文字：去掉空白、标点，转小写。
fn normalize(text: &str) -> Vec<char> {
    text.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// 两段文字的相似度（0–1）：一方包含另一方（至少 6 个字）记为 1，否则按相邻两字的重合比例。
pub fn similarity(a: &str, b: &str) -> f64 {
    let (a, b) = (normalize(a), normalize(b));
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let (short, long) = if a.len() <= b.len() { (&a, &b) } else { (&b, &a) };
    if short.len() >= 6 && long.windows(short.len()).any(|w| w == short.as_slice()) {
        return 1.0;
    }
    let pairs = |v: &Vec<char>| v.windows(2).map(|w| (w[0], w[1])).collect::<Vec<_>>();
    let (pa, mut pb) = (pairs(&a), pairs(&b));
    if pa.is_empty() || pb.is_empty() {
        return if a == b { 1.0 } else { 0.0 };
    }
    let total = pa.len() + pb.len();
    let mut common = 0;
    for p in &pa {
        if let Some(i) = pb.iter().position(|q| q == p) {
            pb.swap_remove(i);
            common += 1;
        }
    }
    2.0 * common as f64 / total as f64
}

/// 往周的一个条目。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PastItem {
    /// 所在分组（上一级条目）；顶层条目为空。
    pub group: String,
    /// 不含进度的内容。
    pub text: String,
    pub progress: Option<String>,
}

/// 大纲中的条目及其分组：第 0 层是分组标题，下面各层是条目。只有一层时每条都是条目。
pub fn past_items(content: &[OutlineItem]) -> Vec<PastItem> {
    let nested = content.iter().any(|i| i.level > 0);
    let mut group = String::new();
    let mut out = Vec::new();
    for item in content {
        let text = item.text.trim();
        if text.is_empty() {
            continue;
        }
        if nested && item.level == 0 {
            group = text.to_string();
            continue;
        }
        let (body, progress) = split_progress(text);
        out.push(PastItem { group: if nested { group.clone() } else { String::new() }, text: body.to_string(), progress: progress.map(str::to_string) });
    }
    out
}

/// 往周使用的分组标题，按出现次数从多到少（同样多时较近的在前）。
pub fn past_groups(weeks: &[Vec<OutlineItem>]) -> Vec<String> {
    let mut counts: Vec<(String, usize)> = Vec::new();
    for week in weeks {
        if !week.iter().any(|i| i.level > 0) {
            continue;
        }
        for item in week.iter().filter(|i| i.level == 0) {
            let title = item.text.trim();
            if title.is_empty() {
                continue;
            }
            match counts.iter_mut().find(|(t, _)| t == title) {
                Some((_, n)) => *n += 1,
                None => counts.push((title.to_string(), 1)),
            }
        }
    }
    // 稳定排序：次数相同时保持先出现（较近的周）的在前
    counts.sort_by_key(|c| std::cmp::Reverse(c.1));
    counts.into_iter().map(|(t, _)| t).collect()
}

/// 往周最常用的进度写法（进度前的分隔，例如 ` --`）。
pub fn past_separator(weeks: &[Vec<OutlineItem>]) -> String {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for item in weeks.iter().flatten() {
        if let Some(c) = PROGRESS.captures(item.text.trim()) {
            *counts.entry(c[2].to_string()).or_default() += 1;
        }
    }
    counts.into_iter().max_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.cmp(&a.0))).map(|(s, _)| s).unwrap_or_else(|| DEFAULT_SEPARATOR.into())
}

/// 往周条目中与 `text` 最相似的（达到判断为同一件事的程度）。
pub fn find_same<'a>(text: &str, items: &'a [PastItem]) -> Option<&'a PastItem> {
    items
        .iter()
        .map(|i| (i, similarity(text, &i.text)))
        .filter(|(_, s)| *s >= SAME_ITEM)
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(i, _)| i)
}

/// 条目应放在哪个分组：往周同一件事所在的分组，其次是内容中出现的往周分组标题（至少两个字），都没有时返回 `None`。
pub fn guess_group(text: &str, past: &[PastItem], groups: &[String]) -> Option<String> {
    if let Some(same) = find_same(text, past).filter(|i| !i.group.is_empty()) {
        return Some(same.group.clone());
    }
    groups.iter().filter(|g| g.chars().count() >= 2 && text.contains(g.as_str())).max_by_key(|g| g.chars().count()).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outline(lines: &[&str]) -> Vec<OutlineItem> {
        lines
            .iter()
            .map(|l| {
                let level = (l.len() - l.trim_start().len()) / 2;
                OutlineItem { level: level as u8, text: l.trim().to_string() }
            })
            .collect()
    }

    #[test]
    fn splits_progress() {
        assert_eq!(split_progress("修复导入 --100%"), ("修复导入", Some("100%")));
        assert_eq!(split_progress("导出功能开发 ------90%"), ("导出功能开发", Some("90%")));
        assert_eq!(split_progress("登录问题排查 – 100%"), ("登录问题排查", Some("100%")));
        assert_eq!(split_progress("报表字段调整 --转开发解决"), ("报表字段调整", Some("转开发解决")));
        assert_eq!(split_progress("A-1 拆分 x-y"), ("A-1 拆分 x-y", None));
        assert_eq!(split_progress("没有进度"), ("没有进度", None));
        assert!(is_finished(Some("100%")) && is_finished(Some("已完成")) && !is_finished(Some("80%")) && !is_finished(None));
    }

    #[test]
    fn measures_similarity() {
        assert_eq!(similarity("订单金额计算修复", "【客户】订单金额计算修复（第二轮）"), 1.0);
        assert!(similarity("订单报表增加三个字段", "订单报表增加两个字段") > 0.6);
        assert!(similarity("订单报表增加三个字段", "导入期货文件报错") < 0.2);
    }

    #[test]
    fn learns_from_past_weeks() {
        let last = outline(&["产品甲", "  导出功能开发 ------90%", "客户乙", "  订单金额计算修复 --80%", "  已完成的事 --100%"]);
        let older = outline(&["产品甲", "  别的事 --100%", "客户丙", "  另一件事 --100%"]);
        let items = past_items(&last);
        assert_eq!(items[1], PastItem { group: "客户乙".into(), text: "订单金额计算修复".into(), progress: Some("80%".into()) });
        let groups = past_groups(&[last.clone(), older.clone()]);
        assert_eq!(groups, vec!["产品甲", "客户乙", "客户丙"]);
        assert_eq!(past_separator(&[last, older]), " --");
        assert_eq!(guess_group("客户乙订单金额计算修复", &items, &groups), Some("客户乙".into()));
        assert_eq!(guess_group("客户丙：新需求", &items, &groups), Some("客户丙".into()));
        assert_eq!(guess_group("完全无关", &items, &groups), None);
        // 只有一层时每条都是条目，没有分组
        assert_eq!(past_items(&outline(&["一件事 --100%"]))[0].group, "");
    }
}
