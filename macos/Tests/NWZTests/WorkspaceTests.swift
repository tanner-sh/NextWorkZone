import Foundation
import Testing
import NWZCore
@testable import NWZWorkspace

struct WorkspaceTests {
    @Test func todoLifecycle() async throws {
        let ws = try await Workspace()
        let a = try await ws.saveTodo(.init(title: "写周报"))
        let b = try await ws.saveTodo(.init(title: "评审 MR"))
        #expect(try await ws.todos().map(\.title) == ["评审 MR", "写周报"])
        let done = try await ws.setTodoDone(a.id, done: true)
        #expect(done.done && done.completedAt != nil)
        let undone = try await ws.saveTodo(.init(id: a.id, title: a.title))
        #expect(!undone.done && undone.completedAt == nil)
        try await ws.moveTodo(b.id, sort: 5)
        #expect(try await ws.todos().last?.id == b.id)
        try await ws.deleteTodo(b.id)
        #expect(try await ws.todos().count == 1)
        let restored = try await ws.restoreTodo(b.id)
        #expect(!restored.deleted && restored.title == "评审 MR")
        #expect(try await ws.todos().count == 2)
    }
    @Test func jiraTodosFollowAssignedIssues() async throws {
        let ws = try await Workspace()
        #expect(try await ws.syncJiraTodos([.init(key: "ABC-1", summary: "修复导出"), .init(key: "ABC-2", summary: "优化查询")]).added == 2)
        var input = TodoInput(try #require(await ws.todo("jira-ABC-2")))
        input.title = "我自己的说法"
        _ = try await ws.saveTodo(input)
        let changed: [AssignedIssue] = [.init(key: "ABC-1", summary: "修复导出（新）"), .init(key: "ABC-2", summary: "优化查询（新）")]
        _ = try await ws.syncJiraTodos(changed)
        #expect(try await ws.todo("jira-ABC-1")?.title == "修复导出（新）")
        #expect(try await ws.todo("jira-ABC-2")?.title == input.title)
        #expect(try await ws.syncJiraTodos([changed[1]]).completed == 1)
        #expect(try await ws.syncJiraTodos(changed).reopened == 1)
        try await ws.deleteTodo("jira-ABC-2")
        #expect(try await ws.syncJiraTodos(changed).added == 0)
        #expect(try await ws.todos().count == 1)
    }
    @Test func wikiTodosAreSeparate() async throws {
        let ws = try await Workspace()
        _ = try await ws.syncJiraTodos([.init(key: "ABC-1", summary: "修复导出")])
        #expect(try await ws.syncWikiTodos([.init(pageId: "9", pageTitle: "会议纪要", taskId: "2", text: "整理方案", due: "2026-11-01")]).added == 1)
        let todo = try #require(await ws.todo("wiki-9-2"))
        #expect(todo.title == "整理方案" && todo.refSystem == "wiki" && todo.refKey == "9")
        #expect(try await ws.backlinks(system: "wiki", key: "9").count == 1)
        #expect(try await ws.syncWikiTodos([]).completed == 1)
        #expect(try await ws.todo("jira-ABC-1")?.done == false)
    }
    @Test func publishedAddressIsPreserved() async throws {
        let ws = try await Workspace()
        let doc = try await ws.saveDoc(.init(kind: "page", title: "方案", content: "正文"))
        let url = "https://wiki.example.com/pages/viewpage.action?pageId=5&pageVersion=1"
        _ = try await ws.setPublished(doc.id, url: url)
        let changed = try await ws.saveDoc(.init(id: doc.id, kind: "page", title: "方案", content: "改过"))
        #expect(changed.publishedUrl == url)
        #expect(try await ws.docs(kind: "page").first?.publishedUrl == url)
    }
    @Test func documentTreeTagsAndDaily() async throws {
        let ws = try await Workspace()
        let root = try await ws.saveDoc(.init(kind: "page", title: "部署手册", tags: ["运维", "#运维", " 发布 "]))
        #expect(root.tags == ["运维", "发布"])
        let child = try await ws.saveDoc(.init(kind: "page", title: "回滚步骤", parentId: root.id))
        await #expect(throws: (any Error).self) { try await ws.moveDoc(root.id, parentId: child.id, sort: 0) }
        #expect(try await ws.tags().first?.name == "发布")
        #expect(try await ws.deleteDoc(root.id) == 2)
        #expect(try await ws.docs(kind: "page").isEmpty == true)
        let daily = try await ws.daily("2026-10-22")
        #expect(daily.id == "daily-2026-10-22")
        #expect(try await ws.dailyDays().isEmpty == true)
        _ = try await ws.saveDoc(.init(id: daily.id, kind: "daily", title: daily.title, content: "今天"))
        #expect(try await ws.dailyDays() == ["2026-10-22"])
        #expect(try await ws.doc(daily.id)?.day == "2026-10-22")
    }
    @Test func backlinksAndSearch() async throws {
        let ws = try await Workspace()
        let page = try await ws.saveDoc(.init(kind: "page", title: "库存计算说明", content: "库存为零时金额应为零"))
        _ = try await ws.saveDoc(.init(title: "排查记录", content: "PROJ-123 的原因见 [说明](ws://doc/\(page.id))"))
        _ = try await ws.saveTodo(.init(title: "跟进", refSystem: "jira", refKey: "PROJ-123"))
        #expect(try await ws.backlinks(system: "jira", key: "PROJ-123").count == 2)
        #expect(try await ws.backlinks(system: "doc", key: page.id).first?.title == "排查记录")
        let hit = try #require(await ws.search("金额应为", limit: 10).first)
        #expect(hit.title == "库存计算说明" && hit.snippet.contains("金额应为"))
        #expect(try await ws.search("库存", limit: 10).count == 1)
        #expect(try await ws.search("跟进", limit: 10).first?.itemType == "todo")
        try await ws.deleteDoc(page.id)
        #expect(try await ws.search("库存", limit: 10).isEmpty == true)
        _ = try await ws.saveDoc(.init(kind: "jira-template", title: "隐藏模板", content: "PROJ-123"))
        #expect(try await ws.search("隐藏模板", limit: 10).isEmpty == true)
    }
    @Test func extractsReferences() {
        let refs = References.extract("见 PROJ-123 和ABC-1、[说明](ws://doc/1234-ab) UTF8 x-1 https://wiki.example.com/pages/viewpage.action?pageId=987")
        #expect(refs == [.init(system: "jira", key: "PROJ-123"), .init(system: "jira", key: "ABC-1"), .init(system: "doc", key: "1234-ab"), .init(system: "wiki", key: "987")])
        #expect(References.extract("AB-1 CD-2").count == 2)
        #expect(References.extract("A-1").isEmpty)
        #expect(References.extract("xABC-1 ABC-0 ABC-12345678").isEmpty)
    }
    @Test func stripsMarkdown() {
        #expect(References.plainText("# 标题\n\n- [x] **完成** 的 `代码`\n> 引用\n\n![图](ws://asset/1) [链接](https://example.com)") == "标题\n完成 的 代码\n引用\n链接")
    }
    @Test func nextOccurrenceSkipsPastDates() {
        let next = Workspace.nextOccurrence
        #expect(next("2026-10-23", "daily", "2026-10-23") == "2026-10-24")
        #expect(next("2026-10-23", "weekdays", "2026-10-23") == "2026-10-26")
        #expect(next("2026-10-01", "weekly", "2026-10-23") == "2026-10-29")
        #expect(next("2026-11-05", "weekly", "2026-10-23") == "2026-11-12")
        #expect(next("2026-01-31", "monthly", "2026-01-31") == "2026-02-28")
        #expect(next(nil, "daily", "2026-10-23") == "2026-10-24")
        #expect(next(nil, "yearly", "2026-10-23") == nil)
    }
    @Test func repeatingTodoCreatesNextOnlyOnce() async throws {
        let ws = try await Workspace()
        let today = Workspace.today(), next = try #require(Workspace.nextOccurrence(today, "daily", today))
        let reminder: Int64 = 1_800_000_000_000
        let todo = try await ws.saveTodo(.init(title: "站会", due: today, remindAt: reminder, repeat: "daily", checklist: [.init(id: "1", text: "同步进度", done: true)]))
        let done = try await ws.setTodoDone(todo.id, done: true)
        #expect(done.done && done.repeat == nil)
        let pending = try await ws.todos().filter { !$0.done }
        #expect(pending.count == 1 && pending[0].due == next && pending[0].repeat == "daily")
        #expect(pending[0].remindAt == reminder + 86_400_000 && !pending[0].checklist[0].done)
        _ = try await ws.setTodoDone(todo.id, done: false)
        _ = try await ws.setTodoDone(todo.id, done: true)
        #expect(try await ws.todos().count == 2)
    }
    @Test func uncompletingRepeatingTodoWithdrawsNext() async throws {
        let ws = try await Workspace()
        let today = Workspace.today()
        let todo = try await ws.saveTodo(.init(title: "站会", due: today, repeat: "daily"))
        _ = try await ws.setTodoDone(todo.id, done: true)
        #expect(try await ws.todos().count == 2)
        let undone = try await ws.setTodoDone(todo.id, done: false)
        #expect(!undone.done && undone.repeat == "daily" && undone.nextId == nil)
        #expect(try await ws.todos().map(\.id) == [todo.id])
        // 通过保存整条待办（详情页）取消完成也一样
        let again = try await ws.setTodoDone(todo.id, done: true)
        var input = TodoInput(again)
        input.done = false
        let saved = try await ws.saveTodo(input)
        #expect(saved.repeat == "daily")
        #expect(try await ws.todos().count == 1)
        // 下一次已经完成的话保留，不再恢复重复规则
        _ = try await ws.setTodoDone(todo.id, done: true)
        let following = try #require(await ws.todos().first { !$0.done })
        _ = try await ws.setTodoDone(following.id, done: true)
        let reopened = try await ws.setTodoDone(todo.id, done: false)
        #expect(reopened.repeat == nil)
        #expect(try await ws.todo(following.id)?.deleted == false)
    }
    @Test func sourceTodosFollowUntouchedTitleAndDue() async throws {
        let ws = try await Workspace()
        _ = try await ws.syncJiraTodos([.init(key: "ABC-1", summary: "修复导出", due: "2026-11-01"), .init(key: "ABC-2", summary: "优化查询", due: "2026-11-02")])
        var input = TodoInput(try #require(await ws.todo("jira-ABC-2")))
        input.due = "2026-11-10"
        _ = try await ws.saveTodo(input)
        _ = try await ws.syncJiraTodos([.init(key: "ABC-1", summary: "修复导出", due: "2026-11-05"), .init(key: "ABC-2", summary: "优化查询", due: "2026-11-06")])
        #expect(try await ws.todo("jira-ABC-1")?.due == "2026-11-05")
        #expect(try await ws.todo("jira-ABC-2")?.due == "2026-11-10")
        _ = try await ws.syncJiraTodos([.init(key: "ABC-1", summary: "修复导出", due: nil)])
        #expect(try await ws.todo("jira-ABC-1")?.due == nil)
        _ = try await ws.syncWikiTodos([.init(pageId: "9", pageTitle: "会议纪要", taskId: "2", text: "整理方案", due: nil)])
        _ = try await ws.syncWikiTodos([.init(pageId: "9", pageTitle: "会议纪要", taskId: "2", text: "整理方案初稿", due: nil)])
        #expect(try await ws.todo("wiki-9-2")?.title == "整理方案初稿")
    }
    @Test func deletedDocsCanBeRestored() async throws {
        let ws = try await Workspace()
        let parent = try await ws.saveDoc(.init(kind: "page", title: "方案"))
        let child = try await ws.saveDoc(.init(kind: "page", title: "细节", parentId: parent.id))
        let earlier = try await ws.saveDoc(.init(kind: "page", title: "早删的", parentId: parent.id))
        _ = try await ws.deleteDoc(earlier.id)
        _ = try await ws.saveDoc(.init(kind: "note", title: "", content: ""))
        let empty = try #require(await ws.docs(kind: "note").first)
        _ = try await ws.deleteDoc(empty.id)
        try await Task.sleep(for: .milliseconds(5))
        #expect(try await ws.deleteDoc(parent.id) == 2)
        #expect(try await ws.deletedDocs(since: 0).map(\.title) == ["方案"])
        #expect(try await ws.restoreDoc(parent.id) == 2)
        #expect(Set(try await ws.docs(kind: "page").map(\.id)) == [parent.id, child.id])
        #expect(try await ws.deletedDocs(since: 0).map(\.title) == ["早删的"])
        // 上级已删除时恢复到最上层
        _ = try await ws.deleteDoc(parent.id)
        #expect(try await ws.restoreDoc(earlier.id) == 1)
        #expect(try await ws.doc(earlier.id)?.parentId == nil)
    }
    @Test func capturesBecomeTodos() async throws {
        let ws = try await Workspace()
        _ = try await ws.capture(title: "看一下这个链接", body: "", url: "https://example.com/x")
        _ = try await ws.capture(title: "回复邮件", body: "周五之前\nhttps://example.com/y", url: "https://example.com/y")
        _ = try await ws.setInboxState("mr:1:2", title: "评审 !2", handledAt: 100, snoozeUntil: nil)
        #expect(try await ws.capturesToTodos() == 2)
        let todos = try await ws.todos()
        #expect(todos.count == 2 && todos.contains { $0.title == "看一下这个链接" && $0.notes == "https://example.com/x" })
        #expect(todos.contains { $0.title == "回复邮件" && $0.notes == "周五之前\nhttps://example.com/y" })
        #expect(try await ws.inbox().count == 1)
        #expect(try await ws.capturesToTodos() == 0)
    }
    @Test func dueAlertsFireOnce() async throws {
        let ws = try await Workspace(), now = Workspace.now()
        let todo = try await ws.saveTodo(.init(title: "开会", remindAt: now - 1_000))
        _ = try await ws.saveTodo(.init(title: "很久以前", remindAt: now - 48 * 3_600_000))
        _ = try await ws.saveTodo(.init(title: "以后", remindAt: now + 3_600_000))
        let capture = try await ws.capture(title: "回复邮件", body: "")
        _ = try await ws.setInboxState(capture.id, title: "", handledAt: nil, snoozeUntil: now - 10)
        #expect(Set(try await ws.takeDueAlerts(now).map(\.title)) == ["开会", "回复邮件"])
        #expect(try await ws.takeDueAlerts(now).isEmpty == true)
        _ = try await ws.saveTodo(.init(id: todo.id, title: todo.title, remindAt: now - 500))
        #expect(try await ws.takeDueAlerts(now).count == 1)
    }
    @Test func newSchemaAndDevicePersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("workspace.sqlite").path
        let first = try await Workspace(path: path)
        _ = try await first.saveTodo(.init(title: "保存后可用"))
        let second = try await Workspace(path: path)
        #expect(first.deviceID == second.deviceID)
        #expect(try await second.todos().count == 1)
        let database = try Database(path: path)
        #expect(try await database.query("PRAGMA user_version").first?["user_version"] == .integer(1))
    }
}
