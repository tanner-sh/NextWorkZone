import AppKit
import Observation
import SwiftUI
import UserNotifications

/// 应用的全局状态：设置、导航、侧栏数量，以及各页面共享的动态、提醒、需要处理的事。
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: 设置

    var settings: Settings?
    /// 访问附件、图片等网页路径的方式；尚未检测时没有。
    var webAccess: [Service: WebAccess] = [:]
    /// 每次网页访问状态变化时递增，用于让图片重新加载。
    var sessionVersion = 0
    /// 不在侧边栏显示的工具。
    var hiddenTools: [String] = []

    func baseUrl(_ service: Service) -> String {
        settings?.services.first(where: { $0.service == service })?.baseUrl ?? ""
    }

    /// 地址与 Token 都已配置。
    func isReady(_ service: Service) -> Bool {
        guard let s = settings?.services.first(where: { $0.service == service }) else { return false }
        return !s.baseUrl.isEmpty && s.hasToken
    }

    func access(_ service: Service) -> WebAccess? {
        service == .gitlab ? .token : webAccess[service]
    }

    // MARK: 导航

    var current: NavTarget = AppModel.initialTarget()
    /// 最近一次带有附加目标（例如打开某个问题）的跳转，由对应页面处理后清除。
    /// 不参与观察：页面在 body 中读它（或 current）时，每次导航所有保留的页面都会整体重算，
    /// 列表很长时切换一次要一两百毫秒。页面改为接收 `navigated` 通知后取走。
    @ObservationIgnored var pending: NavTarget?
    /// 导航到新目标后发出。
    static let navigated = Notification.Name("nwz.navigated")
    var paletteOpen = false
    var quickTodoOpen = false
    /// 剪贴板记录已暂停（菜单栏图标的菜单据此显示“恢复”）
    var clipboardPaused = false
    /// 打开设置窗口（SwiftUI 只在视图中提供，由主窗口的根视图交给这里）
    @ObservationIgnored var openSettingsAction: OpenSettingsAction?
    /// 打开新窗口（问题、Wiki 页面等单独的窗口，预览窗口），同样由主窗口的根视图交给这里
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    private static let lastPageKey = "nextworkzone.lastPage"
    private static let lastToolKey = "nextworkzone.lastTool"

    private static func initialTarget() -> NavTarget {
        let defaults = AppPreferences.shared
        // 搜索页需要搜索文字，启动时不恢复
        if let saved = defaults.string(forKey: lastPageKey), let page = PageID(rawValue: saved), page != .search, page != .settings {
            return page == .tools ? NavTarget(.tools, tool: defaults.string(forKey: lastToolKey)) : NavTarget(page)
        }
        return NavTarget(.home)
    }

    func navigate(_ target: NavTarget) {
        // 设置在单独的设置窗口中
        if target.page == .settings { return openSettings() }
        current = target
        pending = target
        NotificationCenter.default.post(name: Self.navigated, object: nil)
        AppPreferences.shared.set(target.page.rawValue, forKey: Self.lastPageKey)
        if let tool = target.tool { AppPreferences.shared.set(tool, forKey: Self.lastToolKey) }
        MainWindow.show()
    }

    func navigate(_ page: PageID) { navigate(NavTarget(page)) }

    func openSettings() {
        NSApp.activate()
        openSettingsAction?()
    }

    /// 页面取走发给它的附加目标。
    func take(_ page: PageID) -> NavTarget? {
        guard let p = pending, p.page == page else { return nil }
        pending = nil
        return p
    }

    // MARK: 共享数据

    var inbox: InboxView?
    var activity: ActivityFeed?
    var reminders: Reminders?
    var issueCount: Int?
    /// 未安排日期的待办（新分配的 Jira 问题也在这里）
    var unscheduled: Int?
    /// 每次本机数据变化时递增，页面据此刷新。
    var workspaceVersion = 0

    /// 侧栏的数量。
    func count(_ page: PageID) -> Int? {
        let n: Int? = switch page {
        case .home: inbox?.items.count
        case .todos: unscheduled
        case .jira: issueCount
        case .activity: activity?.unread
        default: nil
        }
        return (n ?? 0) > 0 ? n : nil
    }

    /// 逾期或今天到期的问题数。
    var overdue: Int {
        reminders?.items.filter { $0.kind == "overdue" || $0.kind == "today" }.count ?? 0
    }

    // MARK: 启动

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { await loadSettings() }
        Task { hiddenTools = (try? await API.shared.toolsHidden()) ?? [] }
        Task { await refreshInbox() }
        Task { activity = try? await API.shared.jiraActivity() }
        loadUnscheduled()

        NotificationCenter.default.addObserver(forName: Events.name(AppEvent.webSession), object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.refreshSessions() }
        }
        NotificationCenter.default.addObserver(forName: Events.name(AppEvent.inbox), object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.refreshInbox() }
        }
        for name in [AppEvent.workspaceSynced, Events.local.workspaceChanged] {
            NotificationCenter.default.addObserver(forName: Events.name(name), object: nil, queue: .main) { _ in
                Task { @MainActor in
                    AppModel.shared.workspaceVersion += 1
                    AppModel.shared.loadUnscheduled()
                }
            }
        }
        startPolling()
    }

    func loadSettings() async {
        let old = settings.map(Self.fingerprint)
        settings = try? await API.shared.getSettings()
        if settings.map(Self.fingerprint) != old { await refreshSessions() }
    }

    func setSettings(_ s: Settings) {
        let changed = settings.map(Self.fingerprint) != Self.fingerprint(s)
        settings = s
        if changed { Task { await refreshSessions() } }
    }

    private static func fingerprint(_ s: Settings) -> String {
        s.services.map { "\($0.baseUrl)|\($0.hasToken)" }.joined(separator: ",")
    }

    func refreshSessions() async {
        guard let status = try? await API.shared.webAccessStatus() else { return }
        webAccess = Dictionary(uniqueKeysWithValues: status.compactMap { k, v in Service(rawValue: k).map { ($0, v) } })
        sessionVersion += 1
        ImageCache.shared.clearFailures()
    }

    func loadUnscheduled() {
        Task {
            guard let list = try? await API.shared.wsTodos() else { return }
            unscheduled = list.filter { !$0.done && $0.due == nil }.count
        }
    }

    // MARK: 需要处理的事

    private var inboxTask: Task<InboxView?, Never>?

    /// 重新汇总；同时发起的多次刷新合并为一次。
    @discardableResult
    func refreshInbox() async -> InboxView? {
        if let inboxTask { return await inboxTask.value }
        let task = Task { try? await API.shared.wsInbox() }
        inboxTask = task
        let view = await task.value
        inboxTask = nil
        if let view { inbox = view }
        return view
    }

    /// 先从本地列表中去掉条目（界面立即响应），再记下处理状态。
    func handle(_ item: InboxItem) async {
        if var v = inbox {
            v.items.removeAll { $0.id == item.id }
            v.snoozed.removeAll { $0.id == item.id }
            inbox = v
        }
        try? await API.shared.wsInboxHandle(InboxHandleInput(id: item.id, title: item.title, eventIds: item.events.map(\.id)))
        await refreshInbox()
    }

    func snooze(_ item: InboxItem, until: Int64?) async {
        try? await API.shared.wsInboxSnooze(item.id, title: item.title, until: until)
        await refreshInbox()
    }

    // MARK: 动态与提醒

    /// 检查动态的间隔。
    static let activityInterval: Duration = .seconds(180)

    private func startPolling() {
        Task {
            var rounds = 0
            while true {
                let jiraReady = isReady(.jira)
                if jiraReady || isReady(.confluence) {
                    // 新的动态也会进入今天页的“需要处理”
                    _ = try? await pollActivity()
                    await refreshInbox()
                    // 问题数和待办不需要那么频繁，大约每 9 分钟一次
                    if jiraReady && rounds % 3 == 0 {
                        if let r = try? await API.shared.jiraSearch(JQL.myUnresolved, startAt: 0, maxResults: 1) { issueCount = r.total }
                        _ = try? await checkReminders()
                        if let r = try? await API.shared.wsRefreshJiraTodos(), r.added + r.completed + r.reopened > 0 { Events.workspaceChanged() }
                    }
                    rounds += 1
                } else if settings == nil {
                    // 设置还没读出来：稍后再看
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                try? await Task.sleep(for: Self.activityInterval)
            }
        }
    }

    /// 检查一次动态，按通知设置发送系统通知。
    @discardableResult
    func pollActivity() async throws -> ActivityFeed {
        let poll = try await API.shared.jiraActivityPoll()
        activity = poll.feed
        let jiraKeys = Array(Set(poll.fresh.filter { $0.system != "wiki" }.map(\.issueKey)))
        if !jiraKeys.isEmpty {
            Events.post(Events.local.jiraActivity, payload: (try? JSONEncoder().encode(jiraKeys)).map { String(decoding: $0, as: UTF8.self) } ?? "[]")
            // 新分配、新建或状态变化的问题：未解决问题数、到期提醒和关联待办不必等下一轮
            issueChanged()
        }
        let kinds = ActivityText.notifyKinds()
        let wanted = poll.fresh.filter { kinds.contains($0.kind) }
        if wanted.count == 1, let e = wanted.first {
            let detail = ActivityText.detail(e)
            Notifier.send(ActivityText.subject(e), "\(e.actor) \(ActivityText.action(e))\(detail.isEmpty ? "" : "：\(detail)")")
        } else if wanted.count > 1 {
            var items: [String] = []
            for e in wanted {
                let s = e.system == "wiki" ? e.issueSummary : e.issueKey
                if !items.contains(s) { items.append(s) }
            }
            let system = wanted.allSatisfy { $0.system == "wiki" } ? "Wiki " : wanted.allSatisfy { $0.system != "wiki" } ? "Jira " : ""
            Notifier.send("\(wanted.count) 条新的\(system)动态", items.prefix(4).joined(separator: "、") + (items.count > 4 ? " 等 \(items.count) 项" : ""))
        }
        return poll.feed
    }

    func markRead(_ ids: [String]?) async {
        if let feed = try? await API.shared.jiraActivityRead(ids) { activity = feed }
    }

    private static let notifiedKey = "nextworkzone.jira.remindedToday"
    /// 早于这个钟点不发每天的汇总通知。
    private static let notifyHour = 9

    /// 检查一次到期提醒；`withNotify` 为真时按设置发送系统通知（每天一次汇总，之后只通知新出现的）。
    @discardableResult
    func checkReminders(withNotify: Bool = true) async throws -> Reminders {
        let r = try await API.shared.jiraReminders()
        reminders = r
        if withNotify && r.remind { notifyDue(r.items.filter { $0.kind == "overdue" || $0.kind == "today" }) }
        return r
    }

    private var issueChangeTask: Task<Void, Never>?

    /// 在应用里改了问题（字段、流转、分配等）：重新计算到期提醒、未解决问题数、关联的待办和需要处理的事，不必等下一轮轮询。连续修改只刷新一次。
    func issueChanged() {
        issueChangeTask?.cancel()
        issueChangeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            _ = try? await checkReminders(withNotify: false)
            if let r = try? await API.shared.jiraSearch(JQL.myUnresolved, startAt: 0, maxResults: 1) { issueCount = r.total }
            // 问题解决或重新打开后，关联的待办跟着完成或恢复
            if let r = try? await API.shared.wsRefreshJiraTodos(), r.added + r.completed + r.reopened > 0 { Events.workspaceChanged() }
            await refreshInbox()
        }
    }

    /// 在应用里合并、关闭或批准了合并请求：立即刷新需要处理的事。
    func mergeRequestChanged() {
        Task {
            await API.shared.glInboxChanged()
            await refreshInbox()
        }
    }

    private func notifyDue(_ due: [Reminder]) {
        guard !due.isEmpty else { return }
        let day = Fmt.today()
        let defaults = AppPreferences.shared
        let savedDay = defaults.string(forKey: Self.notifiedKey + ".day") ?? ""
        if savedDay != day && Calendar.current.component(.hour, from: Date()) < Self.notifyHour { return }
        let known = savedDay == day ? (defaults.stringArray(forKey: Self.notifiedKey + ".keys") ?? []) : []
        let fresh = due.filter { !known.contains($0.key) }
        guard !fresh.isEmpty else { return }
        let overdue = fresh.filter { $0.kind == "overdue" }.count
        let dueToday = fresh.count - overdue
        let title = [overdue > 0 ? "\(overdue) 个问题已逾期" : nil, dueToday > 0 ? "\(dueToday) 个问题今天到期" : nil].compactMap { $0 }.joined(separator: "，")
        Notifier.send(title, fresh.prefix(3).map { "\($0.key) \($0.summary)" }.joined(separator: "\n") + (fresh.count > 3 ? "\n等 \(fresh.count) 个" : ""))
        defaults.set(day, forKey: Self.notifiedKey + ".day")
        defaults.set(known + fresh.map(\.key), forKey: Self.notifiedKey + ".keys")
    }

    /// 提醒的文字，例如“逾期 2 天”“明天到期”“9 天未更新”。
    nonisolated static func reminderLabel(_ kind: String, _ days: Int) -> String {
        switch kind {
        case "overdue": "逾期 \(-days) 天"
        case "today": "今天到期"
        case "soon": days == 1 ? "明天到期" : "\(days) 天后到期"
        case "stale": "\(days) 天未更新"
        default: ""
        }
    }
}

