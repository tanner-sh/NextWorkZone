import Foundation
import NWZCore
import NWZGitLab
import NWZJira

extension GitLabService {
    private func names(_ client: GitLabClient, ids: [Int]) async -> [Int: String] {
        let identity = client.rest.cacheIdentity
        var names = projectNames[identity] ?? [:]
        for id in ids where names[id] == nil { names[id] = (try? await client.project(id).name) ?? "项目 \(id)" }
        projectNames[identity] = names; return names
    }
    public func inboxItems(now: Date = Date()) async throws -> [InboxItem] {
        guard let client = try? await client() else { return [] }
        let identity = client.rest.cacheIdentity
        if let cached = inboxCache, cached.identity == identity, now.timeIntervalSince(cached.at) < 120 { return cached.items }
        let me = try await client.currentUser(), query = MrQuery(state: "opened")
        async let reviewing = client.mergeRequests(scope: .reviewer, query: query)
        async let assigned = client.mergeRequests(scope: .assignedToMe, query: query)
        let pair = try await (reviewing, assigned)
        var seen: Set<Int> = [], items: [InboxItem] = []
        for (mr, reason) in pair.0.map({ ($0, "请你审核") }) + pair.1.map({ ($0, "指派给你") }) where mr.author.id != me.id && seen.insert(mr.id).inserted {
            items.append(InboxItem(id: "mr:\(mr.projectId):\(mr.iid)", source: "mr", title: mr.title, detail: mr.reference + " · " + mr.author.name + " · " + reason, at: Int64((JiraActivity.time(mr.updatedAt)?.timeIntervalSince1970 ?? 0) * 1000), system: "gitlab", url: mr.webUrl, mr: InboxMr(projectId: mr.projectId, iid: mr.iid, reference: mr.reference)))
        }
        inboxCache = (identity, now, items); return items
    }
    func localEvents(from: String, to: String) async throws -> [(GitLabEvent, String)] {
        guard let client = try? await client() else { return [] }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
        guard let start = format.date(from: from), format.string(from: start) == from, let last = format.date(from: to), format.string(from: last) == to, last >= start else { throw NWZError.other("日期无效") }
        let calendar = Calendar.current, end = calendar.date(byAdding: .day, value: 1, to: last)!
        let after = format.string(from: calendar.date(byAdding: .day, value: -2, to: start)!), before = format.string(from: calendar.date(byAdding: .day, value: 2, to: last)!)
        let events = try await client.myEvents(after: after, before: before).filter { JiraActivity.time($0.at).map { $0 >= start && $0 < end } ?? false }
        let names = await names(client, ids: events.map(\.projectId))
        return events.map { ($0, names[$0.projectId] ?? "") }
    }
    public func workEvents(day: String) async throws -> [WorkEvent] {
        try await localEvents(from: day, to: day).compactMap { event, project in
            guard let time = JiraActivity.time(event.at) else { return nil }
            let detail: String, key: String?
            if event.kind == "push" { key = nil; detail = event.detail + (event.commitCount > 1 ? "（\(event.commitCount) 个提交，\(event.title)）" : "（\(event.title)）") }
            else { key = event.iid.map { "!\($0)" }; detail = event.kind == "comment" ? event.title + "：" + event.detail : event.title }
            return WorkEvent(at: Int64(time.timeIntervalSince1970 * 1000), system: "gitlab", kind: event.kind, title: project, key: key, detail: detail, projectId: event.projectId)
        }
    }
}
extension GitLabService: WeeklyCodeSource {
    public func weeklyWork(from: String, to: String) async throws -> [WeeklyCodeWork] {
        try await localEvents(from: from, to: to).compactMap { event, project in
            let keys = GitLabLinks.issueKeys(event.title + " " + event.detail), mr = event.iid.map { "!\($0)" } ?? ""
            let evidence: String, standalone: String?
            switch event.kind {
            case "push":
                evidence = "推送 \(max(1, event.commitCount)) 个提交到 \(event.title)"
                let text = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                standalone = text.isEmpty || text.hasPrefix("Merge branch") || text.hasPrefix("Merge remote") ? nil : text
            case "mr_open": evidence = "发起合并请求 " + mr; standalone = "发起合并请求：" + event.title
            case "mr_merge": evidence = "合并 " + mr; standalone = "合并：" + event.title
            case "mr_approve": evidence = "批准 " + mr; standalone = "审核合并请求：" + event.title
            case "comment": evidence = "在 \(mr) 中评论"; standalone = nil
            default: return nil
            }
            return WeeklyCodeWork(kind: event.kind, keys: keys, project: project, evidence: evidence, standalone: standalone)
        }
    }
}
