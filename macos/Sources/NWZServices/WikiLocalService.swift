import Foundation
import NWZCore
import NWZWiki
import NWZWorkspace
import NWZJira

extension WikiService {
    public func start() {
        guard indexLoop == nil else { return }
        indexLoop = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(40))
                while !Task.isCancelled { await self?.syncIndex(); try await Task.sleep(for: .seconds(600)) }
            } catch {}
        }
    }
    public func stop() { indexLoop?.cancel(); indexLoop = nil; indexTask?.cancel() }
    public func configurationChanged() async {
        indexTask?.cancel(); await indexTask?.value; identity = nil
        if let client = try? await client() {
            try? await index.ensureScope(base: client.baseURL, spaces: settings.configuration.snapshot().wikiTools.indexSpaces, identity: client.rest.cacheIdentity)
        }
    }
    public func indexStatus() async throws -> WikiIndexStatus {
        let stats = try await index.stats()
        return WikiIndexStatus(enabled: settings.configuration.snapshot().wikiTools.indexEnabled, count: stats.count, spaces: stats.spaces, lastSync: stats.lastSync, running: indexRunning, progress: indexProgress, error: indexError)
    }
    public func requestIndexSync() {
        guard indexTask == nil else { return }
        indexTask = Task { await self.performSync(); self.indexTask = nil }
    }
    public func syncIndex() async { requestIndexSync(); await indexTask?.value }
    private func progress(_ value: WikiIndexProgress) { indexProgress = value; host.emit(ServiceEvent("wiki-index-changed")) }
    private func performSync() async {
        let config = settings.configuration.snapshot().wikiTools
        guard config.indexEnabled, let client = try? await client() else { return }
        indexRunning = true; indexProgress = nil; indexError = nil; host.emit(ServiceEvent("wiki-index-changed"))
        do {
            _ = try await index.sync(client: client, scope: WikiScope(spaces: config.indexSpaces)) { await self.progress($0) }
            if config.taskTodos { try await refreshTaskTodos() }
        } catch is CancellationError {} catch { indexError = error.localizedDescription }
        indexRunning = false; indexProgress = nil; host.emit(ServiceEvent("wiki-index-changed"))
    }
    public func rebuildIndex() async throws -> WikiIndexStatus {
        indexTask?.cancel(); await indexTask?.value
        try await index.clear(); requestIndexSync(); return try await indexStatus()
    }
    public func toolsSettings() -> WikiToolsSettings {
        let c = settings.configuration.snapshot().wikiTools
        return WikiToolsSettings(indexEnabled: c.indexEnabled, indexSpaces: c.indexSpaces, taskTodos: c.taskTodos, activity: c.activity, mutedPages: c.mutedPages)
    }
    public func saveToolsSettings(_ input: WikiToolsSettings) async throws -> WikiToolsSettings {
        func clean(_ values: [String]) -> [String] {
            var out: [String] = []
            for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty && !out.contains(value) { out.append(value) }
            return out
        }
        let old = settings.configuration.snapshot().wikiTools
        var c = WikiToolsConfig()
        c.indexEnabled = input.indexEnabled; c.indexSpaces = clean(input.indexSpaces); c.taskTodos = input.taskTodos; c.activity = input.activity; c.mutedPages = clean(input.mutedPages)
        let config = c
        try await settings.updateConfiguration { $0.wikiTools = config }
        if old.indexSpaces != c.indexSpaces || !c.indexEnabled { await configurationChanged() }
        if c.indexEnabled { requestIndexSync() }
        host.emit(ServiceEvent("wiki-index-changed"))
        return toolsSettings()
    }
    public func refreshTaskTodos() async throws {
        guard let workspace, settings.configuration.snapshot().wikiTools.taskTodos else { return }
        let key = try await me().key
        let tasks = try await index.assignedTasks(key).map {
            NWZWorkspace.AssignedWikiTask(pageId: $0.pageId, pageTitle: $0.pageTitle, taskId: $0.task.taskId, text: $0.task.text, due: $0.task.due)
        }
        let report = try await workspace.syncWikiTodos(tasks)
        if report.added + report.completed + report.reopened > 0 { host.emit(ServiceEvent("workspace-synced")) }
    }
}

extension WikiService: WikiActivitySource {
    public func events(since: Date, first: Bool) async throws -> [ActivityEvent] {
        let client = try await client(), me = try await me().key, config = settings.configuration.snapshot()
        let muted = Set(config.wikiTools.mutedPages + [config.weekly.pageId].filter { !$0.isEmpty })
        var found: [ActivityEvent] = []
        for n in await client.notifications() where n.updated > Int64(since.timeIntervalSince1970 * 1000) {
            let kind = ["mention", "comment", "share", "task", "like"].contains(n.action) ? n.action : "other"
            found.append(ActivityEvent(id: "wiki:n:" + n.id, issueKey: n.pageId ?? "", issueSummary: n.pageTitle.isEmpty ? n.title : n.pageTitle, kind: kind, actor: n.actor, at: Date(timeIntervalSince1970: Double(n.updated) / 1000).ISO8601Format(), text: n.text.isEmpty ? n.title : n.text, read: first, system: "wiki"))
        }
        for change in try await client.watchedChanges(minutes: max(1, Int(Date().timeIntervalSince(since) / 60))) {
            if change.byKey == me || muted.contains(change.id) { continue }
            if let time = WikiIndex.time(change.when), time <= since { continue }
            found.append(ActivityEvent(id: "wiki:\(change.id):v\(change.version)", issueKey: change.id, issueSummary: change.title, kind: "edit", actor: change.by, at: change.when, text: "第 \(change.version) 版" + (change.message.isEmpty ? "" : "：" + change.message), read: first, system: "wiki"))
        }
        return found
    }
}
