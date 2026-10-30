import Foundation

/// 待办、文档的常用操作和菜单，与 src/pages/workspace/todoMenu.tsx、docMenu.tsx、issueActions.ts 相同。
@MainActor
enum TodoActions {
    static let priorities = ["无", "低", "中", "高"]

    /// 由“分配给我的 Jira 问题”自动生成的待办；删除后同步时不会再添加。
    static func fromJiraSync(_ todo: Todo) -> Bool { todo.id.hasPrefix("jira-") }

    /// 保存修改；给出 `undo` 时可以在“编辑”菜单中撤销（例如菜单中改截止日期、优先级，不含编辑标题、备注时的逐字保存）。
    static func save(_ todo: Todo, undo: String? = nil, _ patch: @escaping (inout Todo) -> Void) async throws -> Todo {
        var next = todo
        patch(&next)
        let saved = try await API.shared.wsSaveTodo(TodoInput(next))
        Events.workspaceChanged()
        if let undo {
            undoable(undo, undo: { _ = try await API.shared.wsSaveTodo(TodoInput(todo)) }, redo: { _ = try await save(todo, patch) })
        }
        return saved
    }

    /// 标记完成或未完成（可撤销）。重复的待办完成时会生成下一次，撤销不能把它去掉，所以不登记撤销。
    static func setDone(_ todo: Todo, _ done: Bool) async throws -> Todo {
        let saved = try await API.shared.wsSetTodoDone(todo.id, done: done)
        Events.workspaceChanged()
        if todo.repeat == nil {
            undoable(done ? "完成待办" : "标记为未完成", undo: { _ = try await API.shared.wsSetTodoDone(todo.id, done: !done) }, redo: { _ = try await API.shared.wsSetTodoDone(todo.id, done: done) })
        }
        return saved
    }

    /// 删除（可撤销：删除只是打上删除标记，撤销时去掉）。
    static func delete(_ todo: Todo) async throws {
        try await API.shared.wsDeleteTodo(todo.id)
        Events.workspaceChanged()
        undoable("删除待办", undo: { _ = try await API.shared.wsRestoreTodo(todo.id) }, redo: { try await API.shared.wsDeleteTodo(todo.id) })
    }

    /// 在主窗口的撤销记录中登记一步：⌘Z 撤销、⇧⌘Z 重做，完成后各页面按工作空间变化刷新。
    private static func undoable(_ name: String, undo: @escaping @MainActor () async throws -> Void, redo: @escaping @MainActor () async throws -> Void) {
        guard let manager = MainWindow.window?.undoManager else { return }
        manager.registerUndo(withTarget: UndoTarget.shared) { _ in
            MainActor.assumeIsolated {
                // 撤销时登记的就是重做
                undoable(name, undo: redo, redo: undo)
                guarded {
                    try await undo()
                    Events.workspaceChanged()
                }
            }
        }
        manager.setActionName(name)
    }

    private final class UndoTarget: Sendable {
        static let shared = UndoTarget()
    }

