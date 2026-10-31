import Charts
import SwiftUI

/// 个人统计：一段时间内处理、解决的问题，处理时长，按项目、模块、类型的分布。
struct StatsPage: View {
    enum Period: String, CaseIterable, Identifiable {
        case thisWeek, lastWeek, thisMonth, lastMonth, last90, thisYear
        var id: String { rawValue }
        var label: String {
            switch self {
            case .thisWeek: "本周"
            case .lastWeek: "上周"
            case .thisMonth: "本月"
            case .lastMonth: "上月"
            case .last90: "近 90 天"
            case .thisYear: "今年"
            }
        }

        /// 时间段的起止日期（含两端）。
        var range: (from: String, to: String) {
            let t = Fmt.today()
            let cal = Calendar.current
            let now = Date()
            let weekday = (cal.component(.weekday, from: now) + 5) % 7 // 周一为 0
            let monday = Fmt.addDays(t, -weekday)
            let comps = cal.dateComponents([.year, .month], from: now)
            let firstOfMonth = Fmt.day(cal.date(from: comps)!)
            switch self {
            case .thisWeek: return (monday, t)
            case .lastWeek: return (Fmt.addDays(monday, -7), Fmt.addDays(monday, -1))
            case .thisMonth: return (firstOfMonth, t)
            case .lastMonth: return (Fmt.day(cal.date(byAdding: .month, value: -1, to: cal.date(from: comps)!)!), Fmt.addDays(firstOfMonth, -1))
            case .last90: return (Fmt.addDays(t, -89), t)
            case .thisYear: return ("\(comps.year!)-01-01", t)
            }
        }
    }

    struct Stats {
        var handled: (issues: [IssueSummary], total: Int)
        var resolved: (issues: [IssueSummary], total: Int)
        var assigned: Int
        var unresolved: Int
        var worklogSeconds: Int?
    }

    /// 统计中最多取的问题数。
    static let maxIssues = 1000
    static let extra = ["components", "resolutiondate"]

    @Environment(AppModel.self) private var model
    @State private var period: Period = .thisMonth
    @State private var stats: Stats?
    @State private var loading = false
    @State private var error: String?
    @State private var issueMenu = IssueMenu()

    static func queries(_ from: String, _ to: String) -> (handled: String, resolved: String, assigned: String) {
        let end = Fmt.addDays(to, 1)
        let during = "DURING (\"\(from)\", \"\(end)\")"
        return (
            "status changed by currentUser() \(during) ORDER BY updated DESC",
            "resolved >= \"\(from)\" AND resolved < \"\(end)\" AND (assignee = currentUser() OR status changed by currentUser() \(during)) ORDER BY resolved DESC",
            "assignee changed to currentUser() \(during)"
        )
    }

    private static func searchAll(_ jql: String) async throws -> ([IssueSummary], Int) {
        var issues: [IssueSummary] = []
        var total = 0
        repeat {
            let page = try await API.shared.jiraSearch(jql, startAt: issues.count, maxResults: 100, fields: extra)
            total = page.total
            issues += page.issues
            if page.issues.isEmpty { break }
        } while issues.count < min(total, maxIssues)
        return (issues, total)
    }

