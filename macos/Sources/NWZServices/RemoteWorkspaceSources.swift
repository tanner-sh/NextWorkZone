import Foundation
import NWZCore
import NWZJira
import NWZWiki

/// 汇总远端工作记录；本机收件箱状态始终由工作空间管理。
public struct RemoteWorkspaceSources: WorkspaceRemoteSources {
    let wiki: WikiService
    let jira: JiraService
    let gitlab: GitLabService
    public init(jira: JiraService, wiki: WikiService, gitlab: GitLabService) { self.jira = jira; self.wiki = wiki; self.gitlab = gitlab }
    public func inboxSources() async throws -> InboxView {
        var result = InboxView(items: [], snoozed: [], notes: [])
        do { result.items = try await gitlab.inboxItems() } catch { result.notes.append("合并请求：" + error.localizedDescription) }
        let feed = try await jira.activity()
        let actionKinds: Set<String> = ["mention", "assigned", "comment", "status", "created", "share", "task"]
        var groups: [String: InboxItem] = [:]
        for event in feed.events where !event.read && actionKinds.contains(event.kind) && !event.issueKey.isEmpty {
            let id = "activity:\(event.system):\(event.issueKey)", at = Int64((JiraActivity.time(event.at)?.timeIntervalSince1970 ?? 0) * 1000)
            var item = groups[id] ?? InboxItem(id: id, source: "activity", title: event.system == "wiki" ? event.issueSummary : event.issueKey + " " + event.issueSummary, at: at, system: event.system, key: event.issueKey)
            item.at = max(item.at, at); item.events.append(event); groups[id] = item
        }
        result.items += groups.values
        if (try? await jira.client()) != nil {
            do {
                let reminders = try await jira.reminders(), today = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
                for reminder in reminders.items where ["overdue", "today"].contains(reminder.kind) {
                    result.items.append(InboxItem(id: "due:" + reminder.key, source: "due", title: reminder.key + " " + reminder.summary, detail: reminder.status.name, at: today, system: "jira", key: reminder.key, dueKind: reminder.kind, dueDays: reminder.days))
                }
            } catch { result.notes.append("到期问题：" + error.localizedDescription) }
        }
        result.items.sort { $0.at > $1.at }; return result
    }
    public func workEvents(day: String) async throws -> WorkLog {
        var result = WorkLog(day: day)
        do { result.events = try await gitlab.workEvents(day: day) } catch { result.notes.append("GitLab：" + error.localizedDescription) }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
        guard let start = format.date(from: day), format.string(from: start) == day, let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { throw NWZError.other("日期无效") }
        if let client = try? await wiki.client() {
            do {
                let events = try await client.myWork(from: day, to: format.string(from: end))
                result.events += events.compactMap { event in
                    guard let at = WikiIndex.time(event.at), at >= start, at < end else { return nil }
                    return WorkEvent(at: Int64(at.timeIntervalSince1970 * 1000), system: "wiki", kind: event.kind, title: event.title, key: event.pageId, detail: event.detail)
                }
            } catch { result.notes.append("Wiki：" + error.localizedDescription) }
        }
        if let client = try? await jira.client() { do {
            let actions = try await client.myActions(me: jira.me(), from: day, to: format.string(from: end), start: start, end: end)
            result.events += actions.compactMap { action in
                guard let time = JiraActivity.time(action.at) else { return nil }
                return WorkEvent(at: Int64(time.timeIntervalSince1970 * 1000), system: "jira", kind: action.kind, title: action.summary, key: action.key, detail: action.detail)
            }
        } catch { result.notes.append("Jira：" + error.localizedDescription) } }
        result.events.sort { $0.at < $1.at }; return result
    }
    public func markActivityRead(_ ids: [String]) async throws { _ = try await jira.markActivityRead(ids) }
    public func setWikiTask(page: String, task: String, done: Bool) async throws { try await wiki.setTask(page, task: task, done: done) }
}
