import Foundation

public enum HTML {
    public static func parse(_ source: String) -> RichDoc { .init(blocks: blocks(HTMLNode.parse(source), context: .init())) }
    public static func markdown(_ source: String, baseURL: String) -> String {
        var doc = parse(source); doc.absolutize(baseURL: baseURL)
        return Markdown.write(doc)
    }
    struct Context {
        var marks: Marks = []
        var link: String?
        var color: String?
        var parents: [HTMLNode] = []
        var hideCheckboxes = false
        func adding(_ mark: Marks) -> Self { var copy = self; copy.marks.formUnion(mark); return copy }
        func parent(_ node: HTMLNode) -> Self { var copy = self; copy.parents = [node] + parents.prefix(2); return copy }
    }
    static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre", "table", "hr", "section", "article", "header", "footer", "nav", "aside", "figure", "figcaption", "dl", "dt", "dd", "details", "summary", "li", "tr", "td", "th", "tbody", "thead", "tfoot", "form", "center", "main", "address", "fieldset"]
    static let skipTags: Set<String> = ["script", "style", "noscript", "template", "svg", "textarea", "select", "button", "head", "title", "meta", "link", "colgroup", "col"]
    static func isBlock(_ node: HTMLNode, parent: HTMLNode? = nil) -> Bool {
        blockTags.contains(node.tag) || node.tag == "span" && node.hasClass("nwz-opaque") && node.hasClass("nwz-block") && !["p", "li", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6"].contains(parent?.tag ?? "")
    }
    static func blocks(_ parent: HTMLNode, context: Context) -> [RichBlock] {
        var output: [RichBlock] = [], inline: [RichInline] = []
        func flush() { trim(&inline); if !inline.isEmpty { output.append(.para(inline)) }; inline = [] }
        for child in parent.children {
            if skipTags.contains(child.tag) { continue }
            if isBlock(child, parent: parent) { flush(); output += block(child, context: context.parent(parent)) }
            else { appendInline(child, context: context.parent(parent), to: &inline) }
        }
        flush()
        return output
    }
    static func trim(_ content: inout [RichInline]) {
        func changed(_ item: RichInline, text: String) -> RichInline {
            guard case .text(_, let marks, let link, let color) = item else { return item }
            return .text(text, marks, link: link, color: color)
        }
        for index in content.indices {
            guard case .text(var text, _, _, _) = content[index] else { continue }
            if index + 1 < content.count && content[index + 1] == .br { text = String(text.reversed().drop(while: { $0 == " " }).reversed()) }
            if index > 0 && content[index - 1] == .br { text = String(text.drop(while: { $0 == " " })) }
            content[index] = changed(content[index], text: text)
        }
        while case .text(let text, _, _, _) = content.first {
            let value = String(text.drop(while: { $0 == " " || $0 == "\n" }))
            if value.isEmpty { content.removeFirst() } else { content[0] = changed(content[0], text: value); break }
        }
        while let last = content.last {
            if last == .br { content.removeLast(); continue }
            guard case .text(let text, _, _, _) = last else { break }
            let value = String(text.reversed().drop(while: { $0 == " " || $0 == "\n" }).reversed())
            if value.isEmpty { content.removeLast() } else { content[content.count - 1] = changed(last, text: value); break }
        }
        content.removeAll { if case .text(let text, _, _, _) = $0 { return text.isEmpty }; return false }
        if content.allSatisfy({ item in if case .text(let text, _, _, _) = item { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return item == .br }) { content = [] }
    }
    static func block(_ node: HTMLNode, context: Context) -> [RichBlock] {
        switch node.tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            var content = inlineChildren(node, context: context); trim(&content)
            return content.isEmpty ? [] : [.heading(level: Int(node.tag.dropFirst()) ?? 1, content, id: node.attribute("id"))]
        case "p", "dt", "dd", "figcaption", "summary", "address": return blocks(node, context: node.tag == "dt" ? context.adding(.bold) : context)
        case "ul", "ol": return [list(node, context: context)]
        case "blockquote":
            let content = blocks(node, context: context)
            return content.isEmpty ? [] : [.quote(content)]
        case "pre": return [code(node)]
        case "table":
            let rows = tableRows(node, context: context)
            return rows.isEmpty ? [] : [.table(rows)]
        case "hr": return [.rule]
        case "span": return [.opaque(opaque(node, block: true))]
        case "details":
            let title = node.children.first { $0.tag == "summary" }?.trimmed ?? ""
            var copy = node; copy.children.removeAll { $0.tag == "summary" }
            return [.panel(kind: "expand", title: title, blocks: blocks(copy, context: context))]
        case "div":
            if node.hasClass("nwz-container") {
                var output: [RichBlock] = []
                if let value = node.attribute("data-nwz-open").flatMap(Int.init) { output.append(.marker(value)) }
                output += blocks(node, context: context)
                if let value = node.attribute("data-nwz-close").flatMap(Int.init) { output.append(.marker(value)) }
                return output
            }
            if node.hasClass("toc-macro") || node.hasClass("client-side-toc-macro") { return [] }
            if (node.hasClass("code") || node.hasClass("preformatted")) && node.hasClass("panel"), let pre = node.first(where: { $0.tag == "pre" }) { return [code(pre)] }
            if node.hasClass("confluence-information-macro") {
                let classes = node.attribute("class") ?? ""
                let kind = classes.contains("macro-note") ? "note" : classes.contains("macro-warning") ? "warning" : classes.contains("macro-tip") ? "tip" : "info"
                let title = node.first { $0.hasClass("title") }?.trimmed ?? ""
                let content = node.first { $0.hasClass("confluence-information-macro-body") }.map { blocks($0, context: context) } ?? []
                return [.panel(kind: kind, title: title, blocks: content)]
            }
            if node.hasClass("expand-container") {
                let title = node.first { $0.hasClass("expand-control-text") }?.trimmed ?? ""
                return [.panel(kind: "expand", title: title, blocks: node.first { $0.hasClass("expand-content") }.map { blocks($0, context: context) } ?? [])]
            }
            if node.hasClass("panel") {
                let title = node.children.first { $0.hasClass("panelHeader") }?.trimmed ?? ""
                let content = node.children.first { $0.hasClass("panelContent") } ?? node
                return [.panel(kind: "panel", title: title, blocks: blocks(content, context: context))]
            }
            return blocks(node, context: context)
        default: return blocks(node, context: context)
        }
    }
    static func list(_ node: HTMLNode, context: Context) -> RichBlock {
        let taskList = node.hasClass("inline-task-list") || node.hasClass("contains-task-list") || node.attribute("data-type") == "taskList"
        var items: [RichItem] = []
        for child in node.children {
            if child.isText {
                if !child.trimmed.isEmpty { items.append(.init(blocks: [.para([.text(child.trimmed, [], link: nil, color: nil)])])) }
                continue
            }
            if child.tag == "ul" || child.tag == "ol" {
                let nested = list(child, context: context)
                if !items.isEmpty { items[items.count - 1].blocks.append(nested) } else { items.append(.init(blocks: [nested])) }
                continue
            }
            var task: RichTask?
            if taskList || child.attribute("data-inline-task-id") != nil || child.attribute("data-type") == "taskItem" {
                task = .init(done: child.hasClass("checked") || child.attribute("data-checked") == "true", id: child.attribute("data-inline-task-id"))
            }
            if task == nil, let checkbox = child.first(where: { $0.tag == "input" && $0.attribute("type") == "checkbox" }) { task = .init(done: checkbox.attributes["checked"] != nil) }
            var context = context; context.hideCheckboxes = true
            items.append(.init(task: task, blocks: blocks(child, context: context)))
        }
        return .list(ordered: node.tag == "ol", start: node.attribute("start").flatMap(Int.init) ?? 0, items: items)
    }
    static func code(_ node: HTMLNode) -> RichBlock {
        let classes = (node.attribute("class") ?? "") + " " + (node.first { $0.tag == "code" }?.attribute("class") ?? "")
        var language = ""
        for item in classes.split(whereSeparator: \.isWhitespace) {
            for prefix in ["code-", "language-", "lang-"] where item.hasPrefix(prefix) { language = String(item.dropFirst(prefix.count)); break }
            if !language.isEmpty { break }
        }
        if language.isEmpty, let parameters = node.attribute("data-syntaxhighlighter-params") {
            language = parameters.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("brush:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        var text = node.content
        if text.hasSuffix("\n") { text.removeLast() }
        return .code(lang: language, text: text)
    }
    static func tableRows(_ node: HTMLNode, context: Context) -> [RichRow] {
        node.children.flatMap { child -> [RichRow] in
            if ["thead", "tbody", "tfoot"].contains(child.tag) { return tableRows(child, context: context) }
            guard child.tag == "tr" else { return [] }
            let cells = child.children.filter { $0.tag == "td" || $0.tag == "th" }.map { cell in
                RichCell(head: cell.tag == "th", blocks: blocks(cell, context: context), colspan: max(1, cell.attribute("colspan").flatMap(Int.init) ?? 1), rowspan: max(1, cell.attribute("rowspan").flatMap(Int.init) ?? 1))
            }
            return cells.isEmpty ? [] : [.init(cells: cells)]
        }
    }
}
