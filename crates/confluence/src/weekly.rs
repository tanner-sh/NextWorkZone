//! 周报页面的读写。
//!
//! 约定的页面结构：每周一个顶层 `<h1>`，标题以日期范围开头（如 `10.12-10.18`、`10/12-10/18`，可带后缀）；
//! 其下的表格中，第一列是人名的那一行就是自己的周报：`名字 | 周报内容 | 风险事项（可选）`。
//! 本模块只改写自己那一行的后续单元格，其余内容逐字节保持原样。

use chrono::{Datelike, Duration, NaiveDate};
use nextworkzone_core::{Error, Result};
use serde::{Deserialize, Serialize};

use crate::storage::{Doc, TokKind, collapse_whitespace, escape_text};

/// 新建小节时，第一列文字不超过这个长度的表格视为“人员名单”，保留第一列。
const NAME_CELL_MAX_CHARS: usize = 20;
/// 页面上列出的最近几周小节。
const RECENT_SECTIONS: usize = 6;

/// 大纲式列表中的一项：`level` 为缩进层级（0 为顶层）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutlineItem {
    pub level: u8,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SectionInfo {
    pub title: String,
    pub covers_today: bool,
}

/// 某一周小节中自己那一行的内容。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WeekEntry {
    pub section_title: String,
    pub row_found: bool,
    pub content: Vec<OutlineItem>,
    pub risk: Vec<OutlineItem>,
    /// 单元格原文，保存时用于判断是否被他人改动过。
    pub content_raw: String,
    pub risk_raw: String,
    /// 原内容包含无法在大纲编辑器中保留的格式（加粗、颜色、链接、宏等）。
    pub lossy: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WeeklyOverview {
    pub sections: Vec<SectionInfo>,
    /// 本周（周一至周日）的标题，沿用最新小节的日期写法，例如 `10.19-10.25`。
    pub current_week_title: String,
    /// 是否已有覆盖今天的小节。
    pub current_week_exists: bool,
}

pub(crate) struct Section {
    pub title: String,
    /// 小节在 token 序列中的范围（从 `<h1>` 到下一个顶层 `<h1>` 之前）。
    pub toks: std::ops::Range<usize>,
    /// 小节在原文中的起始字节。
    pub start: usize,
}

pub(crate) fn sections(doc: &Doc) -> Vec<Section> {
    let heads = doc.find_children(0..doc.toks.len(), 0, "h1");
    heads
        .iter()
        .enumerate()
        .map(|(i, &open)| {
            let end = heads.get(i + 1).copied().unwrap_or(doc.toks.len());
            Section { title: doc.text(doc.children(open)), toks: open..end, start: doc.toks[open].span.start }
        })
        .filter(|s| !s.title.is_empty())
        .collect()
}

/// 解析小节标题开头的日期范围 `MM.DD-MM.DD`。年份根据 `today` 推断，并处理跨年。
pub fn parse_range(title: &str, today: NaiveDate) -> Option<(NaiveDate, NaiveDate)> {
    let mut nums = title
        .split(|c: char| !c.is_ascii_digit())
        .filter(|s| !s.is_empty())
        .take(4)
        .map(|s| s.parse::<u32>().ok());
    let (m1, d1, m2, d2) = (nums.next()??, nums.next()??, nums.next()??, nums.next()??);
    let year = today.year();
    let mut start = NaiveDate::from_ymd_opt(year, m1, d1)?;
    let mut end = NaiveDate::from_ymd_opt(year, m2, d2)?;
    if end < start {
        end = NaiveDate::from_ymd_opt(year + 1, m2, d2)?;
    }
    if start > today + Duration::days(60) {
        start = NaiveDate::from_ymd_opt(year - 1, m1, d1)?;
        end = NaiveDate::from_ymd_opt(end.year() - 1, m2, d2)?;
    }
    Some((start, end))
}

