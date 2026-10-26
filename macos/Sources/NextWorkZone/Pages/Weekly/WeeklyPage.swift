import SwiftUI

/// 周报：编辑共享 Wiki 页面中自己那一行（周报内容、风险事项），旁边是按这一周的工作生成的草稿。
struct WeeklyPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageVisit) private var visit
    @State private var view: WeeklyView?
    @State private var error: String?
    @State private var loading = false
    @State private var content: [EditorItem] = []
    @State private var risk: [EditorItem] = []
    @State private var restored = false
    @State private var notice: String?
    @State private var confirmSave = false
    @State private var confirmCreate = false
    @State private var busy = false
    @State private var actionError: String?

    /// 未保存的编辑内容暂存在本地，防止误关窗口丢失。
    private struct LocalDraft: Codable {
        var content: [OutlineItem]
        var risk: [OutlineItem]
    }

    private static func draftKey(_ pageId: String, _ section: String) -> String { "nextworkzone.weekly.\(pageId).\(section)" }

    private static func readDraft(_ key: String) -> LocalDraft? {
        AppPreferences.shared.data(forKey: key).flatMap { try? JSONDecoder().decode(LocalDraft.self, from: $0) }
    }

    private static func writeDraft(_ key: String, _ draft: LocalDraft?) {
        if let draft, let data = try? JSONEncoder().encode(draft) { AppPreferences.shared.set(data, forKey: key) } else { AppPreferences.shared.removeObject(forKey: key) }
    }

    private var configured: Bool { model.isReady(.confluence) && !(model.settings?.weeklyPageId.isEmpty ?? true) }
    private var entry: WeekEntry? { view?.entry }
    private var editedContent: [OutlineItem] { EditorItem.withoutIds(content) }
    private var editedRisk: [OutlineItem] { EditorItem.withoutIds(risk) }
    private var dirty: Bool {
        guard let entry else { return false }
        return !WeeklyText.same(editedContent, entry.content) || !WeeklyText.same(editedRisk, entry.risk)
    }

    var body: some View {
        Group {
            if model.settings == nil {
                LoadingView()
            } else if !configured {
                NotConfigured(label: "Wiki 或周报页面")
            } else if let error {
                ErrorBox(message: error) { Task { await load(entry?.sectionTitle) } }.padding(28)
            } else if let view {
                HStack(alignment: .top, spacing: 0) {
                    editor(view)
                    if let entry, entry.rowFound {
                        Divider()
                        DraftPanel(section: entry.sectionTitle, content: content, onInsert: insertDraft)
                            .frame(width: 380)
                    }
                }
            } else {
                LoadingView()
            }
        }
        .task(id: configured) { if configured { await load(nil) } }
        // 回到页面时重新读取正在看的小节（别人可能改过）；有未保存的修改时不动
        .onChange(of: visit) { if configured && view != nil && !dirty && !busy { Task { await load(entry?.sectionTitle) } } }
        .onChange(of: content) { persistDraft() }
        .onChange(of: risk) { persistDraft() }
        .sheet(isPresented: $confirmSave) { saveSheet }
        .sheet(isPresented: $confirmCreate) { createSheet }
    }

    private func apply(_ next: WeeklyView) {
        // 内容没有变化时只更新页面信息，编辑区不重建（重建会丢掉光标）
        if let entry = next.entry, entry == view?.entry, !dirty {
            view = next
            return
        }
        view = next
        guard let entry = next.entry else {
            content = []
            risk = []
            return
        }
        let local = Self.readDraft(Self.draftKey(next.pageId, entry.sectionTitle))
        let useLocal = local.map { !WeeklyText.same($0.content, entry.content) || !WeeklyText.same($0.risk, entry.risk) } ?? false
        content = EditorItem.withIds(useLocal ? local!.content : entry.content)
        risk = EditorItem.withIds(useLocal ? local!.risk : entry.risk)
        restored = useLocal
    }

    private func load(_ section: String?) async {
        loading = true
        error = nil
        do { apply(try await API.shared.weeklyLoad(section: section)) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
        loading = false
    }

    private func persistDraft() {
        guard let view, let entry else { return }
        Self.writeDraft(Self.draftKey(view.pageId, entry.sectionTitle), dirty ? LocalDraft(content: editedContent, risk: editedRisk) : nil)
    }

    private func switchSection(_ title: String) {
        if dirty && !Confirm.ask("当前小节有未保存的修改（已暂存在本地），确定切换吗？", confirm: "切换", destructive: false) { return }
        notice = nil
        Task { await load(title) }
    }

    /// 并入草稿条目：放到同名分组下，已有的同一条只更新进度。
    private func insertDraft(_ group: String?, _ texts: [String]) {
        let result = WeeklyText.merge(content, group: group, texts: texts)
        content = result.next
        let parts = [result.added > 0 ? "插入 \(result.added) 条" : nil, result.updated > 0 ? "更新 \(result.updated) 条的进度" : nil].compactMap { $0 }
        toast(parts.isEmpty ? "这些条目已在周报中" : "已\(parts.joined(separator: "，"))")
    }

    private func editor(_ view: WeeklyView) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 4) {
                    Button(view.pageTitle) { if let id = wikiPageIdOf(view.pageUrl) ?? Optional(view.pageId) { model.navigate(NavTarget(.wiki, wikiPage: id)) } }.buttonStyle(.link)
                    Text("· 版本 \(view.version) · \(view.modifiedBy) 于 \(Fmt.time(view.modifiedAt)) 更新").foregroundStyle(.secondary)
                }
                .font(.callout)
                if !view.currentWeekExists {
                    HStack {
                        Label("本周（\(view.currentWeekTitle)）的小节还没有创建。如果团队约定由他人创建，可以稍后刷新。", systemImage: "calendar.badge.plus")
                        Spacer()
                        Button("按上周模板新建") { actionError = nil; confirmCreate = true }
                    }
                    .padding(10)
                    .noticeBackground(.orange)
                }
                if let notice { Text(notice).foregroundStyle(.green) }
                ScrollView(.horizontal, showsIndicators: false) {
                    Picker("", selection: Binding(get: { entry?.sectionTitle ?? "" }, set: { switchSection($0) })) {
                        ForEach(view.sections, id: \.title) { s in Text(s.coversToday ? "\(s.title) · 本周" : s.title).tag(s.title) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if let entry, !entry.rowFound {
                    ErrorBox(message: "在「\(entry.sectionTitle)」中没有找到第一列为「\(view.personName)」的行。请确认你已被加入表格，或在设置中修改“我的名字”。")
                }
                if let entry, entry.rowFound {
                    if restored { Text("已恢复上次未保存的编辑内容。").foregroundStyle(.orange) }
                    if entry.lossy { Text("原内容包含加粗、颜色等格式。只要修改了这一栏，保存后格式会变成纯文本列表；没修改的栏目保持原样。").foregroundStyle(.orange) }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("周报内容").font(.headline)
                            Spacer()
                            Text("回车新增 · Tab 缩进 · Shift+Tab 取消缩进 · 可粘贴多行文本").font(.caption).foregroundStyle(.secondary)
                        }
                        OutlineEditor(items: $content, placeholder: "点击开始填写，例如：客户或产品名称")
                    }
                    .padding(16)
                    .groupBackground()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("风险事项").font(.headline)
                        OutlineEditor(items: $risk, placeholder: "无风险可留空")
                    }
                    .padding(16)
                    .groupBackground()
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .pageToolbar {
            ToolbarItem {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await load(entry?.sectionTitle) } }.disabled(loading).help("重新读取周报页面")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("预览并保存", systemImage: "square.and.arrow.down") { actionError = nil; confirmSave = true }
                    .labelStyle(.titleAndIcon)
                    .prominentToolbarButton(dirty && !busy)
            }
        }
        .pageSubtitle(.weekly, entry?.sectionTitle ?? "")
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存「\(entry?.sectionTitle ?? "")」的周报").font(.title3.weight(.semibold))
            Text("只会修改你自己那一行；保存时会基于页面最新版本改写，不会覆盖他人的内容。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DiffBlock(title: "周报内容", before: entry?.content ?? [], after: editedContent)
                    DiffBlock(title: "风险事项", before: entry?.risk ?? [], after: editedRisk)
                }
            }
            .frame(maxHeight: 420)
            if let actionError { ErrorBox(message: actionError) }
            HStack {
                Spacer()
                Button("取消") { confirmSave = false }.keyboardShortcut(.cancelAction)
                Button(busy ? "保存中…" : "确认保存到 Wiki", action: save).keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 620)
        .interactiveDismissDisabled(busy)
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建 \(view?.currentWeekTitle ?? "") 小节").font(.title3.weight(.semibold))
            Text("将在页面最上方插入「\(view?.currentWeekTitle ?? "")」小节：")
            VStack(alignment: .leading, spacing: 4) {
                Text("• 复制「\(view?.sections.first?.title ?? "")」的结构（说明文字、表头、人员名单）")
                Text("• 清空所有表格中填写的内容，人员名单保留")
                Text("• 这是对共享页面的修改，如果团队约定由他人创建，请先确认")
            }
            .font(.callout)
            if let actionError { ErrorBox(message: actionError) }
            HStack {
                Spacer()
                Button("取消") { confirmCreate = false }.keyboardShortcut(.cancelAction)
                Button(busy ? "创建中…" : "确认新建", action: createWeek).keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(busy)
    }

    private func save() {
        guard let view, let entry else { return }
        busy = true
        actionError = nil
        Task {
            do {
                let result = try await API.shared.weeklySave(WeeklySaveInput(section: entry.sectionTitle, contentRaw: entry.contentRaw, riskRaw: entry.riskRaw, content: editedContent, risk: editedRisk))
                Self.writeDraft(Self.draftKey(view.pageId, entry.sectionTitle), nil)
                confirmSave = false
                notice = result.changed ? "已保存到 Wiki（版本 \(result.version)）" : "内容没有变化，无需保存"
                await load(entry.sectionTitle)
            } catch {
                guard !isCancellation(error) else { return }
                actionError = errorMessage(error)
            }
            busy = false
        }
    }

    private func createWeek() {
        busy = true
        actionError = nil
        Task {
            do {
                let title = view?.currentWeekTitle ?? ""
                apply(try await API.shared.weeklyCreateWeek())
                confirmCreate = false
                notice = "已新建 \(title) 小节"
            } catch {
                guard !isCancellation(error) else { return }
                actionError = errorMessage(error)
            }
            busy = false
        }
    }
}

