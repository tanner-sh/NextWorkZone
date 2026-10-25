import AppKit

/// 只读富文本的右键菜单：按右键的位置给出选中的文字、链接、图片、代码块各自的操作。
/// 指向问题、Wiki 页面的链接显示与列表中右键这个对象相同的菜单。
@MainActor
enum RichContextMenu {
    private static let issueKey = /^[A-Z][A-Z0-9_]+-\d+$/

    /// 没有可用的操作时返回空数组（使用系统的菜单）。
    static func specs(_ textView: NSTextView, at point: NSPoint, service: Service) -> [MenuSpec] {
        var groups: [[MenuSpec]] = []
        let index = characterIndex(textView, at: point)
        let selection = textView.selectedRange()
        if selection.length > 0, let index, NSLocationInRange(index, selection) {
            let text = plain((textView.string as NSString).substring(with: selection)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { groups.append(selectionSpecs(text, service: service)) }
        }
        if let index, let storage = textView.textStorage, index < storage.length {
            var range = NSRange()
            if let link = storage.attribute(.link, at: index, effectiveRange: &range) {
                let href = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
                let text = plain((storage.string as NSString).substring(with: range)).trimmingCharacters(in: .whitespacesAndNewlines)
                let specs = linkSpecs(href, text: text, service: service)
                if !specs.isEmpty { groups.append(specs) }
            }
            if let image = storage.attribute(.attachment, at: index, effectiveRange: nil) as? RemoteImageAttachment {
                groups.append(imageSpecs(image, service: service))
            }
            if let code = storage.attribute(.nwzCode, at: index, effectiveRange: nil) as? String {
                groups.append([copy("复制代码块", code, icon: "chevron.left.forwardslash.chevron.right")])
            }
        }
        return groups.enumerated().flatMap { $0.offset > 0 ? [.separator] + $0.element : $0.element }
    }

    /// 右键位置所在的字符；不在文字上（行尾之后的空白处）时为 nil。
    private static func characterIndex(_ textView: NSTextView, at point: NSPoint) -> Int? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let origin = textView.textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs, layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    /// 代码块中的换行在显示时换成了行分隔符；附件字符不属于文字。
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// 菜单标签中引用的文字：太长时截断。
    private static func quote(_ text: String) -> String {
        let line = text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 16 ? String(line.prefix(16)) + "…" : line
    }

    private static func copy(_ label: String, _ text: String, icon: String = "doc.on.doc") -> MenuSpec {
        .action(label, icon: icon) {
            Pasteboard.copy(text)
            toast("已复制")
        }
    }

    /// 选中的文字：复制，搜索，记为待办（第一行作标题，其余作备注）；是问题键时附上问题菜单。
    private static func selectionSpecs(_ text: String, service: Service) -> [MenuSpec] {
        let single = text.components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces)
        var specs: [MenuSpec] = [copy("复制", text)]
        if text.wholeMatch(of: issueKey) != nil { specs.append(.submenu("问题 \(text)", children: IssueMenu.shared.specs(.key(text, summary: nil)))) }
        if text.wholeMatch(of: /https?:\/\/\S+/) != nil { specs.append(.action("打开链接", icon: "link") { RichLinks.open(text, service: service) }) }
        specs.append(.separator)
        let model = AppModel.shared
        if !model.baseUrl(.jira).isEmpty {
            // 引号和反斜杠在 JQL 字符串中需要转义，直接换成空格
            let words = single.replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "\\", with: " ")
            let jql = "text ~ \"\(words)\" ORDER BY updated DESC"
            specs.append(.action("在 Jira 中搜索“\(quote(text))”", icon: "magnifyingglass") { model.navigate(NavTarget(.jira, jql: jql)) })
        }
        if !model.baseUrl(.confluence).isEmpty {
            specs.append(.action("在 Wiki 中搜索“\(quote(text))”", icon: "magnifyingglass") { model.navigate(NavTarget(.wiki, wikiSearch: single)) })
        }
        specs.append(.separator)
        specs.append(.action("添加为待办", icon: "checkmark.square") {
            guarded {
                let notes = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await API.shared.wsSaveTodo(TodoInput(title: String(single.prefix(200)), notes: notes))
                Events.workspaceChanged()
                toast("已添加待办")
            }
        })
        return specs
    }

    /// 链接：系统中的问题和 Wiki 页面显示它们的菜单，其他链接打开或复制。
    private static func linkSpecs(_ href: String, text: String, service: Service) -> [MenuSpec] {
        if href.hasPrefix("nwz-issue:") {
            return IssueMenu.shared.specs(.key(String(href.dropFirst(10)), summary: nil))
        }
        if href.hasPrefix("ws://doc/") {
            return [.action("打开", icon: "doc.text") { RichLinks.open(href, service: service) }]
        }
        guard href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("mailto:") else { return [] }
        let copyText: MenuSpec? = !text.isEmpty && text != href ? copy("复制链接文字", text) : nil
        let route = Links.route(href, baseUrl: { AppModel.shared.baseUrl($0) })
        if case .target(let target)? = route {
            if let key = target.issueKey {
                return IssueMenu.shared.specs(.key(key, summary: nil)) + (text != key ? [.separator] + [copyText].compactMap { $0 } : [])
            }
            if let page = target.wikiPage, page.wholeMatch(of: /\d+/) != nil {
                return WikiMenus.page(id: page) + [.separator] + [copyText].compactMap { $0 }
            }
        }
        let attachment = RichLinks.isAttachment(href)
        var specs: [MenuSpec] = [.action(attachment ? "预览附件" : route != nil ? "在应用内打开" : "打开链接", icon: "link") { RichLinks.open(href, service: service) }]
        if route != nil || attachment { specs.append(.action("在浏览器中打开", icon: "safari") { Links.openInBrowser(href) }) }
        specs.append(.separator)
        specs.append(href.hasPrefix("mailto:") ? copy("复制邮件地址", String(href.dropFirst(7))) : copy("复制链接", href, icon: "link"))
        if let copyText { specs.append(copyText) }
        specs.append(copy("复制为 Markdown 链接", "[\(text.isEmpty ? href : text)](\(href))"))
        return specs
    }

    private static func imageSpecs(_ image: RemoteImageAttachment, service: Service) -> [MenuSpec] {
        let src = RichRenderer(service: service).absolute(image.info.full ?? image.info.src)
        return [
            .action("查看大图", icon: "arrow.up.left.and.arrow.down.right") { ImageViewer.show(src: src, service: service, alt: image.info.alt ?? "") },
            .action("复制图片", icon: "photo", disabled: !image.loaded) {
                guard let picture = image.image else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([picture])
                toast("已复制图片")
            },
        ]
    }
}