/// 本周（周一至周日）的小节标题。日期写法（分隔符、是否补零）参照 `template`（通常是最新一节的标题），
/// 无法识别时使用 `MM.DD-MM.DD`。
pub fn week_title(today: NaiveDate, template: Option<&str>) -> String {
    let monday = today - Duration::days(today.weekday().num_days_from_monday() as i64);
    let sunday = monday + Duration::days(6);
    let style = template.and_then(DateStyle::detect).unwrap_or_default();
    let fmt = |n: u32| if style.padded { format!("{n:02}") } else { n.to_string() };
    format!(
        "{}{}{}{}{}{}{}",
        fmt(monday.month()),
        style.date_sep,
        fmt(monday.day()),
        style.range_sep,
        fmt(sunday.month()),
        style.date_sep,
        fmt(sunday.day()),
    )
}

/// 小节标题中日期范围的写法。
struct DateStyle {
    date_sep: String,
    range_sep: String,
    padded: bool,
}

impl Default for DateStyle {
    fn default() -> Self {
        DateStyle { date_sep: ".".into(), range_sep: "-".into(), padded: true }
    }
}

impl DateStyle {
    /// 从形如 `10.12-10.18` 的标题开头识别：数字、分隔符、数字、分隔符、数字、分隔符、数字。
    fn detect(title: &str) -> Option<Self> {
        let mut numbers: Vec<&str> = Vec::new();
        let mut separators: Vec<&str> = Vec::new();
        let mut rest = title.trim_start();
        while numbers.len() < 4 {
            let digits = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
            if digits == 0 || digits > 2 {
                return None;
            }
            numbers.push(&rest[..digits]);
            rest = &rest[digits..];
            if numbers.len() < 4 {
                let sep = rest.find(|c: char| c.is_ascii_digit()).unwrap_or(rest.len());
                if sep == 0 || sep > 3 {
                    return None;
                }
                separators.push(&rest[..sep]);
                rest = &rest[sep..];
            }
        }
        Some(DateStyle {
            date_sep: separators[0].to_string(),
            range_sep: separators[1].to_string(),
            padded: numbers.iter().all(|n| n.len() == 2),
        })
    }
}

fn covers(title: &str, today: NaiveDate) -> bool {
    parse_range(title, today).is_some_and(|(start, end)| start <= today && today <= end)
}

pub fn overview(storage: &str, today: NaiveDate) -> Result<WeeklyOverview> {
    let doc = Doc::parse(storage).map_err(|e| Error::Other(e.to_string()))?;
    let all = sections(&doc);
    Ok(WeeklyOverview {
        current_week_exists: all.iter().any(|s| covers(&s.title, today)),
        sections: all
            .iter()
            .take(RECENT_SECTIONS)
            .map(|s| SectionInfo { title: s.title.clone(), covers_today: covers(&s.title, today) })
            .collect(),
        current_week_title: week_title(today, all.first().map(|s| s.title.as_str())),
    })
}

/// 默认编辑的小节：覆盖今天的小节，否则最新的一节。
pub fn default_section(overview: &WeeklyOverview) -> Option<String> {
    overview
        .sections
        .iter()
        .find(|s| s.covers_today)
        .or_else(|| overview.sections.first())
        .map(|s| s.title.clone())
}

/// 自己那一行：各单元格的起始标签下标（名字、周报内容、风险事项）。
struct Row {
    cells: Vec<usize>,
}

/// 表格中的行（不含嵌套表格中的行）。
fn table_rows(doc: &Doc, table: usize) -> Vec<usize> {
    let depth = doc.toks[table].depth;
    doc.children(table)
        .filter(|&i| {
            let t = &doc.toks[i];
            t.kind == TokKind::Start && t.name == "tr" && (t.depth == depth + 1 || t.depth == depth + 2)
        })
        .collect()
}

/// 行中的单元格（`td` 与 `th`），按顺序排列。
fn row_cells(doc: &Doc, tr: usize) -> Vec<usize> {
    let depth = doc.toks[tr].depth + 1;
    let mut cells = doc.find_children(doc.children(tr), depth, "td");
    cells.extend(doc.find_children(doc.children(tr), depth, "th"));
    cells.sort_unstable();
    cells
}