    /// `onPromote` 提供时显示“创建为 Jira 问题”。
    static func menu(_ todo: Todo, onSaved: @escaping (Todo) -> Void = { _ in }, onDeleted: @escaping (Todo) -> Void = { _ in }, onPromote: ((Todo) -> Void)? = nil) -> [MenuSpec] {
        func update(_ patch: @escaping (inout Todo) -> Void) -> @MainActor () -> Void {
            { guarded { onSaved(try await save(todo, undo: "修改待办", patch)) } }
        }
        func dueOption(_ label: String, _ due: String?) -> MenuSpec {
            .action(label, checked: todo.due == due, update { $0.due = due })
        }
        let today = Fmt.today()
        var specs: [MenuSpec] = [
            .action(todo.done ? "标记为未完成" : "标记为完成", icon: todo.done ? "arrow.uturn.backward" : "checkmark") {
                guarded { onSaved(try await setDone(todo, !todo.done)) }
            },
            .separator,
            .submenu("截止日期", icon: "calendar", children: [
                dueOption("今天", today), dueOption("明天", Fmt.addDays(today, 1)), dueOption("下周一", Fmt.nextMonday()), .separator,
                .action("清除截止日期", disabled: todo.due == nil, update { $0.due = nil }),
            ]),
            .submenu("优先级", icon: "flag", children: [3, 2, 1, 0].map { p in .action(priorities[p], checked: todo.priority == p, update { $0.priority = p }) }),
            .separator,
        ]
        if todo.refSystem == "jira", let key = todo.refKey {
            specs.append(.action("打开 \(key)", icon: "arrow.up.forward.square") { AppModel.shared.navigate(NavTarget(.jira, issueKey: key)) })
        }
        if todo.refSystem == "wiki", let key = todo.refKey {
            specs.append(.action("打开 Wiki 页面", icon: "arrow.up.forward.square") { AppModel.shared.navigate(NavTarget(.wiki, wikiPage: key)) })
        }
        if todo.refSystem == "doc", let key = todo.refKey {
            specs.append(.action("打开来源文档", icon: "arrow.up.forward.square") {
                guarded {
                    if let doc = try await API.shared.wsDoc(key) {
                        AppModel.shared.navigate(NavTarget(doc.kind == "page" ? .kb : .notes, docId: doc.id))
                    } else {
                        toast("来源文档已被删除", error: true)
                    }
                }
            })
        }
        if todo.refKey == nil, let onPromote {
            specs.append(.action("创建为 Jira 问题", icon: "smallcircle.filled.circle") { onPromote(todo) })
        }
        specs.append(.action("复制标题", icon: "doc.on.doc") {
            Pasteboard.copy(todo.title)
            toast("已复制")
        })
        specs.append(.separator)
        let deleteLabel = todo.refSystem == "jira" ? "删除待办（不影响 Jira 问题）" : todo.source == "wiki" ? "删除待办（不影响 Wiki 任务）" : "删除"
        specs.append(.item(deleteLabel, icon: "trash", destructive: true, confirm: fromJiraSync(todo) ? "确认删除？之后不再自动添加" : "确认删除？") {
            guarded {
                try await delete(todo)
                onDeleted(todo)
            }
        })
        return specs
    }

    /// 为问题添加一条关联的待办。
    @discardableResult
    static func addIssueTodo(key: String, summary: String) async throws -> Todo {
        let todo = try await API.shared.wsSaveTodo(TodoInput(title: summary, refSystem: .some("jira"), refKey: .some(key), refTitle: .some(summary)))
        Events.workspaceChanged()
        return todo
    }
}

@MainActor
enum DocActions {
    static func input(_ doc: Doc) -> DocInput {
        DocInput(id: doc.id, kind: doc.kind, title: doc.title, content: doc.content, parentId: doc.parentId, tags: doc.tags, pinned: doc.pinned, sourceSystem: doc.sourceSystem, sourceKey: doc.sourceKey, sourceUrl: doc.sourceUrl)
    }

    /// 新建一篇引用该问题的笔记。
    static func createIssueNote(key: String, summary: String) async throws -> Doc {
        let doc = try await API.shared.wsSaveDoc(DocInput(kind: "note", title: "\(key) \(summary)", content: "\(key)\n\n"))
        Events.workspaceChanged()
        return doc
    }

    static func pinItem(id: String, pinned: Bool) -> MenuSpec {
        .action(pinned ? "取消置顶" : "置顶", icon: pinned ? "pin.slash" : "pin") {
            guarded {
                guard let full = try await API.shared.wsDoc(id) else { return }
                var input = input(full)
                input.pinned = !full.pinned
                _ = try await API.shared.wsSaveDoc(input)
                Events.workspaceChanged()
            }
        }
    }

    static func copyTitleItem(_ title: String) -> MenuSpec {
        .action("复制标题", icon: "doc.on.doc", disabled: title.isEmpty) {
            Pasteboard.copy(title)
            toast("已复制")
        }
    }

    /// `beforeDelete` 在删除前调用，用于先关闭正在编辑的文档。
    static func deleteItem(id: String, label: String, beforeDelete: @escaping @MainActor () -> Void) -> MenuSpec {
        .item(label, icon: "trash", destructive: true, confirm: "确认删除？") {
            guarded {
                beforeDelete()
                _ = try await API.shared.wsDeleteDoc(id)
                Events.workspaceChanged()
            }
        }
    }
}
