import Foundation

/// 把外部内容沉淀为知识库页面：Jira 问题（描述、解决方案等富文本字段、评论）、Wiki 页面。与 src/pages/workspace/kbImport.ts 相同。
@MainActor
enum KBImport {
    /// 由 Jira 问题生成知识库页面并保存，返回新页面。
    static func issueToPage(_ key: String, parentId: String? = nil) async throws -> Doc {
        let jiraBase = AppModel.shared.baseUrl(.jira)
        async let issueTask = API.shared.jiraIssue(key)
        async let editableTask = try? API.shared.jiraEditFields(key)
        let (issue, editable) = try await (issueTask, editableTask)
        // 多行文本字段（解决方案、原因分析等），即使内容是纯文本也要带上
        let textareas = Set((editable ?? []).filter { $0.kind == "textarea" && $0.key != "description" }.map(\.key))
        let url = "\(jiraBase)/browse/\(issue.key)"
        var parts = ["> 来源：[\(issue.key) \(issue.summary)](\(url)) · \(issue.issueType.name) · \(issue.status.name)\(issue.resolution.map { " · \($0)" } ?? "")"]
        if let d = issue.descriptionHtml {
            parts += ["## 问题描述", try await Rich.htmlToMarkdown(d, baseUrl: jiraBase)]
        }
        for field in issue.fields where field.html != nil || textareas.contains(field.id) {
            parts.append("## \(field.name)")
            parts.append(try await field.html.asyncMap { try await Rich.htmlToMarkdown($0, baseUrl: jiraBase) } ?? field.text)
        }
        if !issue.comments.isEmpty {
            parts.append("## 讨论记录")
            for c in issue.comments {
                parts.append("**\(c.author)** · \(Fmt.time(c.created))")
                parts.append(try await Rich.htmlToMarkdown(c.bodyHtml, baseUrl: jiraBase))
            }
        }
        let doc = try await API.shared.wsSaveDoc(DocInput(kind: "page", title: issue.summary, content: parts.joined(separator: "\n\n"), parentId: parentId, sourceSystem: "jira", sourceKey: issue.key, sourceUrl: url))
        Events.workspaceChanged()
        return doc
    }

    /// 剪藏的正文：来源说明加上页面内容。
    private static func clipContent(_ page: String) async throws -> (view: WsWikiPage, content: String, sourceUrl: String) {
        let view = try await API.shared.wsWikiPage(page)
        let content = "> 剪藏自 Wiki：[\(view.title)](\(view.url))\n\n" + (try await Rich.htmlToMarkdown(view.html, baseUrl: AppModel.shared.baseUrl(.confluence)))
        // 地址带上剪藏时的版本，之后据此判断原页面是否有更新
        return (view, content, "\(view.url)&pageVersion=\(view.version)")
    }

    /// 剪藏 Wiki 页面（地址或页面 id）为知识库页面，返回新页面。
    static func wikiToPage(_ page: String, parentId: String? = nil) async throws -> Doc {
        let (view, content, sourceUrl) = try await clipContent(page)
        let doc = try await API.shared.wsSaveDoc(DocInput(kind: "page", title: view.title, content: content, parentId: parentId, sourceSystem: "wiki", sourceKey: view.id, sourceUrl: sourceUrl))
        Events.workspaceChanged()
        return doc
    }

    /// 用原页面的最新内容重新剪藏（替换正文），返回更新后的页面。
    static func reclip(_ doc: Doc) async throws -> Doc {
        let (_, content, sourceUrl) = try await clipContent(doc.sourceKey ?? "")
        let saved = try await API.shared.wsSaveDoc(DocInput(id: doc.id, kind: doc.kind, title: doc.title, content: content, parentId: doc.parentId, tags: doc.tags, pinned: doc.pinned, sourceUrl: sourceUrl))
        Events.workspaceChanged()
        return saved
    }

    /// Wiki 地址中记录的版本（`pageVersion=`）。
    static func wikiVersion(_ url: String?) -> Int? {
        guard let url, let m = url.firstMatch(of: /[?&]pageVersion=(\d+)/) else { return nil }
        return Int(m.1)
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self {
        case .some(let v): try await transform(v)
        case .none: nil
        }
    }
}