private struct DiffBlock: View {
    var title: String
    var before: [OutlineItem]
    var after: [OutlineItem]

    var body: some View {
        let lines = WeeklyText.diff(before, after)
        let changed = lines.contains { $0.kind != .same }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                if !changed { Text("（无变化）").font(.caption).foregroundStyle(.secondary) }
            }
            if changed {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 6) {
                        Text(l.kind == .add ? "+" : l.kind == .del ? "−" : " ").monospaced().frame(width: 12)
                        Text(l.text).strikethrough(l.kind == .del)
                    }
                    .padding(.leading, 12 + CGFloat(l.level) * 20)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(l.kind == .add ? Color.green : l.kind == .del ? Color.red : Color.primary)
                    .background(l.kind == .add ? Color.green.opacity(0.08) : l.kind == .del ? Color.red.opacity(0.08) : .clear)
                }
            }
        }
    }
}

/// 按“一件事”整理这一周的工作，插入到周报。
private struct DraftPanel: View {
    var section: String
    var content: [EditorItem]
    var onInsert: (String?, [String]) -> Void
    @Environment(AppModel.self) private var model
    @State private var draft: WeeklyDraft?
    @State private var loading = false
    @State private var error: String?

    private static let sourceLabels = ["jira": "Jira", "worklog": "工作日志", "gitlab": "GitLab", "wiki": "Wiki", "todo": "待办", "daily": "日记"]

