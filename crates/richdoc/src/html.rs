//! HTML → 文档模型。
//!
//! 输入可以是 Jira、Confluence 渲染出的 HTML，Markdown 转出的 HTML，从网页粘贴的 HTML，
//! 也可以是 Wiki 编辑会话的可编辑 HTML（宏等不可编辑的内容是 `span.nwz-opaque` 占位块，
//! 布局等容器是 `.nwz-container`）。不认识的元素按其内容处理，脚本、样式等直接丢弃。

use dom_query::{Document, NodeRef};

use crate::model::{Block, Cell, Doc, Inline, Item, Opaque, Row, Task, marks};

pub fn from_html(html: &str) -> Doc {
    let doc = Document::fragment(html);
    let root = doc.root();
    // fragment 的根下是 <html> 元素
    let body = root.children().into_iter().find(|n| n.is_element() && name(n) == "html").unwrap_or(root);
    Doc { blocks: blocks_of(&body, &Ctx::default()) }
}

#[derive(Clone, Default)]
struct Ctx {
    marks: u16,
    link: Option<String>,
    color: Option<String>,
}

const BLOCK_TAGS: &[&str] = &[
    "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre", "table", "hr", "section", "article", "header", "footer", "nav", "aside",
    "figure", "figcaption", "dl", "dt", "dd", "details", "summary", "li", "tr", "td", "th", "tbody", "thead", "tfoot", "form", "center", "main", "address", "fieldset",
];

const SKIP_TAGS: &[&str] = &["script", "style", "noscript", "template", "svg", "textarea", "select", "button", "head", "title", "meta", "link", "colgroup", "col"];

fn name(n: &NodeRef) -> String {
    n.node_name().map(|s| s.to_ascii_lowercase()).unwrap_or_default()
}

/// 符合选择器的后代元素。
fn sel<'a>(n: &NodeRef<'a>, selector: &str) -> Vec<NodeRef<'a>> {
    n.descendants_it().filter(|d| d.is_element() && d.is(selector)).collect()
}

fn attr(n: &NodeRef, a: &str) -> Option<String> {
    n.attr(a).map(|s| s.to_string()).filter(|s| !s.is_empty())
}