/// 在小节的表格中找第一列是自己名字的那一行。
fn find_row(doc: &Doc, section: &Section, name: &str) -> Option<Row> {
    let wanted = collapse_whitespace(name).replace(' ', "");
    doc.find_children(section.toks.clone(), 0, "table")
        .into_iter()
        .flat_map(|table| table_rows(doc, table))
        .map(|tr| row_cells(doc, tr))
        .find(|cells| cells.len() >= 2 && doc.text(doc.children(cells[0])).replace(' ', "") == wanted)
        .map(|cells| Row { cells })
}

fn section_by_title<'d>(all: &'d [Section], title: &str) -> Result<&'d Section> {
    all.iter()
        .find(|s| s.title == title)
        .ok_or_else(|| Error::Other(format!("页面中没有找到小节「{title}」，它可能已被他人改名或删除")))
}

pub fn entry(storage: &str, section_title: &str, name: &str) -> Result<WeekEntry> {
    let doc = Doc::parse(storage).map_err(|e| Error::Other(e.to_string()))?;
    let all = sections(&doc);
    let section = section_by_title(&all, section_title)?;
    let Some(row) = find_row(&doc, section, name) else {
        return Ok(WeekEntry {
            section_title: section_title.to_string(),
            row_found: false,
            content: Vec::new(),
            risk: Vec::new(),
            content_raw: String::new(),
            risk_raw: String::new(),
            lossy: false,
        });
    };
    let cell = |i: usize| row.cells.get(i).copied();
    let (content, lossy_content) = cell(1).map(|c| cell_to_outline(&doc, c)).unwrap_or_default();
    let (risk, lossy_risk) = cell(2).map(|c| cell_to_outline(&doc, c)).unwrap_or_default();
    let raw = |i: usize| cell(i).map(|c| storage[doc.inner(c)].to_string()).unwrap_or_default();
    Ok(WeekEntry {
        section_title: section_title.to_string(),
        row_found: true,
        content,
        risk,
        content_raw: raw(1),
        risk_raw: raw(2),
        lossy: lossy_content || lossy_risk,
    })
}

/// 改写结果。
pub struct Edit {
    pub storage: String,
    pub changed: bool,
}

/// 用新的大纲内容替换自己那一行的两个单元格。
///
/// `expected` 为加载时的单元格原文；若页面上的原文已不同（他人或网页端改动过这一行），返回冲突错误。
pub fn apply_entry(
    storage: &str,
    section_title: &str,
    name: &str,
    expected: Option<(&str, &str)>,
    content: &[OutlineItem],
    risk: &[OutlineItem],
) -> Result<Edit> {
    let doc = Doc::parse(storage).map_err(|e| Error::Other(e.to_string()))?;
    let all = sections(&doc);
    let section = section_by_title(&all, section_title)?;
    let row = find_row(&doc, section, name)
        .ok_or_else(|| Error::Other(format!("小节「{section_title}」中没有找到「{name}」的行")))?;
    let content_cell = row.cells.get(1).map(|&c| doc.inner(c));
    let risk_cell = row.cells.get(2).map(|&c| doc.inner(c));

    if let Some((expected_content, expected_risk)) = expected {
        let current = |r: &Option<std::ops::Range<usize>>| r.clone().map(|r| &storage[r]).unwrap_or("");
        if current(&content_cell) != expected_content || current(&risk_cell) != expected_risk {
            return Err(Error::Conflict(
                "你在这一周的周报内容在 Wiki 上已被修改（可能是在网页中编辑过），请重新加载后再编辑".into(),
            ));
        }
    }

    // 从后往前替换，前面的字节位置不受影响。
    let mut replacements: Vec<(std::ops::Range<usize>, String)> = Vec::new();
    if let Some(range) = content_cell {
        replacements.push((range, render_outline(content)));
    }
    if let Some(range) = risk_cell {
        replacements.push((range, render_outline(risk)));
    }
    replacements.sort_by_key(|(r, _)| std::cmp::Reverse(r.start));

    let mut out = storage.to_string();
    let mut changed = false;
    for (range, html) in replacements {
        // 内容在语义上没变时保留原文：不产生无意义的改动，也保留原有的加粗、颜色等格式。
        let unchanged = outline_of_html(&storage[range.clone()]) == outline_of_html(&html);
        if !unchanged {
            out.replace_range(range, &html);
            changed = true;
        }
    }
    Ok(Edit { storage: out, changed })
}