    /// 作为周报条目的分组（问题、代码、工作日志）；其余（Wiki、待办、日记）是参考，单条插入时不加分组标题。
    private static func isWork(_ g: DraftGroup) -> Bool { g.source == "jira" || g.source == "gitlab" || g.source == "worklog" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("草稿", systemImage: "sparkles").font(.headline)
                    Spacer()
                    if let draft, draft.groups.contains(where: Self.isWork) {
                        Button("全部插入") {
                            for g in draft.groups where Self.isWork(g) { onInsert(g.title, g.items.map(\.text)) }
                        }
                        .help("插入全部问题和代码条目；已在周报中的只更新进度")
                    }
                    Button(loading ? "生成中…" : draft != nil ? "重新生成" : "生成草稿", action: generate).disabled(loading)
                }
                .controlSize(.small)
                Text("按“一件事”整理这一周的工作：每个 Jira 问题一条，提到它的推送、合并请求和完成的待办作为依据；分组和进度写法沿用往周周报，并和上周对比。插入时放到同名分组下，已有的条目只更新进度。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { ErrorBox(message: error) }
                if let draft { draftBody(draft) }
            }
            .padding(16)
        }
        .onChange(of: section) { draft = nil }
    }

    private func generate() {
        loading = true
        error = nil
        Task {
            do { draft = try await API.shared.weeklyDraft(section: section) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            loading = false
        }
    }

    @ViewBuilder
    private func draftBody(_ draft: WeeklyDraft) -> some View {
        Text("范围：\(draft.from) 至 \(draft.to)").font(.caption).foregroundStyle(.secondary)
        ForEach(draft.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        if !draft.carryOver.isEmpty {
            let pending = draft.carryOver.filter { $0.thisWeek == nil }
            let progressed = draft.carryOver.filter { $0.thisWeek != nil }
            VStack(alignment: .leading, spacing: 6) {
                Label("上周（\(draft.lastWeekTitle ?? "")）未完成 \(draft.carryOver.count) 项", systemImage: "clock.arrow.circlepath").fontWeight(.semibold).lineLimit(1)
                ForEach(pending, id: \.self) { c in
                    let text = c.progress.map { "\(c.text)\(draft.separator)\($0)" } ?? c.text
                    let state = WeeklyText.presence(content, text)
                    itemButton(help: "沿用到本周，插入后再修改进度", action: { onInsert(c.group.isEmpty ? nil : c.group, [text]) }) {
                        Text(c.text)
                        HStack(spacing: 6) {
                            if let p = c.progress { chip("上周 \(p)") }
                            Text("本周没有记录").foregroundStyle(.orange)
                            if state != .none { Text("· 已在周报中").foregroundStyle(.secondary) }
                        }
                        .font(.caption)
                    }
                }
                ForEach(progressed, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.text)
                        HStack(spacing: 6) {
                            if let p = c.progress { chip("上周 \(p)") }
                            Text("本周：\(c.thisWeek ?? "")").foregroundStyle(.green)
                        }
                        .font(.caption)
                    }
                    .padding(6)
                }
            }
        }
        if draft.groups.isEmpty { Text("这一周没有找到相关记录。").foregroundStyle(.secondary) }
        ForEach(draft.groups, id: \.self) { g in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Self.sourceLabels[g.source] ?? g.source).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor.opacity(0.12), in: Capsule())
                    Text(g.title).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Button("插入") { onInsert(g.title, g.items.map(\.text)) }.buttonStyle(.borderless)
                }
                ForEach(g.items, id: \.self) { item in
                    let state = WeeklyText.presence(content, item.text)
                    itemButton(help: state == .changed ? "周报中已有这一条，点击更新进度" : "插入这一条", action: { onInsert(Self.isWork(g) ? g.title : nil, [item.text]) }) {
                        Text(item.text).foregroundStyle(state == .same ? .secondary : .primary)
                        if !item.evidence.isEmpty || item.lastWeek != nil || item.key != nil || state != .none {
                            HStack(spacing: 6) {
                                if let key = item.key { Text(key).monospaced().foregroundStyle(.secondary) }
                                if let lw = item.lastWeek { chip("上周 \(lw)") }
                                if state == .same { Text("已在周报中").foregroundStyle(.secondary) }
                                if state == .changed { Text("周报中进度不同，点击更新").foregroundStyle(Color.accentColor) }
                                if !item.evidence.isEmpty { Text(item.evidence.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).padding(.horizontal, 5).background(Color.primary.opacity(0.07), in: Capsule())
    }

    private func itemButton<Content: View>(help: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .groupBackground(radius: Theme.controlRadius)
        .help(help)
    }
}
