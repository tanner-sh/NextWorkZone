import SwiftUI

/// 动态：与我有关的问题上别人的评论、状态变化、分配和修改，以及 Wiki 上的评论、提到和关注页面的修改。
struct ActivityPage: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, unread, mention, comment, status, wiki
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "全部"
            case .unread: "未读"
            case .mention: "@我"
            case .comment: "评论"
            case .status: "状态"
            case .wiki: "Wiki"
            }
        }
        func match(_ e: ActivityEvent) -> Bool {
            switch self {
            case .all: true
            case .unread: !e.read
            case .mention: e.kind == "mention" || e.kind == "assigned" || e.kind == "task"
            case .comment: e.kind == "comment" || e.kind == "mention"
            case .status: e.kind == "status"
            case .wiki: e.system == "wiki"
            }
        }
    }

    static let kindIcons = ["mention": "at", "assigned": "person.crop.circle.badge.checkmark", "created": "smallcircle.filled.circle", "comment": "bubble.left", "status": "arrow.left.arrow.right", "field": "pencil.line", "edit": "doc.badge.ellipsis", "share": "square.and.arrow.up", "task": "checkmark.square", "like": "hand.thumbsup", "other": "bell"]

    /// 合并显示的时间范围。
    static let mergeMs: Int64 = 10 * 60 * 1000

    @Environment(AppModel.self) private var model
    @Environment(\.page) private var pageState
    private var visit: Int { pageState.visit }
    @State private var filter: Filter = .all
    @State private var loading = false
    @State private var error: String?
    @State private var notifyKinds = ActivityText.notifyKinds()
    @State private var issueMenu = IssueMenu()

    private var ready: Bool { model.isReady(.jira) || model.isReady(.confluence) }

    /// 同一个人几分钟内对同一问题的连续操作合并显示（中间可能夹着其他问题的动态）。
    private var days: [(String, [[ActivityEvent]])] {
        var order: [String] = []
        var map: [String: [[ActivityEvent]]] = [:]
        for e in (model.activity?.events ?? []).filter(filter.match) {
            let day = String(e.at.prefix(10))
            if map[day] == nil { order.append(day) }
            var groups = map[day] ?? []
            if let i = groups.firstIndex(where: { g in
                let prev = g.last!
                return prev.issueKey == e.issueKey && prev.actor == e.actor && abs(Fmt.ms(prev.at) - Fmt.ms(e.at)) <= Self.mergeMs
            }) {
                groups[i].append(e)
            } else {
                groups.append([e])
            }
            map[day] = groups
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        Group {
            if model.settings == nil {
                LoadingView()
            } else if !ready {
                NotConfigured(label: "Jira 或 Wiki")
            } else {
                content
                    .pageToolbar { toolbar }
                    .pageCommands { PageCommands(title: "动态", refresh: { Task { await refresh() } }) }
                    .pageSubtitle(.activity, model.activity?.lastCheck.map { "上次检查 \(Fmt.time($0))" } ?? "")
            }
        }
        .issueMenuDialogs(issueMenu)
        .task(id: "\(ready)|\(visit)") { if ready { await refresh() } }
    }

    private func refresh() async {
        loading = true
        error = nil
        do { try await model.pollActivity() } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
        loading = false
    }

    private func open(_ group: [ActivityEvent]) {
        let unread = group.filter { !$0.read }.map(\.id)
        if !unread.isEmpty { Task { await model.markRead(unread) } }
        if let t = ActivityText.target(group[0]) { model.navigate(t) }
    }

    /// 左侧筛选；右侧通知设置、立即检查、全部已读。
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("筛选", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    Text(f == .unread && (model.activity?.unread ?? 0) > 0 ? "未读 \(model.activity!.unread)" : f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup {
            Button("通知设置", systemImage: "bell.badge") {
                MenuBuilder.popUp([.label("以下动态发送系统通知")] + ActivityText.kindLabels.map { k, label in
                    .action(label, checked: notifyKinds.contains(k)) {
                        notifyKinds = notifyKinds.contains(k) ? notifyKinds.filter { $0 != k } : notifyKinds + [k]
                        ActivityText.storeNotifyKinds(notifyKinds)
                    }
                })
            }
            .help("通知设置")
            Button("立即检查", systemImage: "arrow.clockwise") { Task { await refresh() } }.refreshing(loading).disabled(loading).help("立即检查")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button("全部已读", systemImage: "checkmark.circle") { Task { await model.markRead(nil) } }
                .labelStyle(.titleAndIcon)
                .disabled((model.activity?.unread ?? 0) == 0)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("你经办、报告、关注的问题和提到你的评论，以及 Wiki 上的评论、提到、分享和你关注的页面的修改。每 3 分钟检查一次。")
                    .font(.callout).foregroundStyle(.secondary)
                if let error { ErrorBox(message: error) { Task { await refresh() } } }
                if model.activity == nil { ProgressView() }
                let days = self.days
                if model.activity != nil && days.isEmpty {
                    Text(filter == .unread ? "没有未读的动态" : "暂无动态").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(days, id: \.0) { day, groups in
                    VStack(alignment: .leading, spacing: 6) {
                        let label = Fmt.dayLabel(day)
                        Text(label + (label != day && day != Fmt.today() ? " · \(day)" : "")).font(.caption).foregroundStyle(.secondary)
                        ForEach(groups, id: \.first!.id) { group in row(group) }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ group: [ActivityEvent]) -> some View {
        let first = group[0]
        let unread = group.contains { !$0.read }
        return HStack(alignment: .top, spacing: 10) {
            Avatar(name: first.actor, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(first.actor).fontWeight(.semibold)
                    if first.system == "wiki" {
                        Image(systemName: "text.book.closed").foregroundStyle(.secondary)
                        Text(first.issueSummary).lineLimit(1)
                    } else {
                        SysImage(service: .jira, src: first.issueTypeIcon, size: 16, fallback: "ticket")
                        Text(first.issueKey).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(first.issueSummary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.time(first.at)).font(.caption).foregroundStyle(.secondary)
                }
                // 同一组按时间先后显示
                ForEach(group.reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Label(ActivityText.action(e), systemImage: Self.kindIcons[e.kind] ?? "bell").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        let d = ActivityText.detail(e)
                        if !d.isEmpty { Text(d).font(.callout).lineLimit(3) }
                    }
                }
            }
        }
        .padding(10)
        .groupBackground(tint: unread ? Color.accentColor : nil)
        .overlay(alignment: .leading) { if unread { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 8) } }
        .rowTap { open(group) }
        .contextMenu(specs: {
            var specs: [MenuSpec] = [
                .action("打开", icon: "arrow.up.forward.square") { open(group) },
                .action("标记为已读", icon: "checkmark", disabled: group.allSatisfy(\.read)) { Task { await model.markRead(group.map(\.id)) } },
                .separator,
            ]
            // 下面是问题或页面本身的菜单（“打开”已在上面，打开时会标记为已读）
            specs += first.system == "wiki" ? WikiMenus.page(id: first.issueKey, title: first.issueSummary, current: true) : issueMenu.specs(.key(first.issueKey, summary: first.issueSummary), current: true)
            return specs
        })
    }
}