fn outline_of_html(html: &str) -> Vec<OutlineItem> {
    Doc::parse(html).map(|d| normalize(parse_outline(&d, 0..d.toks.len()).0)).unwrap_or_default()
}

/// 在页面顶部插入新的一周小节：复制最新一周的结构，清空填写内容，保留人员名单。
pub fn insert_week(storage: &str, title: &str) -> Result<String> {
    let doc = Doc::parse(storage).map_err(|e| Error::Other(e.to_string()))?;
    let all = sections(&doc);
    if all.iter().any(|s| s.title.starts_with(title)) {
        return Err(Error::Other(format!("小节「{title}」已存在")));
    }
    let latest = all.first().ok_or_else(|| Error::Other("页面中没有可作为模板的周小节".into()))?;
    let end = all.get(1).map(|s| s.start).unwrap_or(storage.len());

    // 在模板片段内记录需要替换的范围：标题文字、各数据单元格内容。
    let mut replacements: Vec<(std::ops::Range<usize>, String)> = Vec::new();
    let h1 = latest.toks.start;
    replacements.push((doc.inner(h1), escape_text(title)));
    for table in doc.find_children(latest.toks.clone(), 0, "table") {
        // 只取包含 td 的数据行，表头行（全是 th）原样保留
        let data_rows: Vec<Vec<usize>> = table_rows(&doc, table)
            .into_iter()
            .map(|tr| doc.find_children(doc.children(tr), doc.toks[tr].depth + 1, "td"))
            .filter(|cells| !cells.is_empty())
            .collect();
        let keep_names = is_name_list(&doc, &data_rows);
        for cells in &data_rows {
            for (col, &td) in cells.iter().enumerate() {
                if keep_names && col == 0 {
                    continue;
                }
                replacements.push((doc.inner(td), "<br />".into()));
            }
        }
    }
    replacements.sort_by_key(|(r, _)| std::cmp::Reverse(r.start));
    let mut section = storage[latest.start..end].to_string();
    for (range, html) in replacements {
        section.replace_range(range.start - latest.start..range.end - latest.start, &html);
    }

    let mut out = String::with_capacity(storage.len() + section.len());
    out.push_str(&storage[..latest.start]);
    out.push_str(&section);
    out.push_str(&storage[latest.start..]);
    Ok(out)
}

/// 表格的第一列是否是人员名单：至少两行，且每行第一列都是简短的纯文本（不含列表、段落等结构）。
fn is_name_list(doc: &Doc, rows: &[Vec<usize>]) -> bool {
    rows.len() >= 2
        && rows.iter().all(|cells| {
            let first = cells[0];
            let structured = doc.children(first).any(|i| {
                let t = &doc.toks[i];
                t.kind == TokKind::Start && matches!(t.name.as_str(), "ul" | "ol" | "table" | "p" | "div")
            });
            let text = doc.text(doc.children(first));
            !structured && !text.is_empty() && text.chars().count() <= NAME_CELL_MAX_CHARS
        })
}

// ---------- 单元格 ↔ 大纲 ----------

/// 可以无损转换为大纲的标签。
const PLAIN_TAGS: &[&str] = &["ul", "ol", "li", "p", "br", "span", "div"];

fn cell_to_outline(doc: &Doc, cell: usize) -> (Vec<OutlineItem>, bool) {
    let (items, lossy) = parse_outline(doc, doc.children(cell));
    (normalize(items), lossy)
}