fn is_block(n: &NodeRef) -> bool {
    if !n.is_element() {
        return false;
    }
    let tag = name(n);
    if BLOCK_TAGS.contains(&tag.as_str()) {
        return true;
    }
    // 宏等占位块（单独一行的）
    tag == "span" && n.has_class("nwz-opaque") && n.has_class("nwz-block") && !n.parent().is_some_and(|p| ["p", "li", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6"].contains(&name(&p).as_str()))
}

/// 子节点中的块；连续的行内内容合成段落。
fn blocks_of(parent: &NodeRef, ctx: &Ctx) -> Vec<Block> {
    let mut out = Vec::new();
    let mut inl = Vec::new();
    for child in parent.children() {
        if child.is_element() && SKIP_TAGS.contains(&name(&child).as_str()) {
            continue;
        }
        if is_block(&child) {
            flush(&mut inl, &mut out);
            out.extend(block_of(&child, ctx));
        } else {
            inline_of(&child, ctx, &mut inl);
        }
    }
    flush(&mut inl, &mut out);
    out
}

fn flush(inl: &mut Vec<Inline>, out: &mut Vec<Block>) {
    let mut list = std::mem::take(inl);
    trim_inlines(&mut list);
    if !list.is_empty() {
        out.push(Block::Para { inl: list });
    }
}

/// 去掉首尾空白，以及换行两侧的空格。
pub(crate) fn trim_inlines(list: &mut Vec<Inline>) {
    // 换行前后的空格
    for i in 0..list.len() {
        let next_br = matches!(list.get(i + 1), Some(Inline::Br));
        let prev_br = i > 0 && matches!(list[i - 1], Inline::Br);
        if let Inline::Text { s, .. } = &mut list[i] {
            if next_br {
                *s = s.trim_end_matches(' ').to_string();
            }
            if prev_br {
                *s = s.trim_start_matches(' ').to_string();
            }
        }
    }
    while let Some(Inline::Text { s, .. }) = list.first_mut() {
        let t = s.trim_start_matches([' ', '\n']).to_string();
        if t.is_empty() {
            list.remove(0);
        } else {
            *s = t;
            break;
        }
    }
    while let Some(last) = list.last_mut() {
        match last {
            Inline::Text { s, .. } => {
                let t = s.trim_end_matches([' ', '\n']).to_string();
                if t.is_empty() {
                    list.pop();
                } else {
                    *s = t;
                    break;
                }
            }
            Inline::Br => {
                list.pop();
            }
            _ => break,
        }
    }
    list.retain(|i| !matches!(i, Inline::Text { s, .. } if s.is_empty()));
    // 只剩空白时视为空
    if list.iter().all(|i| matches!(i, Inline::Text { s, .. } if s.trim().is_empty()) || matches!(i, Inline::Br)) {
        list.clear();
    }
}

fn block_of(el: &NodeRef, ctx: &Ctx) -> Vec<Block> {
    let tag = name(el);
    match tag.as_str() {
        "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
            let mut inl = inline_children(el, ctx);
            trim_inlines(&mut inl);
            if inl.is_empty() {
                return vec![];
            }
            vec![Block::Heading { level: tag[1..].parse().unwrap_or(1), inl, id: attr(el, "id") }]
        }
        "p" | "dt" | "dd" | "figcaption" | "summary" | "address" => {
            let ctx = if tag == "dt" { Ctx { marks: ctx.marks | marks::BOLD, ..ctx.clone() } } else { ctx.clone() };
            // 段落中意外出现的块（浏览器会拆开，这里也拆开）
            blocks_of(el, &ctx)
        }
        "ul" | "ol" => vec![list_of(el, ctx)],
        "blockquote" => {
            let blocks = blocks_of(el, ctx);
            if blocks.is_empty() { vec![] } else { vec![Block::Quote { blocks }] }
        }
        "pre" => vec![code_of(el)],
        "table" => table_of(el, ctx).into_iter().collect(),
        "hr" => vec![Block::Rule],
        "details" => {
            let title = el.children().into_iter().find(|c| name(c) == "summary").map(|s| s.text().trim().to_string()).unwrap_or_default();
            let content: Vec<Block> = el
                .children()
                .into_iter()
                .filter(|c| name(c) != "summary")
                .flat_map(|c| if is_block(&c) { block_of(&c, ctx) } else { wrap_inline(&c, ctx) })
                .collect();
            vec![Block::Panel { kind: "expand".into(), title, blocks: content }]
        }
        "span" => vec![Block::Opaque(opaque_of(el, true))],
        "div" => div_of(el, ctx),
        _ => blocks_of(el, ctx),
    }
}

fn wrap_inline(n: &NodeRef, ctx: &Ctx) -> Vec<Block> {
    let mut inl = Vec::new();
    inline_of(n, ctx, &mut inl);
    trim_inlines(&mut inl);
    if inl.is_empty() { vec![] } else { vec![Block::Para { inl }] }
}

fn div_of(el: &NodeRef, ctx: &Ctx) -> Vec<Block> {
    // Wiki 编辑：布局等容器
    if el.has_class("nwz-container") {
        let mut out = Vec::new();
        if let Some(n) = attr(el, "data-nwz-open").and_then(|v| v.parse().ok()) {
            out.push(Block::Marker { n });
        }
        out.extend(blocks_of(el, ctx));
        if let Some(n) = attr(el, "data-nwz-close").and_then(|v| v.parse().ok()) {
            out.push(Block::Marker { n });
        }
        return out;
    }
    // 目录宏：界面自己生成目录
    if el.has_class("toc-macro") || el.has_class("client-side-toc-macro") {
        return vec![];
    }
    // 代码块（Jira 的 {code}、{noformat}，Confluence 的 code 宏）
    if (el.has_class("code") || el.has_class("preformatted")) && el.has_class("panel")
        && let Some(pre) = sel(el, "pre").first() {
            return vec![code_of(pre)];
        }
    // Confluence 的信息框：info / note / warning / tip
    if el.has_class("confluence-information-macro") {
        let class = attr(el, "class").unwrap_or_default();
        let kind = if class.contains("macro-information") {
            "info"
        } else if class.contains("macro-note") {
            "note"
        } else if class.contains("macro-warning") {
            "warning"
        } else if class.contains("macro-tip") {
            "tip"
        } else {
            "info"
        };
        let title = sel(el, ".title").first().map(|t| t.text().trim().to_string()).unwrap_or_default();
        let body = sel(el, ".confluence-information-macro-body").first().cloned();
        let blocks = body.map(|b| blocks_of(&b, ctx)).unwrap_or_default();
        return vec![Block::Panel { kind: kind.into(), title, blocks }];
    }
    // 折叠块
    if el.has_class("expand-container") {
        let title = sel(el, ".expand-control-text").first().map(|t| t.text().trim().to_string()).unwrap_or_default();
        let blocks = sel(el, ".expand-content").first().map(|b| blocks_of(b, ctx)).unwrap_or_default();
        return vec![Block::Panel { kind: "expand".into(), title, blocks }];
    }
    // 面板（Jira 的 {panel}、Confluence 的 panel 宏）
    if el.has_class("panel") {
        let children = el.element_children();
        let header = children.iter().find(|c| c.has_class("panelHeader"));
        let content = children.iter().find(|c| c.has_class("panelContent"));
        let title = header.map(|h| h.text().trim().to_string()).unwrap_or_default();
        let blocks = match content {
            Some(c) => blocks_of(c, ctx),
            None => blocks_of(el, ctx),
        };
        return vec![Block::Panel { kind: "panel".into(), title, blocks }];
    }
    blocks_of(el, ctx)
}

fn list_of(el: &NodeRef, ctx: &Ctx) -> Block {
    let ordered = name(el) == "ol";
    let start = attr(el, "start").and_then(|s| s.parse().ok()).unwrap_or(0);
    let task_list = el.has_class("inline-task-list") || el.has_class("contains-task-list") || attr(el, "data-type").as_deref() == Some("taskList");
    let mut items: Vec<Item> = Vec::new();
    for child in el.children() {
        if !child.is_element() {
            if !child.text().trim().is_empty() {
                // 列表下直接出现的文字
                items.push(Item { task: None, blocks: vec![Block::para(vec![Inline::text(child.text().trim().to_string())])] });
            }
            continue;
        }
        let tag = name(&child);
        if tag == "ul" || tag == "ol" {
            // 不规范的嵌套：列表直接放在列表下
            let nested = list_of(&child, ctx);
            match items.last_mut() {
                Some(last) => last.blocks.push(nested),
                None => items.push(Item { task: None, blocks: vec![nested] }),
            }
            continue;
        }
        let mut task = None;
        if task_list || attr(&child, "data-inline-task-id").is_some() || attr(&child, "data-type").as_deref() == Some("taskItem") {
            let done = child.has_class("checked") || attr(&child, "data-checked").as_deref() == Some("true");
            task = Some(Task { done, id: attr(&child, "data-inline-task-id") });
        }
        // GitHub 风格任务列表：开头的勾选框
        if let Some(input) = sel(&child, "input[type=checkbox]").first() {
            if task.is_none() {
                task = Some(Task { done: input.has_attr("checked"), id: None });
            }
            input.remove_from_parent();
        }
        items.push(Item { task, blocks: blocks_of(&child, ctx) });
    }
    Block::List { ordered, start, items }
}

fn code_of(pre: &NodeRef) -> Block {
    let class = attr(pre, "class").unwrap_or_default();
    let code = sel(pre, "code").first().cloned();
    let code_class = code.as_ref().and_then(|c| attr(c, "class")).unwrap_or_default();
    let mut lang = class
        .split_whitespace()
        .chain(code_class.split_whitespace())
        .find_map(|c| c.strip_prefix("code-").or_else(|| c.strip_prefix("language-")).or_else(|| c.strip_prefix("lang-")))
        .unwrap_or("")
        .to_string();
    if lang.is_empty()
        && let Some(params) = attr(pre, "data-syntaxhighlighter-params")
    {
        // brush: java; gutter: false
        lang = params.split(';').find_map(|p| p.trim().strip_prefix("brush:").map(|b| b.trim().to_string())).unwrap_or_default();
    }
    let text = pre.text().to_string();
    let text = text.strip_suffix('\n').unwrap_or(&text).to_string();
    Block::Code { lang, text }
}

fn table_of(el: &NodeRef, ctx: &Ctx) -> Option<Block> {
    let mut rows = Vec::new();
    collect_rows(el, ctx, &mut rows);
    if rows.is_empty() { None } else { Some(Block::Table { rows }) }
}

fn collect_rows(el: &NodeRef, ctx: &Ctx, rows: &mut Vec<Row>) {
    for child in el.element_children() {
        match name(&child).as_str() {
            "thead" | "tbody" | "tfoot" => collect_rows(&child, ctx, rows),
            "tr" => {
                let cells = child
                    .element_children()
                    .into_iter()
                    .filter(|c| matches!(name(c).as_str(), "td" | "th"))
                    .map(|c| Cell {
                        head: name(&c) == "th",
                        blocks: blocks_of(&c, ctx),
                        colspan: attr(&c, "colspan").and_then(|v| v.parse().ok()).unwrap_or(1).max(1),
                        rowspan: attr(&c, "rowspan").and_then(|v| v.parse().ok()).unwrap_or(1).max(1),
                    })
                    .collect::<Vec<_>>();
                if !cells.is_empty() {
                    rows.push(Row { cells });
                }
            }
            _ => {}
        }
    }
}

fn inline_children(el: &NodeRef, ctx: &Ctx) -> Vec<Inline> {
    let mut inl = Vec::new();
    for child in el.children() {
        inline_of(&child, ctx, &mut inl);
    }
    inl
}

fn push_text(text: &str, ctx: &Ctx, inl: &mut Vec<Inline>) {
    // 只合并普通空白；不间断空格原样保留
    let mut collapsed = String::with_capacity(text.len());
    let mut space = false;
    for c in text.chars() {
        if matches!(c, ' ' | '\t' | '\r' | '\n' | '\x0c') {
            space = true;
        } else {
            if space {
                collapsed.push(' ');
                space = false;
            }
            collapsed.push(c);
        }
    }
    if space {
        collapsed.push(' ');
    }
    if collapsed.is_empty() {
        return;
    }
    // 与前面的空白合并
    let prev_space = match inl.last() {
        Some(Inline::Text { s, .. }) => s.ends_with(' '),
        Some(Inline::Br) | None => true,
        _ => false,
    };
    if prev_space && collapsed.starts_with(' ') {
        collapsed.remove(0);
        if collapsed.is_empty() {
            return;
        }
    }
    push_run(collapsed, ctx, inl);
}

/// 追加一段文字，与前一段格式相同时合并。
fn push_run(s: String, ctx: &Ctx, inl: &mut Vec<Inline>) {
    if let Some(Inline::Text { s: prev, m, link, color }) = inl.last_mut()
        && *m == ctx.marks
        && *link == ctx.link
        && *color == ctx.color
    {
        prev.push_str(&s);
        return;
    }
    inl.push(Inline::Text { s, m: ctx.marks, link: ctx.link.clone(), color: ctx.color.clone() });
}

fn with_marks(ctx: &Ctx, m: u16) -> Ctx {
    Ctx { marks: ctx.marks | m, ..ctx.clone() }
}

fn inline_of(node: &NodeRef, ctx: &Ctx, inl: &mut Vec<Inline>) {
    if node.is_text() {
        push_text(&node.text(), ctx, inl);
        return;
    }
    if !node.is_element() {
        return;
    }
    let tag = name(node);
    if SKIP_TAGS.contains(&tag.as_str()) {
        return;
    }
    // 行内上下文中的块（例如列表项里的段落）：按文字处理，前后断开
    if is_block(node) && tag != "span" {
        if tag == "pre" {
            if let Block::Code { text, .. } = code_of(node) {
                inl.push(Inline::Br);
                push_run(text, &with_marks(ctx, marks::CODE), inl);
                inl.push(Inline::Br);
            }
            return;
        }
        if !inl.is_empty() && !matches!(inl.last(), Some(Inline::Br)) {
            inl.push(Inline::Br);
        }
        for child in node.children() {
            inline_of(&child, ctx, inl);
        }
        return;
    }
    let children = |c: &Ctx, inl: &mut Vec<Inline>| {
        for child in node.children() {
            inline_of(&child, c, inl);
        }
    };
    match tag.as_str() {
        "br" => inl.push(Inline::Br),
        "b" | "strong" => children(&with_marks(ctx, marks::BOLD), inl),
        "i" | "em" | "cite" | "var" | "dfn" => children(&with_marks(ctx, marks::ITALIC), inl),
        "u" | "ins" => children(&with_marks(ctx, marks::UNDERLINE), inl),
        "s" | "del" | "strike" => children(&with_marks(ctx, marks::STRIKE), inl),
        "code" | "tt" | "kbd" | "samp" => children(&with_marks(ctx, marks::CODE), inl),
        "sup" => children(&with_marks(ctx, marks::SUP), inl),
        "sub" => children(&with_marks(ctx, marks::SUB), inl),
        "mark" => children(&with_marks(ctx, marks::MARK), inl),
        "font" => {
            let c = Ctx { color: attr(node, "color").and_then(|c| to_hex(&c)).or(ctx.color.clone()), ..ctx.clone() };
            children(&c, inl);
        }
        "img" => {
            if let Some(img) = image_of(node) {
                inl.push(img);
            }
        }
        "input" => {
            if attr(node, "type").as_deref() == Some("checkbox") {
                push_run(if node.has_attr("checked") { "☑ ".into() } else { "☐ ".into() }, ctx, inl);
            }
        }
        "a" => anchor_of(node, ctx, inl),
        "span" => span_of(node, ctx, inl),
        _ => children(&styled(node, ctx), inl),
    }
}

/// 粘贴进来的内容常用 style 表达格式（如 `<span style="font-weight:bold">`）。
fn styled(node: &NodeRef, ctx: &Ctx) -> Ctx {
    let Some(style) = attr(node, "style") else { return ctx.clone() };
    let mut c = ctx.clone();
    for decl in style.split(';') {
        let Some((k, v)) = decl.split_once(':') else { continue };
        let (k, v) = (k.trim().to_ascii_lowercase(), v.trim().to_ascii_lowercase());
        match k.as_str() {
            "color" => {
                if let Some(hex) = to_hex(&v) {
                    c.color = Some(hex);
                }
            }
            "font-weight" if v == "bold" || v.parse::<u32>().is_ok_and(|w| w >= 600) => c.marks |= marks::BOLD,
            "font-style" if v == "italic" => c.marks |= marks::ITALIC,
            "text-decoration" | "text-decoration-line" => {
                if v.contains("underline") {
                    c.marks |= marks::UNDERLINE;
                }
                if v.contains("line-through") {
                    c.marks |= marks::STRIKE;
                }
            }
            _ => {}
        }
    }
    c
}

fn span_of(node: &NodeRef, ctx: &Ctx, inl: &mut Vec<Inline>) {
    if node.has_class("nwz-opaque") {
        inl.push(Inline::Opaque(opaque_of(node, false)));
        return;
    }
    if node.has_class("nwz-container") {
        if let Some(n) = attr(node, "data-nwz-open").and_then(|v| v.parse().ok()) {
            inl.push(Inline::Marker { n });
        }
        for child in node.children() {
            inline_of(&child, ctx, inl);
        }
        if let Some(n) = attr(node, "data-nwz-close").and_then(|v| v.parse().ok()) {
            inl.push(Inline::Marker { n });
        }
        return;
    }
    // Confluence 的 Jira 宏
    if let Some(key) = attr(node, "data-jira-key")
        && (node.has_class("jira-issue") || node.has_class("nwz-jira") || node.has_class("static-jira-issues_2"))
    {
        inl.push(Inline::Issue { key });
        return;
    }
    if node.has_class("aui-icon") || node.has_class("icon") && node.text().trim().is_empty() {
        return;
    }
    if node.has_class("status-macro") || node.has_class("aui-lozenge") || node.has_class("jira-issue-status-lozenge") {
        let class = attr(node, "class").unwrap_or_default();
        let color = if class.contains("success") {
            "green"
        } else if class.contains("error") {
            "red"
        } else if class.contains("current") || class.contains("moved") {
            "yellow"
        } else if class.contains("complete") {
            "blue"
        } else {
            "grey"
        };
        inl.push(Inline::Status { text: node.text().trim().to_string(), color: color.into() });
        return;
    }
    for child in node.children() {
        inline_of(&child, &styled(node, ctx), inl);
    }
}

fn opaque_of(node: &NodeRef, block: bool) -> Opaque {
    let n = attr(node, "data-nwz").and_then(|v| v.parse().ok()).unwrap_or(usize::MAX);
    let lines: Vec<String> = sel(node, ".nwz-line").iter().map(|l| l.text().trim().to_string()).collect();
    let title = sel(node, ".nwz-macro-title").first().map(|t| t.text().trim().to_string());
    let code = sel(node, ".nwz-code").first().map(|t| t.text().to_string());
    let label = if let Some(code) = code {
        [title.unwrap_or_default(), code].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n")
    } else if !lines.is_empty() {
        [title.unwrap_or_default()].into_iter().chain(lines).filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n")
    } else {
        node.text().trim().to_string()
    };
    let image = sel(node, "img")
        .first()
        .and_then(|img| attr(img, "data-nwz-attachment").map(|f| format!("attachment:{f}")).or_else(|| attr(img, "data-nwz-url")));
    let user = sel(node, "[data-nwz-user]").first().and_then(|u| attr(u, "data-nwz-user"));
    let issue = sel(node, "[data-jira-key]").first().and_then(|u| attr(u, "data-jira-key"));
    Opaque { n, label, block: block || node.has_class("nwz-block"), image, user, issue }
}

const IMAGE_EXT: &[&str] = &[".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg"];

fn is_image_url(url: &str) -> bool {
    let path = url.split(['?', '#']).next().unwrap_or("").to_ascii_lowercase();
    IMAGE_EXT.iter().any(|e| path.ends_with(e))
}

fn image_of(img: &NodeRef) -> Option<Inline> {
    let src = attr(img, "src").or_else(|| attr(img, "data-src"))?;
    let anchor = img.ancestors_it(Some(3)).find(|a| name(a) == "a");
    let href = anchor.as_ref().and_then(|a| attr(a, "href"));
    let full = attr(img, "data-image-src").or_else(|| href.clone().filter(|h| is_image_url(h)));
    // Jira 附件图片：外层链接上的文件名，或地址中的文件名
    let from_link = anchor
        .as_ref()
        .and_then(|a| attr(a, "file-preview-title").or_else(|| if href.as_deref().is_some_and(|h| h.contains("/secure/attachment/")) { attr(a, "title") } else { None }));
    let from_src = attachment_name(&src);
    let file = attr(img, "data-filename").or(from_link).or(from_src);
    Some(Inline::Image {
        thumb: src.contains("/secure/thumbnail/") || attr(img, "data-thumb").is_some(),
        alt: attr(img, "alt").unwrap_or_default(),
        width: attr(img, "width").and_then(|w| w.trim_end_matches("px").parse().ok()),
        height: attr(img, "height").and_then(|w| w.trim_end_matches("px").parse().ok()),
        full,
        file,
        src,
    })
}

/// `/secure/attachment/123/123_x.png` 中的文件名。
fn attachment_name(src: &str) -> Option<String> {
    let rest = src.split("/secure/attachment/").nth(1)?;
    let mut parts = rest.splitn(2, '/');
    let id = parts.next()?;
    let file = parts.next()?.split(['?', '#']).next()?;
    let name = file.strip_prefix(&format!("{id}_"))?;
    Some(percent_decode(name))
}

pub(crate) fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16)
        {
            out.push(b);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn anchor_of(a: &NodeRef, ctx: &Ctx, inl: &mut Vec<Inline>) {
    // @提及
    if a.has_class("user-hover") || a.has_class("confluence-userlink") || a.has_attr("data-username") {
        let user = attr(a, "data-username").or_else(|| attr(a, "rel")).unwrap_or_default();
        let name = a.text().trim().trim_start_matches('@').to_string();
        if !name.is_empty() {
            inl.push(Inline::Mention { name, user });
            return;
        }
    }
    // 拖进编辑器、待上传的附件
    if let Some(file) = attr(a, "data-attachment") {
        inl.push(Inline::Attachment { file });
        return;
    }
    let href = attr(a, "href").filter(|h| !h.starts_with("javascript:"));
    // 附件图片外面包着的预览链接：只保留图片
    if !sel(a, "img").is_empty() && a.text().trim().is_empty() {
        for child in a.children() {
            inline_of(&child, ctx, inl);
        }
        return;
    }
    let c = Ctx { link: href.or(ctx.link.clone()), ..ctx.clone() };
    for child in a.children() {
        inline_of(&child, &c, inl);
    }
}

/// 颜色转为 #rrggbb；黑色、默认的深灰（正文颜色）视为没有颜色。
pub(crate) fn to_hex(color: &str) -> Option<String> {
    let c = color.trim().to_ascii_lowercase();
    let hex = if c.len() == 7 && c.starts_with('#') && c[1..].chars().all(|ch| ch.is_ascii_hexdigit()) {
        c
    } else if c.len() == 4 && c.starts_with('#') && c[1..].chars().all(|ch| ch.is_ascii_hexdigit()) {
        format!("#{}", c[1..].chars().flat_map(|ch| [ch, ch]).collect::<String>())
    } else if let Some(inner) = c.strip_prefix("rgb(").or_else(|| c.strip_prefix("rgba(")) {
        let nums: Vec<u8> = inner.trim_end_matches(')').split(',').take(3).filter_map(|n| n.trim().parse().ok()).collect();
        if nums.len() != 3 {
            return None;
        }
        format!("#{:02x}{:02x}{:02x}", nums[0], nums[1], nums[2])
    } else if !c.is_empty() && c.chars().all(|ch| ch.is_ascii_alphabetic()) {
        return if matches!(c.as_str(), "black" | "inherit" | "initial" | "currentcolor") { None } else { Some(c) };
    } else {
        return None;
    };
    if matches!(hex.as_str(), "#000000" | "#333333" | "#172b4d") { None } else { Some(hex) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn para(doc: &Doc) -> &Vec<Inline> {
        match &doc.blocks[0] {
            Block::Para { inl } => inl,
            b => panic!("不是段落：{b:?}"),
        }
    }

    #[test]
    fn collapses_whitespace_and_merges_runs() {
        let doc = from_html("<p>  a \n b <b>c</b><b> d</b></p>");
        assert_eq!(para(&doc), &vec![Inline::text("a b "), Inline::Text { s: "c d".into(), m: marks::BOLD, link: None, color: None }]);
    }

    #[test]
    fn lists_tasks_and_nesting() {
        let doc = from_html(r#"<ul class="inline-task-list"><li data-inline-task-id="3" class="checked">done</li><li data-inline-task-id="4">todo<ul><li>sub</li></ul></li></ul>"#);
        let Block::List { items, .. } = &doc.blocks[0] else { panic!() };
        assert_eq!(items[0].task, Some(Task { done: true, id: Some("3".into()) }));
        assert!(!items[1].task.as_ref().unwrap().done);
        assert!(matches!(items[1].blocks[1], Block::List { .. }));
    }

    #[test]
    fn jira_code_panel_and_attachment_image() {
        let doc = from_html(r#"<div class="code panel"><div class="codeContent panelContent"><pre class="code-java">int a = 1;
</pre></div></div><p><span class="image-wrap"><a file-preview-title="x.png" href="/secure/attachment/1/1_x.png"><img src="/secure/thumbnail/1/_thumb_1.png"></a></span></p>"#);
        assert_eq!(doc.blocks[0], Block::Code { lang: "java".into(), text: "int a = 1;".into() });
        let Inline::Image { file, thumb, full, .. } = &para_at(&doc, 1)[0] else { panic!() };
        assert_eq!(file.as_deref(), Some("x.png"));
        assert!(*thumb);
        assert_eq!(full.as_deref(), Some("/secure/attachment/1/1_x.png"));
    }

    fn para_at(doc: &Doc, i: usize) -> &Vec<Inline> {
        match &doc.blocks[i] {
            Block::Para { inl } => inl,
            b => panic!("不是段落：{b:?}"),
        }
    }

    #[test]
    fn wiki_editor_placeholders() {
        let doc = from_html(r#"<div class="nwz-container" data-nwz-open="0" data-nwz-close="1"><p>文字 <span class="nwz-opaque" contenteditable="false" data-nwz="2"><span class="nwz-jira" data-jira-key="AB-1">AB-1</span></span></p><span class="nwz-opaque nwz-block" data-nwz="3"><span class="nwz-macro-title">信息</span><span class="nwz-line">一行</span></span></div>"#);
        assert_eq!(doc.blocks[0], Block::Marker { n: 0 });
        let Block::Para { inl } = &doc.blocks[1] else { panic!() };
        assert!(matches!(&inl[1], Inline::Opaque(o) if o.n == 2 && o.issue.as_deref() == Some("AB-1")));
        assert!(matches!(&doc.blocks[2], Block::Opaque(o) if o.n == 3 && o.label == "信息\n一行"));
        assert_eq!(doc.blocks[3], Block::Marker { n: 1 });
    }

    #[test]
    fn colors_and_styles() {
        assert_eq!(to_hex("rgb(255, 0, 0)").as_deref(), Some("#ff0000"));
        assert_eq!(to_hex("#abc").as_deref(), Some("#aabbcc"));
        assert_eq!(to_hex("#000000"), None);
        let doc = from_html(r#"<p><span style="font-weight: 700; color: #ff0000">x</span></p>"#);
        assert_eq!(para(&doc)[0], Inline::Text { s: "x".into(), m: marks::BOLD, link: None, color: Some("#ff0000".into()) });
    }
}