    var body: some View {
        Group {
            if model.settings == nil {
                LoadingView()
            } else if !model.isReady(.jira) {
                NotConfigured(label: "Jira")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        let range = period.range
                        // 时间范围（之前在窗口副标题中）；各指标的含义放在卡片的悬停提示中
                        Text("\(range.from) 至 \(range.to)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        if let error { ErrorBox(message: error) }
                        if let stats { StatsBody(stats: stats, range: range, menu: issueMenu).opacity(loading ? 0.6 : 1) } else if error == nil { ProgressView() }
                    }
                    .padding(28)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .pageCommands { PageCommands(title: "统计", refresh: { Task { await load() } }) }
                .pageToolbar {
                    ToolbarItem(placement: .navigation) {
                        Picker("时间范围", selection: $period) { ForEach(Period.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                    }
                    ToolbarItem {
                        Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }.refreshing(loading).disabled(loading).help("刷新")
                    }
                }
            }
        }
        .issueMenuDialogs(issueMenu)
        .task(id: "\(period)|\(model.isReady(.jira))") { await load() }
    }

    private func load() async {
        guard model.isReady(.jira) else { return }
        loading = true
        error = nil
        let range = period.range
        let q = Self.queries(range.from, range.to)
        do {
            async let handled = Self.searchAll(q.handled)
            async let resolved = Self.searchAll(q.resolved)
            async let assigned = API.shared.jiraSearch(q.assigned, startAt: 0, maxResults: 1)
            async let unresolved = API.shared.jiraSearch(JQL.myUnresolved, startAt: 0, maxResults: 1)
            async let worklogs = try? API.shared.jiraMyWorklogs(from: range.from, to: range.to)
            let (h, r, a, u, w) = try await (handled, resolved, assigned, unresolved, worklogs)
            stats = Stats(handled: h, resolved: r, assigned: a.total, unresolved: u.total, worklogSeconds: w?.reduce(0) { $0 + $1.seconds })
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
        loading = false
    }
}

private struct StatsBody: View {
    var stats: StatsPage.Stats
    var range: (from: String, to: String)
    var menu: IssueMenu

    private static let dayMs = 86_400_000.0

    private func days(_ i: IssueSummary) -> Double? {
        guard let at = i.extra?["resolutiondate"], !at.isEmpty else { return nil }
        let d = (Double(Fmt.ms(at)) - Double(Fmt.ms(i.created))) / Self.dayMs
        return d >= 0 ? d : nil
    }

    private static func formatDays(_ d: Double) -> String {
        d < 1 ? "\(max(1, Int((d * 24).rounded()))) 小时" : d < 10 ? String(format: "%.1f 天", d) : "\(Int(d.rounded())) 天"
    }

    var body: some View {
        let q = StatsPage.queries(range.from, range.to)
        let resolved = stats.resolved.issues
        let durations = resolved.compactMap(days).sorted()
        let median: Double? = durations.isEmpty ? nil : durations.count % 2 == 1 ? durations[durations.count / 2] : (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2
        let open: (String) -> Void = { AppModel.shared.navigate(NavTarget(.jira, jql: $0)) }
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                Kpi(label: "处理过的问题", value: "\(stats.handled.total)", explain: "这段时间内你修改过状态的问题") { open(q.handled) }
                Kpi(label: "解决的问题", value: "\(stats.resolved.total)", explain: "这段时间内解决、经办人是你或由你流转的问题") { open(q.resolved) }
                Kpi(label: "新分配给我", value: "\(stats.assigned)", explain: "这段时间内分配给你的问题") { open(q.assigned) }
                Kpi(label: "当前未解决", value: "\(stats.unresolved)", explain: "经办人是你、还没有解决的问题") { open(JQL.myUnresolved) }
                Kpi(label: "解决用时（中位数）", value: median.map(Self.formatDays) ?? "—", hint: durations.isEmpty ? nil : "共 \(durations.count) 个问题", explain: "解决的问题从创建到解决用了多久")
                Kpi(label: "登记工时", value: stats.worklogSeconds.map { s in let h = Double(s) / 3600; return h < 10 ? "\((h * 10).rounded() / 10)h" : "\(Int(h.rounded()))h" } ?? "—", hint: stats.worklogSeconds == 0 ? "这段时间没有登记" : nil)
            }
            let buckets = bucketize(resolved)
            Card(title: "解决的问题 · 按\(buckets.unit)") {
                if resolved.isEmpty {
                    Text("这段时间没有解决的问题").foregroundStyle(.secondary)
                } else {
                    Chart(buckets.items, id: \.key) { b in
                        BarMark(x: .value("时间", b.label), y: .value("数量", b.count))
                            .cornerRadius(4)
                            .foregroundStyle(Color.accentColor)
                    }
                    .chartXAxis {
                        AxisMarks(values: buckets.items.enumerated().filter { $0.offset % max(1, buckets.items.count / 16) == 0 }.map(\.element.label))
                    }
                    .frame(height: 200)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Breakdown(title: "按项目", issues: stats.handled.issues) { [$0.project.name] }
                Breakdown(title: "按模块", issues: stats.handled.issues) { i in (i.extra?["components"]).flatMap { $0.isEmpty ? nil : $0.components(separatedBy: "、") } ?? ["未设置模块"] }
                Breakdown(title: "按问题类型", issues: stats.handled.issues) { [$0.issueType.name] }
            }
            Card(title: "解决的问题" + (stats.resolved.total > resolved.count ? "（显示前 \(resolved.count) 个）" : ""), actions: {
                Button("在列表中查看") { open(q.resolved) }.buttonStyle(.borderless)
            }) {
                ResolvedTable(issues: Array(resolved.prefix(200)), menu: menu, days: days, formatDays: Self.formatDays)
            }
        }
    }

    private struct Bucket { var key: String; var label: String; var count: Int }

    /// 31 天以内按天，半年以内按周，更长按月。
    private func bucketize(_ issues: [IssueSummary]) -> (unit: String, items: [Bucket]) {
        guard let start = Fmt.date(ofDay: range.from), let end = Fmt.date(ofDay: range.to) else { return ("天", []) }
        let span = Int((end.timeIntervalSince(start) / 86400).rounded()) + 1
        let unit = span <= 31 ? "天" : span <= 190 ? "周" : "月"
        let keyOf: (String) -> String = { day in
            if unit == "天" { return day }
            if unit == "月" { return String(day.prefix(7)) }
            let weekday = (Calendar.current.component(.weekday, from: Fmt.date(ofDay: day) ?? Date()) + 5) % 7
            return Fmt.addDays(day, -weekday)
        }
        var items: [Bucket] = []
        var index: [String: Int] = [:]
        var day = range.from
        while day <= range.to {
            let key = keyOf(day)
            if index[key] == nil {
                let parts = key.components(separatedBy: "-").compactMap(Int.init)
                let label = unit == "月" ? "\(parts[1])月" : unit == "周" ? "\(parts[1])/\(parts[2])" : "\(parts[2])"
                index[key] = items.count
                items.append(Bucket(key: key, label: label, count: 0))
            }
            day = Fmt.addDays(day, 1)
        }
        for i in issues {
            guard let at = i.extra?["resolutiondate"], let d = Fmt.parse(at), let idx = index[keyOf(Fmt.day(d))] else { continue }
            items[idx].count += 1
        }
        return (unit, items)
    }
}

/// 解决的问题：系统表格，可以点列头排序、拖动调整列宽；双击（或回车）打开问题，右键为问题的菜单。
private struct ResolvedTable: View {
    struct Row: Identifiable {
        var issue: IssueSummary
        var id: String { issue.key }
        var key: String { issue.key }
        var project: String { issue.project.name }
        var resolved: String
        /// 解决用时（天）；没有时排在最后
        var days: Double
    }

    var issues: [IssueSummary]
    var menu: IssueMenu
    var days: (IssueSummary) -> Double?
    var formatDays: (Double) -> String

    @State private var sortOrder = [KeyPathComparator(\Row.resolved, order: .reverse)]
    @State private var selection: Set<String> = []

    private static let rowHeight: CGFloat = 26

    var body: some View {
        let rows = issues.map { i in
            Row(issue: i, resolved: i.extra?["resolutiondate"].map { String($0.prefix(10)) } ?? "", days: days(i) ?? .infinity)
        }.sorted(using: sortOrder)
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("问题", value: \.key) { row in
                HStack(spacing: 6) {
                    SysImage(service: .jira, src: row.issue.issueType.iconUrl, size: 16)
                    Text(row.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Text(row.issue.summary).lineLimit(1)
                }
                .help(row.issue.summary)
            }
            .width(min: 240, ideal: 480)
            TableColumn("项目", value: \.project) { row in Text(row.project).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 140)
            TableColumn("解决时间", value: \.resolved) { row in Text(row.resolved.isEmpty ? "—" : row.resolved).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 80, ideal: 96)
            TableColumn("解决用时", value: \.days) { row in Text(row.days.isFinite ? formatDays(row.days) : "—").monospacedDigit() }
                .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { keys in
            if keys.count == 1, let issue = issues.first(where: { $0.key == keys.first }) {
                MenuSpecItems(specs: menu.specs(.summary(issue)))
            } else if !keys.isEmpty {
                Button("复制问题键") { Pasteboard.copy(keys.sorted().joined(separator: "\n")) }
            }
        } primaryAction: { keys in
            if let key = keys.first { AppModel.shared.navigate(NavTarget(.jira, issueKey: key)) }
        }
        // 放在可以滚动的统计页中：表格本身不滚动，高度随行数，最多约 18 行
        .frame(height: min(CGFloat(rows.count) * Self.rowHeight + 30, 18 * Self.rowHeight + 30))
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct Kpi: View {
    var label: String
    var value: String
    var hint: String? = nil
    /// 指标的含义，悬停时显示
    var explain: String? = nil
    var onClick: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            // 切换时间范围时数字滚动变化
            Text(value).font(.title.weight(.semibold)).contentTransition(.numericText()).animation(.snappy, value: value)
            // 没有说明时也占一行，一排卡片高度一致
            Text(hint ?? " ").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground()
        .contentShape(Rectangle())
        .onTapGesture { onClick?() }
        .help([explain, onClick != nil ? "点击在问题列表中查看" : nil].compactMap { $0 }.joined(separator: "。"))
    }
}

/// 分布：横向条形，最多 8 项，其余合并为“其他”。
private struct Breakdown: View {
    var title: String
    var issues: [IssueSummary]
    var keyOf: (IssueSummary) -> [String]

    var body: some View {
        var counts: [String: Int] = [:]
        for i in issues { for k in keyOf(i) { counts[k, default: 0] += 1 } }
        var rows = counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        if rows.count > 8 {
            let rest = rows[7...].reduce(0) { $0 + $1.1 }
            rows = Array(rows.prefix(7)) + [("其他 \(rows.count - 7) 项", rest)]
        }
        let maxCount = max(1, rows.map(\.1).max() ?? 1)
        return Card(title: title) {
            if rows.isEmpty { Text("没有数据").font(.callout).foregroundStyle(.secondary) }
            ForEach(rows, id: \.0) { name, count in
                HStack(spacing: 8) {
                    // 名称给更多宽度（项目、模块名常常很长，之前 110 点截得只剩几个字），条形相应变短
                    Text(name).lineLimit(1).truncationMode(.middle).frame(width: 160, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: max(2, geo.size.width * CGFloat(count) / CGFloat(maxCount)))
                    }
                    .frame(height: 8)
                    Text("\(count)").font(.callout.monospacedDigit()).frame(width: 34, alignment: .trailing)
                }
                .font(.callout)
                .help("\(name)：\(count) 个")
            }
        }
    }
}