fn parse_outline(doc: &Doc, range: std::ops::Range<usize>) -> (Vec<OutlineItem>, bool) {
    let mut items: Vec<OutlineItem> = Vec::new();
    let mut li_stack: Vec<usize> = Vec::new();
    let mut list_depth: usize = 0;
    let mut loose: Option<usize> = None;
    let mut lossy = false;

    for tok in &doc.toks[range] {
        match tok.kind {
            TokKind::Start | TokKind::Empty => {
                let raw = &doc.src[tok.span.clone()];
                if !PLAIN_TAGS.contains(&tok.name.as_str()) || (tok.name == "span" && raw.contains("font-weight")) {
                    lossy = true;
                }
                match (tok.kind, tok.name.as_str()) {
                    (TokKind::Start, "ul" | "ol") => {
                        list_depth += 1;
                        loose = None;
                    }
                    (TokKind::Start, "li") => {
                        items.push(OutlineItem { level: list_depth.saturating_sub(1) as u8, text: String::new() });
                        li_stack.push(items.len() - 1);
                    }
                    (TokKind::Start, "p" | "div") if li_stack.is_empty() => {
                        items.push(OutlineItem { level: list_depth as u8, text: String::new() });
                        loose = Some(items.len() - 1);
                    }
                    (TokKind::Empty, "br") => {
                        if let Some(&i) = li_stack.last().or(loose.as_ref()) {
                            items[i].text.push(' ');
                        }
                    }
                    _ => {}
                }
            }
            TokKind::End => match tok.name.as_str() {
                "ul" | "ol" => list_depth = list_depth.saturating_sub(1),
                "li" => {
                    li_stack.pop();
                }
                "p" | "div" if li_stack.is_empty() => loose = None,
                _ => {}
            },
            TokKind::Text => {
                let text = crate::storage::decode_entities(&doc.src[tok.span.clone()]);
                if text.trim().is_empty() && li_stack.is_empty() && loose.is_none() {
                    continue;
                }
                let target = match li_stack.last().or(loose.as_ref()) {
                    Some(&i) => i,
                    None => {
                        items.push(OutlineItem { level: 0, text: String::new() });
                        loose = Some(items.len() - 1);
                        items.len() - 1
                    }
                };
                items[target].text.push_str(&text);
            }
            TokKind::Other => lossy = true,
        }
    }
    (items, lossy)
}

/// 去掉空项、合并空白，并保证层级每次最多加深一级。
fn normalize(items: Vec<OutlineItem>) -> Vec<OutlineItem> {
    let mut out: Vec<OutlineItem> = Vec::new();
    for item in items {
        let text = collapse_whitespace(&item.text);
        if text.is_empty() {
            continue;
        }
        let max_level = out.last().map(|p| p.level + 1).unwrap_or(0);
        out.push(OutlineItem { level: item.level.min(max_level), text });
    }
    out
}