/// 系统通知（首次使用时请求权限）。
enum Notifier {
    static func send(_ title: String, _ body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// 动态的文字说明，与 src/lib/activity.ts 相同。
enum ActivityText {
    static let kindLabels: [(String, String)] = [
        ("mention", "提到我"), ("assigned", "分配给我"), ("created", "新问题"), ("comment", "评论"), ("status", "状态变化"), ("field", "字段修改"),
        ("edit", "Wiki 页面修改"), ("share", "Wiki 分享"), ("task", "Wiki 任务"), ("like", "Wiki 点赞"), ("other", "其他 Wiki 通知"),
    ]

    private static let notifyKey = "nextworkzone.activity.notify"
    /// 默认不通知字段修改（截止日期等变化较频繁）
    static let defaultNotify = ["mention", "assigned", "created", "comment", "status", "share", "task"]

    static func notifyKinds() -> [String] {
        AppPreferences.shared.stringArray(forKey: notifyKey) ?? defaultNotify
    }

    static func storeNotifyKinds(_ kinds: [String]) {
        AppPreferences.shared.set(kinds, forKey: notifyKey)
    }

    /// 动态对应的问题或页面。
    static func subject(_ e: ActivityEvent) -> String {
        e.system == "wiki" ? e.issueSummary : "\(e.issueKey) \(e.issueSummary)"
    }

    /// 动态的动作，例如“评论”“修改了状态”。
    static func action(_ e: ActivityEvent) -> String {
        if e.system == "wiki" {
            switch e.kind {
            case "mention": return "在 Wiki 中提到了你"
            case "comment": return "评论了页面"
            case "edit": return "修改了页面"
            case "share": return "分享了页面"
            case "task": return "给你分配了任务"
            case "like": return "赞了"
            default: return ""
            }
        }
        switch e.kind {
        case "mention": return "在评论中提到了你"
        case "comment": return "评论"
        case "status": return "修改了状态"
        case "assigned": return "把问题分配给你"
        case "created": return e.text
        default: return "修改了"
        }
    }

    /// 动态的详细内容；动作已说明全部信息时为空。
    static func detail(_ e: ActivityEvent) -> String {
        e.kind == "assigned" || e.kind == "created" ? "" : e.text
    }

    static func target(_ e: ActivityEvent) -> NavTarget? {
        if e.system == "wiki" { return e.issueKey.isEmpty ? nil : NavTarget(.wiki, wikiPage: e.issueKey) }
        return NavTarget(.jira, issueKey: e.issueKey)
    }
}

/// 需要处理的事的文字和跳转目标，与 src/lib/inbox.ts 相同。
enum InboxText {
    static func detail(_ item: InboxItem) -> String {
        switch item.source {
        case "activity":
            guard let e = item.events.first else { return "" }
            let d = ActivityText.detail(e)
            let text = "\(e.actor) \(ActivityText.action(e))\(d.isEmpty ? "" : "：\(d)")"
            let activity = item.events.count > 1 ? "\(text)（共 \(item.events.count) 条）" : text
            // 合并了到期提醒的问题，后面接上到期和状态
            let due = item.dueKind.map { AppModel.reminderLabel($0, item.dueDays ?? 0) } ?? ""
            return [activity, due, due.isEmpty ? "" : item.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        case "due":
            return [item.dueKind.map { AppModel.reminderLabel($0, item.dueDays ?? 0) } ?? "", item.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        default:
            return item.detail
        }
    }

    static func target(_ item: InboxItem) -> NavTarget? {
        switch item.source {
        case "activity": return item.events.first.flatMap(ActivityText.target)
        case "due": return item.key.map { NavTarget(.jira, issueKey: $0) }
        case "mr": return item.mr.map { NavTarget(.gitlab, projectId: $0.projectId, mrIid: $0.iid) }
        default: return nil
        }
    }

    /// 转为待办（截止日期 `due`）。关联的 Jira 问题已有未完成的待办时改它的日期，不重复创建。转换后条目记为已处理。
    @MainActor static func toTodo(_ item: InboxItem, due: String?, todos: [Todo]) async throws -> Todo {
        let jiraKey = item.system == "jira" ? item.key : nil
        let todo: Todo
        if let jiraKey, let existing = todos.first(where: { !$0.done && $0.refSystem == "jira" && $0.refKey == jiraKey }) {
            var input = TodoInput(existing)
            input.due = .some(due)
            todo = try await API.shared.wsSaveTodo(input)
        } else {
            let summary = item.events.first?.issueSummary ?? item.title.replacing(/^[A-Z][A-Z0-9_]+-\d+\s+/, with: "")
            var input: TodoInput
            if item.system == "jira", let key = item.key {
                input = TodoInput(title: summary, refSystem: .some("jira"), refKey: .some(key), refTitle: .some(summary))
            } else if item.system == "wiki", let key = item.key {
                input = TodoInput(title: item.title, refSystem: .some("wiki"), refKey: .some(key), refTitle: .some(item.title))
            } else {
                input = TodoInput(title: "审核 \(item.mr?.reference ?? "") \(item.title)".trimmingCharacters(in: .whitespaces), notes: item.url ?? "")
            }
            input.due = .some(due)
            todo = try await API.shared.wsSaveTodo(input)
        }
        await AppModel.shared.handle(item)
        Events.workspaceChanged()
        return todo
    }
}

/// 常用的 JQL，与 src/pages/jira/jql.ts 相同。
enum JQL {
    static let presets: [(id: String, label: String, jql: String)] = [
        ("mine", "未解决", "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"),
        ("reported", "我报告的", "reporter = currentUser() AND resolution = Unresolved ORDER BY updated DESC"),
        ("recent", "近两周", "assignee was currentUser() AND updated >= -14d ORDER BY updated DESC"),
    ]

    static let myUnresolved = presets[0].jql

    /// 问题键的前缀就是项目键，例如 ABC-123 → ABC。
    static func projectKey(of issueKey: String) -> String {
        issueKey.replacing(/-\d+$/, with: "")
    }

    /// JQL 字符串中的文字需要转义引号和反斜杠。
    static func string(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static let sorts: [(id: String, label: String, order: String?)] = [
        ("default", "默认", nil),
        ("updated", "最近更新", "updated DESC"),
        ("created", "最近创建", "created DESC"),
        ("priority", "优先级", "priority DESC, updated DESC"),
        ("key", "问题键", "key DESC"),
    ]

    /// 字段在 JQL 中的写法：自定义字段用 cf[编号]。
    static func field(_ id: String) -> String {
        if let m = id.wholeMatch(of: /customfield_(\d+)/) { return "cf[\(m.1)]" }
        return id == "components" ? "component" : id
    }

    static func fieldSort(_ id: String, _ dir: String) -> String { "field:\(id):\(dir)" }

    /// 替换 JQL 的排序；“默认”保持原样（关键词搜索时为按相关度）。
    static func withOrder(_ jql: String, sort: String) -> String {
        var order: String?
        if let m = sort.wholeMatch(of: /field:(.+):(asc|desc)/) {
            order = "\(field(String(m.1))) \(m.2.uppercased()), updated DESC"
        } else {
            order = sorts.first(where: { $0.id == sort })?.order ?? nil
        }
        guard let order else { return jql }
        let base = jql.replacing(/(?i)\s+ORDER\s+BY\s+[\s\S]*$/, with: "").trimmingCharacters(in: .whitespaces)
        return "\(base) ORDER BY \(order)"
    }

    struct SearchForm: Equatable {
        var text = ""
        /// all / unresolved / resolved
        var state = "all"
        /// anyone / me
        var who = "anyone"
        var project = ""
    }

    /// 按表单拼出 JQL；有关键词时不指定排序（Jira 按相关度排序）。条件为空时返回 nil。
    static func search(_ form: SearchForm) -> String? {
        var clauses: [String] = []
        let text = form.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            clauses.append(text.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*-\d+/) != nil ? "key = \(string(text.uppercased()))" : "text ~ \(string(text))")
        }
        if !form.project.isEmpty { clauses.append("project = \(string(form.project))") }
        if form.state == "unresolved" { clauses.append("resolution = Unresolved") }
        if form.state == "resolved" { clauses.append("resolution is not EMPTY") }
        if form.who == "me" { clauses.append("assignee was currentUser()") }
        if clauses.isEmpty { return nil }
        return text.isEmpty ? "\(clauses.joined(separator: " AND ")) ORDER BY updated DESC" : clauses.joined(separator: " AND ")
    }

    struct SavedQuery: Codable, Hashable {
        var name: String
        var jql: String
    }

    private static let savedKey = "nextworkzone.jira.savedQueries"

    static func savedQueries() -> [SavedQuery] {
        guard let data = AppPreferences.shared.data(forKey: savedKey) else { return [] }
        return (try? JSONDecoder().decode([SavedQuery].self, from: data)) ?? []
    }

    static func storeSavedQueries(_ list: [SavedQuery]) {
        AppPreferences.shared.set(try? JSONEncoder().encode(list), forKey: savedKey)
    }
}
