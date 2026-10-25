import Foundation

extension HTML {
    static func inlineChildren(_ node: HTMLNode, context: Context) -> [RichInline] {
        var result: [RichInline] = []
        for child in node.children { appendInline(child, context: context.parent(node), to: &result) }
        return result
    }
    static func pushRun(_ text: String, context: Context, to result: inout [RichInline]) {
        if case .text(let previous, let marks, let link, let color) = result.last, marks == context.marks, link == context.link, color == context.color {
            result[result.count - 1] = .text(previous + text, marks, link: link, color: color)
        } else { result.append(.text(text, context.marks, link: context.link, color: context.color)) }
    }
    static func pushText(_ text: String, context: Context, to result: inout [RichInline]) {
        var collapsed = "", space = false
        for character in text {
            if [" ", "\t", "\r", "\n", "\r\n", "\u{c}"].contains(character) { space = true }
            else { if space { collapsed += " "; space = false }; collapsed.append(character) }
        }
        if space { collapsed += " " }
        let previousSpace: Bool
        switch result.last { case .text(let text, _, _, _): previousSpace = text.hasSuffix(" "); case .br, nil: previousSpace = true; default: previousSpace = false }
        if previousSpace && collapsed.hasPrefix(" ") { collapsed.removeFirst() }
        if !collapsed.isEmpty { pushRun(collapsed, context: context, to: &result) }
    }
    static func appendInline(_ node: HTMLNode, context: Context, to result: inout [RichInline]) {
        if node.isText { pushText(node.text, context: context, to: &result); return }
        if skipTags.contains(node.tag) { return }
        if isBlock(node, parent: context.parents.first), node.tag != "span" {
            if node.tag == "pre", case .code(_, let text) = code(node) {
                result.append(.br); pushRun(text, context: context.adding(.code), to: &result); result.append(.br); return
            }
            if !result.isEmpty && result.last != .br { result.append(.br) }
            for child in node.children { appendInline(child, context: context.parent(node), to: &result) }
            return
        }
        let mark: Marks? = switch node.tag {
        case "b", "strong": .bold
        case "i", "em", "cite", "var", "dfn": .italic
        case "u", "ins": .underline
        case "s", "del", "strike": .strike
        case "code", "tt", "kbd", "samp": .code
        case "sup": .sup
        case "sub": .sub
        case "mark": .mark
        default: nil
        }
        var next = mark.map(context.adding) ?? styled(node, context: context)
        switch node.tag {
        case "br": result.append(.br); return
        case "font": next.color = node.attribute("color").flatMap(color) ?? context.color
        case "img": if let image = image(node, context: context) { result.append(.image(image)) }; return
        case "input":
            if !context.hideCheckboxes && node.attribute("type") == "checkbox" { pushRun(node.attributes["checked"] != nil ? "☑ " : "☐ ", context: context, to: &result) }
            return
        case "a":
            if node.hasClass("user-hover") || node.hasClass("confluence-userlink") || node.attributes["data-username"] != nil {
                let name = String(node.trimmed.drop(while: { $0 == "@" }))
                if !name.isEmpty { result.append(.mention(name: name, user: node.attribute("data-username") ?? node.attribute("rel") ?? "")); return }
            }
            if let file = node.attribute("data-attachment") { result.append(.attachment(file)); return }
            if node.first(where: { $0.tag == "img" }) == nil || !node.trimmed.isEmpty {
                let href = node.attribute("href").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("javascript:") ? nil : $0 }
                next.link = href ?? context.link
            }
        case "span":
            if node.hasClass("nwz-opaque") { result.append(.opaque(opaque(node, block: false))); return }
            if node.hasClass("nwz-container") {
                if let index = node.attribute("data-nwz-open").flatMap(Int.init) { result.append(.marker(index)) }
                for child in node.children { appendInline(child, context: context.parent(node), to: &result) }
                if let index = node.attribute("data-nwz-close").flatMap(Int.init) { result.append(.marker(index)) }
                return
            }
            if let key = node.attribute("data-jira-key"), node.hasClass("jira-issue") || node.hasClass("nwz-jira") || node.hasClass("static-jira-issues_2") { result.append(.issue(key)); return }
            if node.hasClass("aui-icon") || node.hasClass("icon") && node.trimmed.isEmpty { return }
            if node.hasClass("status-macro") || node.hasClass("aui-lozenge") || node.hasClass("jira-issue-status-lozenge") {
                let classes = node.attribute("class") ?? ""
                let color = classes.contains("success") ? "green" : classes.contains("error") ? "red" : classes.contains("current") || classes.contains("moved") ? "yellow" : classes.contains("complete") ? "blue" : "grey"
                result.append(.status(text: node.trimmed, color: color)); return
            }
        default: break
        }
        for child in node.children { appendInline(child, context: next.parent(node), to: &result) }
    }
    static func styled(_ node: HTMLNode, context: Context) -> Context {
        var result = context
        for declaration in (node.attribute("style") ?? "").split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased(), value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            switch key {
            case "color": result.color = color(value) ?? result.color
            case "font-weight": if value == "bold" || (Int(value) ?? 0) >= 600 { result.marks.insert(.bold) }
            case "font-style": if value == "italic" { result.marks.insert(.italic) }
            case "text-decoration", "text-decoration-line":
                if value.contains("underline") { result.marks.insert(.underline) }
                if value.contains("line-through") { result.marks.insert(.strike) }
            default: break
            }
        }
        return result
    }
    static func opaque(_ node: HTMLNode, block: Bool) -> RichOpaque {
        let lines = node.descendants { $0.hasClass("nwz-line") }.map(\.trimmed)
        let title = node.first { $0.hasClass("nwz-macro-title") }?.trimmed ?? ""
        let code = node.first { $0.hasClass("nwz-code") }?.content
        let label: String
        if let code { label = [title, code].filter { !$0.isEmpty }.joined(separator: "\n") }
        else if !lines.isEmpty { label = ([title] + lines).filter { !$0.isEmpty }.joined(separator: "\n") }
        else { label = node.trimmed }
        let image = node.first { $0.tag == "img" }
        let imageURL = image?.attribute("data-nwz-attachment").map { "attachment:" + $0 } ?? image?.attribute("data-nwz-url")
        return .init(n: node.attribute("data-nwz").flatMap(Int.init) ?? Int.max, label: label, block: block || node.hasClass("nwz-block"), image: imageURL, user: node.first { $0.attributes["data-nwz-user"] != nil }?.attribute("data-nwz-user"), issue: node.first { $0.attributes["data-jira-key"] != nil }?.attribute("data-jira-key"))
    }
    static func image(_ node: HTMLNode, context: Context) -> RichImage? {
        guard let source = node.attribute("src") ?? node.attribute("data-src") else { return nil }
        let anchor = context.parents.first { $0.tag == "a" }, href = anchor?.attribute("href")
        let full = node.attribute("data-image-src") ?? href.flatMap { address -> String? in
            let path = address.split(whereSeparator: { $0 == "?" || $0 == "#" }).first?.lowercased() ?? ""
            return [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg"].contains { path.hasSuffix($0) } ? address : nil
        }
        var file = node.attribute("data-filename") ?? anchor?.attribute("file-preview-title")
        if file == nil && href?.contains("/secure/attachment/") == true { file = anchor?.attribute("title") }
        if file == nil, let range = source.range(of: "/secure/attachment/") {
            let parts = source[range.upperBound...].split(separator: "/", maxSplits: 1)
            if parts.count == 2, let name = parts[1].split(whereSeparator: { $0 == "?" || $0 == "#" }).first, name.hasPrefix(parts[0] + "_") { file = String(name.dropFirst(parts[0].count + 1)).removingPercentEncoding }
        }
        func dimension(_ value: String?) -> Int? { value.flatMap { Int($0.hasSuffix("px") ? String($0.dropLast(2)) : $0) } }
        return .init(src: source, alt: node.attribute("alt") ?? "", full: full, file: file, thumb: source.contains("/secure/thumbnail/") || node.attribute("data-thumb") != nil, width: dimension(node.attribute("width")), height: dimension(node.attribute("height")))
    }
    public static func color(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hex: String
        if value.hasPrefix("#"), [4, 7].contains(value.count), value.dropFirst().allSatisfy(\.isHexDigit) {
            hex = value.count == 7 ? value : "#" + value.dropFirst().map { String(repeating: String($0), count: 2) }.joined()
        } else if value.hasPrefix("rgb(") || value.hasPrefix("rgba(") {
            let numbers = value.drop(while: { $0 != "(" }).dropFirst().dropLast().split(separator: ",").prefix(3).compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 3 else { return nil }
            hex = String(format: "#%02x%02x%02x", numbers[0], numbers[1], numbers[2])
        } else if !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isLetter }) {
            return ["black", "inherit", "initial", "currentcolor"].contains(value) ? nil : value
        } else { return nil }
        return ["#000000", "#333333", "#172b4d"].contains(hex) ? nil : hex
    }
}
