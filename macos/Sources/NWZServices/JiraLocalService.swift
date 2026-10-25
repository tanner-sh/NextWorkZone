import Foundation
import NWZCore
import NWZJira

extension JiraService {
    public func start() {
        guard indexLoop == nil else { return }
        indexLoop = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
                while !Task.isCancelled { await self?.syncIndex(); try await Task.sleep(for: .seconds(600)) }
            } catch {}
        }
    }
    public func stop() { indexLoop?.cancel(); indexLoop = nil; indexTask?.cancel(); polling?.cancel() }
    public func configurationChanged() async {
        indexTask?.cancel(); polling?.cancel(); username = nil
        if let base = try? settings.configuration.snapshot().baseURL(for: .jira) { try? await index.ensureBase(base) }
    }
    public func indexStatus() async throws -> IndexStatus {
        if let base = try? settings.configuration.snapshot().baseURL(for: .jira) { try await index.ensureBase(base) }
        let stats = try await index.stats()
        return IndexStatus(enabled: settings.configuration.snapshot().jiraTools.indexEnabled, count: stats.count, projects: stats.projects, lastSync: stats.lastSync, running: indexRunning, progress: indexProgress, error: indexError)
    }
    public func requestIndexSync() { if indexTask == nil { indexTask = Task { await self.performIndexSync(); self.indexTask = nil } } }
    public func syncIndex() async {
        if let indexTask { await indexTask.value; return }
        requestIndexSync(); await indexTask?.value
    }
    private func performIndexSync() async {
        let config = settings.configuration.snapshot().jiraTools
        guard config.indexEnabled, let client = try? await client() else { return }
        indexRunning = true; indexProgress = nil; indexError = nil; host.emit(ServiceEvent("jira-index-changed"))
        do { _ = try await index.sync(client: client, scope: IndexScope(jql: config.indexJql, days: Int(config.indexDays))) { progress in await self.progress(progress) } }
        catch is CancellationError {} catch { indexError = error.localizedDescription }
        indexRunning = false; indexProgress = nil; host.emit(ServiceEvent("jira-index-changed"))
    }
    private func progress(_ value: IndexProgress) { indexProgress = value; host.emit(ServiceEvent("jira-index-changed")) }
    public func rebuildIndex() async throws -> IndexStatus {
        indexTask?.cancel(); await indexTask?.value
        try await index.clear(); requestIndexSync(); return try await indexStatus()
    }
    public func searchIndex(_ query: IndexQuery) async throws -> [IssueHit] {
        if let base = try? settings.configuration.snapshot().baseURL(for: .jira) { try await index.ensureBase(base) }
        let name = query.mine ? try await me() : ""
        return try await index.search(query, me: name)
    }
    public func similarIssues(key: String, summary: String, resolvedOnly: Bool) async throws -> SimilarIssues {
        let jql = JiraQueries.similarJQL(key: key, summary: summary, resolvedOnly: resolvedOnly)
        if settings.configuration.snapshot().jiraTools.indexEnabled, let result = try await index.similar(key: key, summary: summary, resolvedOnly: resolvedOnly, limit: 10) { return SimilarIssues(jql: jql, source: "local", issues: result) }
        let result = if let jql { try await client().similarHits(jql, maxResults: 10) } else { [IssueHit]() }
        return SimilarIssues(jql: jql, source: "jira", issues: result)
    }
    public func markViewed(_ key: String, updated: String?) async throws -> Int64? {
        let milliseconds = max(Date().timeIntervalSince1970, updated.flatMap(JiraActivity.time)?.timeIntervalSince1970 ?? 0) * 1000
        return try await index.markViewed(key, at: Int64(milliseconds))
    }
    public func toolsSettings() -> JiraToolsSettings {
        let config = settings.configuration.snapshot().jiraTools
        return JiraToolsSettings(indexEnabled: config.indexEnabled, indexJql: config.indexJql, indexDays: Int(config.indexDays), dueField: config.dueField, dueSoonDays: Int(config.dueSoonDays), staleDays: Int(config.staleDays), remind: config.remind)
    }
    public func saveToolsSettings(_ input: JiraToolsSettings) async throws -> JiraToolsSettings {
        let old = settings.configuration.snapshot().jiraTools
        var next = JiraToolsConfig()
        next.indexEnabled = input.indexEnabled; next.indexJql = input.indexJql.trimmingCharacters(in: .whitespacesAndNewlines); next.indexDays = UInt32(clamping: input.indexDays)
        next.dueField = input.dueField.trimmingCharacters(in: .whitespacesAndNewlines); next.dueSoonDays = UInt32(clamping: input.dueSoonDays); next.staleDays = UInt32(clamping: input.staleDays); next.remind = input.remind
        let config = next
        try await settings.updateConfiguration { $0.jiraTools = config }
        if old.indexJql != next.indexJql || old.indexDays != next.indexDays { indexTask?.cancel(); await indexTask?.value; try await index.clear() }
        if next.indexEnabled { requestIndexSync() }
        return toolsSettings()
    }
    public func reminders() async throws -> Reminders {
        let config = settings.configuration.snapshot().jiraTools
        let fields = (try? await fields()) ?? [], candidates = JiraReminders.candidates(configured: config.dueField, fields: fields)
        let extra = candidates.map(\.id).filter { $0 != "duedate" }
        let issues = try await client().search("assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC", maxResults: 500, fields: extra).issues
        return JiraReminders.make(issues: issues, candidates: candidates, config: config)
    }
    public func activity() async throws -> ActivityFeed { try await activities.feed() }
    public func markActivityRead(_ ids: [String]?) async throws -> ActivityFeed { try await activities.markRead(ids) }
    public func pollActivity() async throws -> ActivityPoll {
        if let polling { return try await polling.value }
        let task = Task { try await self.performPoll() }; polling = task
        defer { polling = nil }
        return try await task.value
    }
    private func performPoll() async throws -> ActivityPoll {
        let now = Date(); var events: [ActivityEvent] = [], checks: [String: String] = [:], errors: [String] = []
        func cutoff(_ last: String?) -> (Date, Bool) {
            if let time = last.flatMap(JiraActivity.time) { return (time.addingTimeInterval(-300), false) }
            return (now.addingTimeInterval(-3 * 86400), true)
        }
        if let client = try? await client() {
            do {
                let last = try await activities.prepare(system: "jira", identity: client.rest.cacheIdentity), (since, first) = cutoff(last)
                let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy/MM/dd HH:mm"
                var found = try await client.activity(me: me(), since: format.string(from: since), cutoff: since)
                if first { for index in found.indices { found[index].read = true } }
                events += found; checks["jira"] = now.ISO8601Format()
            } catch { errors.append("Jira：" + error.localizedDescription) }
        }
        if let wikiActivity, settings.configuration.snapshot().wikiTools.activity, let rest = try? await settings.restClient(.confluence) {
            do {
                let last = try await activities.prepare(system: "wiki", identity: rest.cacheIdentity), (since, first) = cutoff(last)
                events += try await wikiActivity.events(since: since, first: first); checks["wiki"] = now.ISO8601Format()
            } catch { errors.append("Wiki：" + error.localizedDescription) }
        }
        try Task.checkCancellation()
        if checks.isEmpty && !errors.isEmpty { throw NWZError.other(errors.joined(separator: "；")) }
        return try await activities.merge(events, checks: checks)
    }
}
