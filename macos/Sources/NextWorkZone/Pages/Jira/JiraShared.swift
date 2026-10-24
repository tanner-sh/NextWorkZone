import Foundation
import Observation

/// 本机问题库的状态，同步过程中随进度更新（每秒最多刷新一次）。
@MainActor @Observable
final class IndexStatusStore {
    static let shared = IndexStatusStore()
    var status: IndexStatus?
    private var started = false
    private var pending = false

    func start() {
        guard !started else { return }
        started = true
        refresh()
        NotificationCenter.default.addObserver(forName: Events.name(AppEvent.jiraIndex), object: nil, queue: .main) { _ in
            Task { @MainActor in
                let s = IndexStatusStore.shared
                guard !s.pending else { return }
                s.pending = true
                try? await Task.sleep(for: .seconds(1))
                s.pending = false
                s.refresh()
            }
        }
    }

    func refresh() {
        Task { if let s = try? await API.shared.jiraIndexStatus() { status = s } }
    }
}

/// 问题的查看记录：列表中标出上次查看之后有新变化的问题。与 src/lib/viewed.ts 相同。
@MainActor @Observable
final class ViewedStore {
    static let shared = ViewedStore()
    var viewed: [String: Int64] = [:]
    var baseline: Int64?

    func load(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        Task {
            guard let v = try? await API.shared.jiraViewed(keys) else { return }
            viewed.merge(v.viewed) { _, b in b }
            baseline = v.baseline
        }
    }

    /// 列表中的问题是否有尚未查看的变化。从未查看过的问题，以开始记录之后的更新为准。
    func isUnseen(_ issue: IssueSummary) -> Bool {
        guard let baseline else { return false }
        let seen = max(viewed[issue.key] ?? baseline, Fmt.ms(issue.lastViewed))
        return Fmt.ms(issue.updated) > seen
    }

    /// 上次查看的时间：本应用中的记录与 Jira 网页上的“最近查看”取较晚的。
    static func lastSeen(local: Int64?, issue: IssueSummary) -> Int64? {
        let v = max(local ?? 0, Fmt.ms(issue.lastViewed))
        return v > 0 ? v : nil
    }

    /// 记录查看了问题，返回之前的查看时间。
    @discardableResult
    func markViewed(key: String, updated: String) async -> Int64? {
        let previous = (try? await API.shared.jiraMarkViewed(key, updated: updated)) ?? nil
        viewed[key] = max(Fmt.nowMs(), Fmt.ms(updated))
        return previous
    }
}

extension IssueDetail {
    /// 列表需要的字段（菜单操作修改后覆盖列表中的旧数据）。
    func merged(into old: IssueSummary) -> IssueSummary {
        var s = summaryValue
        s.extra = old.extra
        return s
    }
}
