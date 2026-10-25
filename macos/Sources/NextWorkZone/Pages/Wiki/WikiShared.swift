import SwiftUI

/// 收藏的 Wiki 页面（保存在本机）。
struct FavoritePage: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var space: String
}

@MainActor @Observable
final class WikiFavorites {
    static let shared = WikiFavorites()
    private static let key = "nextworkzone.wiki.favorites"
    var list: [FavoritePage] = {
        guard let data = AppPreferences.shared.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([FavoritePage].self, from: data)) ?? []
    }()

    private func store() {
        AppPreferences.shared.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }

    func contains(_ id: String) -> Bool { list.contains { $0.id == id } }

    func toggle(_ page: FavoritePage) {
        if contains(page.id) { list.removeAll { $0.id == page.id } } else { list.insert(page, at: 0) }
        store()
    }

    /// 收藏的页面标题有变化时更新。
    func refresh(_ page: FavoritePage) {
        guard let i = list.firstIndex(where: { $0.id == page.id }), list[i] != page else { return }
        list[i] = page
        store()
    }
}

/// Wiki 页面和空间的右键菜单：页面树、最近、收藏、搜索结果、子页面等处共用。
@MainActor
enum WikiMenus {
    static func pageUrl(_ id: String) -> String { "\(AppModel.shared.baseUrl(.confluence))/pages/viewpage.action?pageId=\(id)" }

    /// `title` 和 `space` 未知时（例如正文中的链接）按需查询。
    static func page(id: String, title: String? = nil, space: String? = nil, current: Bool = false, onNewChild: (@MainActor () -> Void)? = nil) -> [MenuSpec] {
        let url = pageUrl(id)
        var cached: (String, String)? = title.flatMap { t in space.map { (t, $0) } }
        let info: () async throws -> (String, String) = {
            if let cached { return cached }
            let p = try await API.shared.wikiPage(id)
            cached = (p.title, p.spaceName)
            return (p.title, p.spaceName)
        }
        let getTitle: () async throws -> String = { if let title { return title }; return try await info().0 }
        let copy: (@escaping () async throws -> String) -> @MainActor () -> Void = { text in
            { guarded { Pasteboard.copy(try await text()); toast("已复制") } }
        }
        let favorite = WikiFavorites.shared.contains(id)
        var specs: [MenuSpec] = []
        if !current { specs.append(.action("打开", icon: "text.book.closed") { AppModel.shared.navigate(NavTarget(.wiki, wikiPage: id)) }) }
        specs.append(.action(favorite ? "取消收藏" : "收藏", icon: favorite ? "star.slash" : "star") {
            guarded {
                let (t, s) = try await info()
                WikiFavorites.shared.toggle(FavoritePage(id: id, title: t, space: s))
            }
        })
        if let onNewChild { specs.append(.action("新建子页面…", icon: "doc.badge.plus", onNewChild)) }
        specs += [
            .separator,
            .action("复制链接", icon: "link", copy { url }),
            .action("复制标题", icon: "doc.on.doc", copy(getTitle)),
            .action("复制为 Markdown 链接", copy { "[\(try await getTitle())](\(url))" }),
            .separator,
            .action("添加待办", icon: "checkmark.square") {
                guarded {
                    let t = try await getTitle()
                    _ = try await API.shared.wsSaveTodo(TodoInput(title: t, refSystem: .some("wiki"), refKey: .some(id), refTitle: .some(t)))
                    Events.workspaceChanged()
                    toast("已添加待办")
                }
            },
            .action("写笔记", icon: "note.text") {
                guarded {
                    let t = try await getTitle()
                    let doc = try await API.shared.wsSaveDoc(DocInput(kind: "note", title: t, content: "[\(t)](\(url))\n\n"))
                    Events.workspaceChanged()
                    AppModel.shared.navigate(NavTarget(.notes, docId: doc.id))
                }
            },
            .action("剪藏到知识库", icon: "book") { guarded { AppModel.shared.navigate(NavTarget(.kb, docId: try await KBImport.wikiToPage(id).id)) } },
            .separator,
            .action("在浏览器中打开", icon: "safari") { Links.openInBrowser(url) },
        ]
        return specs
    }

    static func space(_ space: WikiSpace, onCreate: (@MainActor () -> Void)? = nil, onRefresh: (@MainActor () -> Void)? = nil) -> [MenuSpec] {
        let url = "\(AppModel.shared.baseUrl(.confluence))/display/\(space.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? space.key)"
        var specs: [MenuSpec] = []
        if let home = space.homepageId { specs.append(.action("打开空间首页", icon: "text.book.closed") { AppModel.shared.navigate(NavTarget(.wiki, wikiPage: home)) }) }
        if let onCreate { specs.append(.action("在空间顶层新建页面…", icon: "doc.badge.plus", onCreate)) }
        if let onRefresh { specs.append(.action("刷新页面树", icon: "arrow.clockwise", onRefresh)) }
        specs += [
            .separator,
            .action("复制空间键", icon: "doc.on.doc") { Pasteboard.copy(space.key); toast("已复制") },
            .action("复制空间名称") { Pasteboard.copy(space.name); toast("已复制") },
            .action("复制链接", icon: "link") { Pasteboard.copy(url); toast("已复制") },
            .separator,
            .action("在浏览器中打开", icon: "safari") { Links.openInBrowser(url) },
        ]
        return specs
    }
}

/// 评论输入框：⌘↵ 发送，Esc 取消（有取消按钮时）。
struct CommentBox: View {
    var placeholder: String
    var submitLabel = "发送"
    var onCancel: (@MainActor () -> Void)? = nil
    var onSubmit: (String) async throws -> Void
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty { Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false) }
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: text.isEmpty ? 36 : 80, maxHeight: 280)
                    .padding(4)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        submit()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard let onCancel else { return .ignored }
                        onCancel()
                        return .handled
                    }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            if let error { ErrorBox(message: error) }
            if !text.isEmpty || onCancel != nil {
                HStack {
                    Spacer()
                    if let onCancel { Button("取消", action: onCancel) }
                    Button(sending ? "\(submitLabel)中…" : submitLabel, systemImage: "paperplane", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
            }
        }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sending else { return }
        sending = true
        error = nil
        Task {
            do {
                try await onSubmit(text)
                text = ""
            } catch {
                self.error = errorMessage(error)
            }
            sending = false
        }
    }
}

extension RichDoc {
    /// 勾选或取消某个任务（Wiki 页面任务，按任务 id）。
    func settingTask(_ id: String, done: Bool) -> RichDoc {
        func blocks(_ list: [RichBlock]) -> [RichBlock] {
            list.map { b in
                switch b {
                case .list(let ordered, let start, let items):
                    return .list(ordered: ordered, start: start, items: items.map { item in
                        var item = item
                        if item.task?.id == id { item.task?.done = done }
                        item.blocks = blocks(item.blocks)
                        return item
                    })
                case .quote(let bs): return .quote(blocks(bs))
                case .panel(let k, let t, let bs): return .panel(kind: k, title: t, blocks: blocks(bs))
                case .table(let rows): return .table(rows.map { r in RichRow(cells: r.cells.map { c in var c = c; c.blocks = blocks(c.blocks); return c }) })
                default: return b
                }
            }
        }
        return RichDoc(blocks: blocks(self.blocks))
    }
}