/// 把大纲渲染为 storage 格式的嵌套列表；为空时输出 `<br />`，与页面上空单元格的写法一致。
pub fn render_outline(items: &[OutlineItem]) -> String {
    let items = normalize(items.to_vec());
    if items.is_empty() {
        return "<br />".into();
    }
    let mut out = String::new();
    let mut current: i32 = -1;
    for item in &items {
        let level = (item.level as i32).min(current + 1);
        if level > current {
            out.push_str("<ul>");
        } else {
            while current > level {
                out.push_str("</li></ul>");
                current -= 1;
            }
            out.push_str("</li>");
        }
        out.push_str("<li>");
        out.push_str(&escape_text(&item.text));
        current = level;
    }
    while current >= 0 {
        out.push_str("</li></ul>");
        current -= 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(level: u8, text: &str) -> OutlineItem {
        OutlineItem { level, text: text.into() }
    }

    const PAGE: &str = concat!(
        "<h1 class=\"auto-cursor-target\">10.12-10.18</h1><p>说明</p>",
        "<table><tbody><tr><th>本周工作总结</th><th>下周</th></tr><tr><td><ul><li>汇总</li></ul></td><td><br /></td></tr></tbody></table>",
        "<table><tbody><tr><th>人员名称（个人填）</th><th>周报内容（个人填）</th><th>风险事项（个人填）</th></tr>",
        "<tr><td><strong>李四</strong></td><td><ul><li>知识库开发</li></ul></td><td><br /></td></tr>",
        "<tr><td><strong>张三</strong></td><td><ul><li>模块 A<ul><li>导出功能&nbsp; &nbsp;--100%</li></ul></li><li>模块 B</li></ul></td><td><br /></td></tr>",
        "</tbody></table><p><br /></p>",
        "<h1>10.05-10.11</h1><table><tbody><tr><th>人员名称</th><th>内容</th><th>风险</th></tr>",
        "<tr><td><strong>张三</strong></td><td><ul><li>上周的内容</li></ul></td><td><br /></td></tr></tbody></table>",
    );

    fn today() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, 15).unwrap()
    }

    #[test]
    fn reads_overview_and_entry() {
        let ov = overview(PAGE, today()).unwrap();
        assert_eq!(ov.sections.len(), 2);
        assert!(ov.sections[0].covers_today);
        assert!(ov.current_week_exists);
        assert_eq!(ov.current_week_title, "10.12-10.18");

        let e = entry(PAGE, "10.12-10.18", "张三").unwrap();
        assert!(e.row_found);
        assert_eq!(e.content, vec![item(0, "模块 A"), item(1, "导出功能 --100%"), item(0, "模块 B")]);
        assert!(e.risk.is_empty());
        assert!(!e.lossy);

        let missing = entry(PAGE, "10.12-10.18", "不存在").unwrap();
        assert!(!missing.row_found);
    }

    #[test]
    fn edits_only_own_cells() {
        let e = entry(PAGE, "10.12-10.18", "张三").unwrap();
        let content = vec![item(0, "模块 A"), item(1, "导出功能 --100%"), item(0, "新增 <b> & 任务")];
        let risk = vec![item(0, "无")];
        let edit = apply_entry(PAGE, "10.12-10.18", "张三", Some((&e.content_raw, &e.risk_raw)), &content, &risk).unwrap();
        assert!(edit.changed);
        let expected_cells = "<td><ul><li>模块 A<ul><li>导出功能 --100%</li></ul></li><li>新增 &lt;b&gt; &amp; 任务</li></ul></td><td><ul><li>无</li></ul></td>";
        assert!(edit.storage.contains(expected_cells), "{}", edit.storage);
        // 其他人、其他周的内容保持不变
        let own_old = &PAGE[PAGE.find("<tr><td><strong>张三").unwrap()..PAGE.find("</tbody></table><p><br /></p>").unwrap()];
        assert_eq!(edit.storage.replacen(&edit.storage[edit.storage.find("<tr><td><strong>张三").unwrap()..edit.storage.find("</tbody></table><p><br /></p>").unwrap()], own_old, 1), PAGE);
        // 再次读取得到相同的大纲
        let again = entry(&edit.storage, "10.12-10.18", "张三").unwrap();
        assert_eq!(again.content, content);
    }

    #[test]
    fn unchanged_content_keeps_original_bytes() {
        let e = entry(PAGE, "10.12-10.18", "张三").unwrap();
        let edit = apply_entry(PAGE, "10.12-10.18", "张三", Some((&e.content_raw, &e.risk_raw)), &e.content, &e.risk).unwrap();
        assert!(!edit.changed);
        assert_eq!(edit.storage, PAGE);
    }

    #[test]
    fn detects_conflict() {
        let result = apply_entry(PAGE, "10.12-10.18", "张三", Some(("<ul><li>旧</li></ul>", "<br />")), &[], &[]);
        assert!(matches!(result, Err(Error::Conflict(_))));
    }

    #[test]
    fn inserts_new_week_from_template() {
        let out = insert_week(PAGE, "10.19-10.25").unwrap();
        assert!(out.starts_with("<h1 class=\"auto-cursor-target\">10.19-10.25</h1><p>说明</p>"));
        assert!(out.ends_with(PAGE));
        let ov = overview(&out, NaiveDate::from_ymd_opt(2026, 10, 22).unwrap()).unwrap();
        assert_eq!(ov.sections[0].title, "10.19-10.25");
        assert!(ov.sections[0].covers_today);
        let e = entry(&out, "10.19-10.25", "张三").unwrap();
        assert!(e.row_found && e.content.is_empty());
        assert!(entry(&out, "10.19-10.25", "李四").unwrap().row_found);
        assert!(insert_week(&out, "10.19-10.25").is_err());
    }

    #[test]
    fn renders_nested_outline() {
        let html = render_outline(&[item(0, "a"), item(2, "b"), item(0, "c")]);
        assert_eq!(html, "<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>");
        assert_eq!(render_outline(&[]), "<br />");
    }

    #[test]
    fn parses_ranges_across_years() {
        let jan = NaiveDate::from_ymd_opt(2027, 1, 2).unwrap();
        let (start, end) = parse_range("12.29-01.04", jan).unwrap();
        assert_eq!(start, NaiveDate::from_ymd_opt(2026, 12, 29).unwrap());
        assert_eq!(end, NaiveDate::from_ymd_opt(2027, 1, 4).unwrap());
        let day = NaiveDate::from_ymd_opt(2026, 3, 4).unwrap();
        assert_eq!(week_title(day, Some("10.12-10.18")), "03.02-03.08");
        assert_eq!(week_title(day, Some("10/5 ~ 10/11 周报")), "3/2 ~ 3/8");
        assert_eq!(week_title(day, Some("第 42 周")), "03.02-03.08");
        assert_eq!(week_title(day, None), "03.02-03.08");
        assert!(parse_range("06.08-06.14（本周试行简化周报）", today()).is_some());
    }

    #[test]
    fn real_page_fixture() {
        // 用真实页面做离线验证：NEXTWORKZONE_WEEKLY_FIXTURE=<storage 文件> NEXTWORKZONE_WEEKLY_NAME=<名字>
        let (Ok(path), Ok(name)) = (std::env::var("NEXTWORKZONE_WEEKLY_FIXTURE"), std::env::var("NEXTWORKZONE_WEEKLY_NAME")) else {
            return;
        };
        let storage = std::fs::read_to_string(path).unwrap();
        let today = chrono::Local::now().date_naive();
        let ov = overview(&storage, today).unwrap();
        println!("sections: {:?}", ov.sections.iter().map(|s| &s.title).collect::<Vec<_>>());
        let title = default_section(&ov).unwrap();
        let e = entry(&storage, &title, &name).unwrap();
        println!("{title}: found={} lossy={} content={:#?}", e.row_found, e.lossy, e.content);
        assert!(e.row_found);
        let edit = apply_entry(&storage, &title, &name, Some((&e.content_raw, &e.risk_raw)), &e.content, &e.risk).unwrap();
        assert!(!edit.changed, "未修改内容时不应产生任何改动");
        let mut content = e.content.clone();
        content.push(item(0, "NextWorkZone 离线测试项"));
        let edit = apply_entry(&storage, &title, &name, None, &content, &e.risk).unwrap();
        let delta = edit.storage.len() as isize - storage.len() as isize;
        println!("修改后长度变化 {delta} 字节");
        // 变化必须局限在自己那一行的单元格内
        let prefix = storage.bytes().zip(edit.storage.bytes()).take_while(|(a, b)| a == b).count();
        let suffix = storage.bytes().rev().zip(edit.storage.bytes().rev()).take_while(|(a, b)| a == b).count();
        let changed_old = &storage[prefix..storage.len() - suffix];
        println!("原文变化窗口 {} 字节，位于 {prefix}", changed_old.len());
        assert!(e.content_raw.contains(changed_old.trim_start_matches(|c: char| c != '<')), "改动超出了自己的单元格");
        assert_eq!(entry(&edit.storage, &title, &name).unwrap().content, content);
        let created = insert_week(&storage, &ov.current_week_title).unwrap();
        println!("新建小节「{}」：新增 {} 字节", ov.current_week_title, created.len() - storage.len());
        let fresh = entry(&created, &ov.current_week_title, &name).unwrap();
        assert!(fresh.row_found && fresh.content.is_empty(), "新小节中应保留人员名单、清空内容");
    }
}
