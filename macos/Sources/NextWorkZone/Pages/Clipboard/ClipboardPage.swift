import AppKit
import SwiftUI

/// 应用内的剪贴板页面：浏览、搜索、整理历史和置顶板，以及设置。
struct ClipboardPage: View {
    var tab: String?
    var query: String?
    @Environment(AppModel.self) private var model

    private var switcher: some View {
        Picker("", selection: Binding(get: { tab == "settings" }, set: { settings in
            model.navigate(NavTarget(.tools, tool: "clipboard", toolTab: settings ? "settings" : nil))
        })) {
            Text("历史").tag(false)
            Text("设置").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    var body: some View {
        Group {
            if tab == "settings" {
                ClipboardSettingsForm()
            } else {
                ClipHistory(initialQuery: query ?? "")
            }
        }
        .pageToolbar {
            ToolbarItem(placement: .navigation) { switcher }
        }
        .pageSubtitle(.tools, "记录复制过的内容，随时搜索、粘贴")
    }
}

private struct ClipHistory: View {
    var initialQuery: String
    @Environment(AppModel.self) private var model
    @State private var list = ClipListModel()
    @State private var input = ""
    @State private var apps: [ClipApp] = []
    @State private var selectedId: String?
    @State private var editBoard: BoardEdit?
    @State private var settings: ClipSettings?
    @State private var debounce = Debouncer()
    @State private var started = false

    struct BoardEdit: Identifiable {
        var board: Pinboard?
        var id: String { board?.id ?? "new" }
    }

    private var items: [ClipItem] { list.items ?? [] }
    private var selected: ClipItem? { items.first { $0.id == selectedId } ?? items.first }

    private var empty: String? {
        guard list.items != nil else { return nil }
        if !list.text.isEmpty || list.kind != nil || list.app != nil { return "没有找到匹配的内容" }
        return list.board != nil ? "这个置顶板还是空的" : "还没有记录。复制一些内容试试。"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 340)
            Divider()
            Group {
                if let selected {
                    ClipDetail(item: selected, boards: list.boards, pinMenu: pinMenu).id(selected.id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "list.clipboard").font(.largeTitle)
                        Text(empty ?? "加载中…")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $editBoard) { e in
            BoardSheet(board: e.board, count: list.boards.count) { b in if e.board == nil { list.board = b.id; list.schedule() } }
        }
        .task {
            guard !started else { return }
            started = true
            input = initialQuery
            list.text = initialQuery
            await list.reload()
            settings = try? await API.shared.clipSettings()
        }
        .task(id: list.items?.count) { apps = (try? await API.shared.clipApps()) ?? apps }
        .onChange(of: initialQuery) { _, q in
            // 从搜索页“在剪贴板中查看”进来时带着搜索文字
            input = q
            list.text = q
            list.schedule()
        }
        .onChange(of: input) { _, q in
            debounce.run(after: .milliseconds(150)) {
                list.text = q.trimmingCharacters(in: .whitespaces)
                await list.reload()
            }
        }
        .onEvent(AppEvent.clipSettings) { _ in Task { settings = try? await API.shared.clipSettings() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: Binding(get: { selected?.id }, set: { selectedId = $0 })) {
                ForEach(items) { item in
                    row(item).tag(item.id)
                        .onAppear { if item.id == items.last?.id { list.loadMore() } }
                }
                if let empty, items.isEmpty {
                    Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .listHeader(inset: 12) {
                FilterField(prompt: "搜索文字、文件名、应用", text: $input)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        BoardChip(label: "全部", active: list.board == nil) { setBoard(nil) }
                        ForEach(list.boards) { b in
                            BoardChip(label: "\(b.name) \(b.count)", active: list.board == b.id, dot: ClipFmt.color(b.color)) { setBoard(b.id) }
                                .contextMenu(specs: { boardMenu(b) })
                                .help("右键：重命名、颜色、删除")
                        }
                        Button { editBoard = BoardEdit(board: nil) } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless).help("新建置顶板")
                    }
                }
                HStack {
                    Picker("", selection: Binding(get: { list.kind }, set: { list.kind = $0; list.schedule() })) {
                        Text("全部类型").tag(String?.none)
                        ForEach(ClipKinds.all, id: \.self) { Text(ClipKinds.of($0).label).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("", selection: Binding(get: { list.app }, set: { list.app = $0; list.schedule() })) {
                        Text("全部来源").tag(String?.none)
                        ForEach(apps) { Text("\($0.name)（\($0.count)）").tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                }
            }
            .padding(.top, 12)
            if let settings {
                Label(settings.config.enabled ? "在任何应用中按 \(HotKeys.display(settings.config.shortcut)) 打开面板" : "剪贴板记录已关闭", systemImage: "keyboard")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 12)
            }
        }
    }

    private func row(_ item: ClipItem) -> some View {
        let meta = ClipKinds.of(item.kind)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                ClipAppIcon(item: item, size: 18)
                Group {
                    if item.kind == "image" { Text("图片") } else if item.kind == "file" { Text(ClipFmt.meta(item)) } else {
                        Text((item.title.isEmpty ? AttributedString() : AttributedString(item.title + "  ", attributes: AttributeContainer().font(.body.bold()))) + clipSnippet(item, query: list.text))
                    }
                }
                .lineLimit(2)
                Spacer(minLength: 0)
                if item.kind == "image" {
                    AssetImage(path: "clip/thumb/\(item.id)", contentMode: .fill).frame(width: 44, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            HStack(spacing: 4) {
                Image(systemName: meta.icon)
                Text("\(meta.label) · \(item.appName ?? "未知来源")")
                if let b = list.boards.first(where: { $0.id == item.pinboard }) { Image(systemName: "pin.fill").foregroundStyle(ClipFmt.color(b.color)) }
                Spacer()
                Text(ClipFmt.time(item.copiedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .overlay {
            ClipMouse(onClick: { _ in selectedId = item.id }, menu: { itemMenu(item) }, dragItems: { [item] })
        }
    }

    private func setBoard(_ id: String?) {
        list.board = id
        list.schedule()
    }

    private func pinMenu(_ ids: [String], _ current: String?) -> [MenuSpec] {
        var specs: [MenuSpec] = list.boards.map { b in .action(b.name, checked: current == b.id) { guarded { try await API.shared.clipSetPinboard(ids, pinboard: b.id) } } }
        specs += [.separator, .action("新建置顶板…", icon: "plus") { editBoard = BoardEdit(board: nil) }]
        if current != nil { specs.append(.action("取消置顶", icon: "pin.slash") { guarded { try await API.shared.clipSetPinboard(ids, pinboard: nil) } }) }
        return specs
    }

    private func itemMenu(_ item: ClipItem) -> [MenuSpec] {
        var specs: [MenuSpec] = [.action("复制", icon: "doc.on.doc") { guarded { try await API.shared.clipCopy([item.id]); toast("已复制") } }]
        if item.hasHtml { specs.append(.action("复制为纯文本") { guarded { try await API.shared.clipCopy([item.id], plain: true); toast("已复制") } }) }
        specs += [
            .submenu("置顶到", icon: "pin", children: pinMenu([item.id], item.pinboard)),
            .separator,
            .item("删除", icon: "trash", destructive: true) { guarded { try await API.shared.clipDelete([item.id]) } },
        ]
        return specs
    }

    private func boardMenu(_ b: Pinboard) -> [MenuSpec] {
        [
            .action("重命名…", icon: "pencil") { editBoard = BoardEdit(board: b) },
            .submenu("颜色", children: ClipKinds.boardColors.map { c in .action(c, checked: b.color == c) { guarded { _ = try await API.shared.clipSavePinboard(id: b.id, name: b.name, color: c) } } }),
            .separator,
            .item("删除置顶板", icon: "trash", destructive: true, confirm: "确认删除（其中的条目回到历史中）") {
                guarded {
                    try await API.shared.clipDeletePinboard(b.id)
                    if list.board == b.id { setBoard(nil) }
                }
            },
        ]
    }
}

private struct BoardChip: View {
    var label: String
    var active: Bool
    var dot: Color? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ClipDetail: View {
    var item: ClipItem
    var boards: [Pinboard]
    var pinMenu: ([String], String?) -> [MenuSpec]
    @State private var text = ""
    @State private var draft: String?
    @State private var title = ""
    @State private var issuesStore = ClipIssues.shared
    @FocusState private var titleFocused: Bool

    var body: some View {
        let issues = issuesStore.hits(ClipFmt.itemIssueKeys(item))
        let board = boards.first { $0.id == item.pinboard }
        let actions = ClipActions.smart(item, text: text, issues: issues, env: ClipActionEnv(
            emitText: { value in
                try await API.shared.clipCopy([item.id], plain: true, edited: value)
                toast("已复制")
            },
            verb: "复制",
            openInApp: { Links.open($0) },
            done: { toast($0) }
        ))
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ClipAppIcon(item: item, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("", text: $title, prompt: Text("\(ClipKinds.of(item.kind).label)（点击命名）"))
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .focused($titleFocused)
                        .onSubmit { titleFocused = false }
                        .onChange(of: titleFocused) { _, f in if !f { saveTitle() } }
                    Text([item.appName ?? "未知来源", ClipFmt.time(item.copiedAt), item.copyCount > 1 ? "复制过 \(item.copyCount) 次" : nil, ClipFmt.meta(item), item.hasHtml ? "带格式" : nil, board.map { "置顶于“\($0.name)”" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let d = draft {
                VStack(alignment: .trailing) {
                    TextEditor(text: Binding(get: { d }, set: { draft = $0 }))
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .groupBackground(radius: Theme.controlRadius)
                    HStack {
                        Button("取消") { draft = nil }
                        Button("保存") {
                            guarded {
                                _ = try await API.shared.clipUpdateText(item.id, text: d)
                                text = d
                                draft = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || d == text)
                    }
                }
            } else {
                ClipPreviewBody(item: item, text: text, issues: issues)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .groupBackground()
            }
            if !actions.isEmpty {
                Text("快捷操作").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading) {
                    ForEach(actions) { a in
                        Button { guarded { try await a.run() } } label: {
                            Label(a.label, systemImage: a.icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(24)
        .pageToolbar {
            // 条目的操作放在窗口工具栏右侧
            ToolbarItemGroup {
                if item.hasHtml { Button("复制为纯文本", systemImage: "textformat") { guarded { try await API.shared.clipCopy([item.id], plain: true); toast("已复制纯文本") } }.help("复制为纯文本") }
                if item.textual && draft == nil { Button("编辑", systemImage: "pencil") { draft = text }.help("编辑") }
                Button(board?.name ?? "置顶到…", systemImage: "pin") { MenuBuilder.popUp(pinMenu([item.id], item.pinboard)) }.help(board.map { "置顶于“\($0.name)”" } ?? "置顶到…")
                Button("删除", systemImage: "trash") { guarded { try await API.shared.clipDelete([item.id]) } }.help("删除")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("复制", systemImage: "doc.on.doc") { guarded { try await API.shared.clipCopy([item.id]); toast("已复制") } }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
            }
        }
        .task {
            text = item.text
            title = item.title
            if item.truncated, let t = try? await API.shared.clipText(item.id) { text = t.text }
        }
    }

    private func saveTitle() {
        guard title.trimmingCharacters(in: .whitespaces) != item.title else { return }
        guarded { _ = try await API.shared.clipRename(item.id, title: title) }
    }
}

// MARK: - 设置

/// 剪贴板设置，修改后立即生效。
struct ClipboardSettingsForm: View {
    @State private var settings: ClipSettings?
    @State private var error: String?
    @State private var candidates: [IgnoredApp] = []
    @State private var message: String?

    static let defaultShortcut = "CommandOrControl+Alt+V"
    static let keepDays: [(UInt32, String)] = [(1, "1 天"), (7, "1 周"), (30, "1 个月"), (90, "3 个月"), (365, "1 年"), (0, "永久")]
    static let maxItems: [UInt32] = [500, 1000, 5000, 10000, 0]
    static let maxImageMb: [UInt32] = [10, 50, 200, 0]

    var body: some View {
        Form {
            if let s = settings {
                let c = s.config
                Section("基本") {
                    Toggle(isOn: bind(\.enabled)) {
                        Text("记录剪贴板历史")
                        Text("关闭后不再记录新的内容，快捷键也不再生效；已有的历史和置顶板保留。")
                    }
                    LabeledContent {
                        ShortcutField(value: c.shortcut, defaultValue: Self.defaultShortcut, disabled: !c.enabled) { v in save { $0.shortcut = v } }
                    } label: {
                        Text("打开面板")
                        Text(s.shortcutError ?? "在任何应用中按下快捷键，从屏幕底部弹出剪贴板面板。").foregroundStyle(s.shortcutError != nil ? .red : .secondary)
                    }
                    LabeledContent("暂停记录") {
                        if let until = s.pausedUntil {
                            HStack {
                                Label(pausedText(until), systemImage: "pause.circle").foregroundStyle(.orange)
                                Button("恢复", systemImage: "play") { pause(0) }
                            }
                        } else {
                            HStack {
                                Button("15 分钟") { pause(15) }
                                Button("1 小时") { pause(60) }
                                Button("直到手动恢复") { pause(-1) }
                            }
                        }
                    }
                }
                Section {
                    Toggle("选中后直接粘贴到之前使用的应用", isOn: bind(\.autoPaste))
                    if c.autoPaste {
                        switch s.pasteSupport {
                        case "ready":
                            Label("可以直接粘贴", systemImage: "checkmark.circle").foregroundStyle(.green)
                        case "needsPermission":
                            HStack(alignment: .top) {
                                Label("需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许 NextWorkZone，才能替你按下 ⌘V。授权前选中条目只会复制到剪贴板。已经打开了开关仍然提示时，在列表中选中 NextWorkZone 点“−”删除，再点“去授权”重新添加。", systemImage: "exclamationmark.shield")
                                    .foregroundStyle(.orange)
                                Button("去授权") { guarded { try await API.shared.clipRequestPermission() } }
                            }
                        default:
                            Text("\(s.pasteNote ?? "当前系统不支持自动粘贴")，选中条目只会复制到剪贴板。").foregroundStyle(.orange)
                        }
                    }
                    Toggle(isOn: bind(\.plainText)) {
                        Text("默认粘贴为纯文本（去掉网页、文档中的格式）")
                        Text("\(c.plainText ? "需要保留格式时" : "需要去掉格式时")，在面板中按 ⇧↩。")
                    }
                } header: { Text("粘贴") }
                Section {
                    Picker("保留时长", selection: bind(\.keepDays)) {
                        ForEach(Self.keepDays, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("最多保留", selection: bind(\.maxItems)) {
                        ForEach(Self.maxItems, id: \.self) { n in Text(n > 0 ? "\(n.formatted()) 条" : "不限").tag(n) }
                    }
                    Toggle("记录复制的图片（截图等）", isOn: bind(\.saveImages))
                    if c.saveImages {
                        Picker("图片上限", selection: bind(\.maxImageMb)) {
                            ForEach(Self.maxImageMb, id: \.self) { n in Text(n > 0 ? "\(n) MB" : "不限").tag(n) }
                        }
                    }
                    LabeledContent("已保存") {
                        HStack {
                            Text("\(s.stats.items.formatted()) 条，其中置顶 \(s.stats.pinned) 条；图片占用 \(Fmt.size(s.stats.imageBytes))").foregroundStyle(.secondary)
                            Button("清除历史", systemImage: "trash", role: .destructive) {
                                guard Confirm.ask("清除全部历史？置顶的条目保留。", confirm: "清除") else { return }
                                guarded { message = "已清除 \(try await API.shared.clipClear()) 条历史" }
                            }
                        }
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                } header: { Text("保留") } footer: { Text("置顶的条目不受影响，始终保留。") }
                Section {
                    Toggle(isOn: bind(\.skipSecrets)) {
                        Text("不记录疑似密码、密钥的内容（私钥、常见服务的访问令牌、像随机密码的短文字）")
                        Text("密码管理器复制的密码带有“不要记录”的标记，始终不会记录。")
                    }
                    ForEach(s.builtinIgnored) { app in
                        LabeledContent(app.name) { Text("内置，始终忽略").foregroundStyle(.secondary) }.help(app.id)
                    }
                    ForEach(c.ignoredApps) { app in
                        LabeledContent(app.name) {
                            Button("不再忽略", systemImage: "xmark") { save { $0.ignoredApps.removeAll { $0.id == app.id } } }.labelStyle(.iconOnly).buttonStyle(.borderless).help("不再忽略")
                        }
                        .help(app.id)
                    }
                    if !candidates.isEmpty {
                        Menu("添加要忽略的应用…") {
                            ForEach(candidates) { app in Button(app.name) { save { $0.ignoredApps.append(app) } } }
                        }
                        .fixedSize()
                    }
                } header: {
                    Text("隐私")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("所有内容只保存在本机（\(s.dataDir)），不会同步或上传。在忽略的应用中复制的内容不会被记录，可选的是曾经复制过内容的应用。")
                        Text("面板中的操作：↩ 粘贴 · ⇧↩ 粘贴为纯文本 · 空格 预览 · ⌘E 编辑后粘贴 · ⌘1–9 快速粘贴 · Tab 切换置顶板 · ⇧←/→ 或 ⌘点击 多选。")
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .task(id: settings?.config.ignoredApps.count) { candidates = (try? await API.shared.clipIgnoreCandidates()) ?? candidates }
        .onEvent(AppEvent.clipSettings) { _ in Task { await refresh() } }
        // 回到应用时（可能刚在系统设置中授了权）刷新权限状态
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await refresh() } }
    }

    private func refresh() async {
        do { settings = try await API.shared.clipSettings() } catch { self.error = errorMessage(error) }
    }

    private func bind<T>(_ key: WritableKeyPath<ClipboardConfig, T>) -> Binding<T> {
        Binding(get: { settings!.config[keyPath: key] }, set: { v in save { $0[keyPath: key] = v } })
    }

    private func save(_ patch: (inout ClipboardConfig) -> Void) {
        guard var config = settings?.config else { return }
        patch(&config)
        Task {
            do { settings = try await API.shared.clipSaveSettings(config) } catch { self.error = errorMessage(error) }
        }
    }

    private func pause(_ minutes: Int) {
        Task { if let s = try? await API.shared.clipPause(minutes: minutes) { settings = s } }
    }

    private func pausedText(_ until: Int64) -> String {
        if until > Fmt.nowMs() + 365 * 86_400_000 { return "已暂停记录，直到手动恢复" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "已暂停记录，\(f.string(from: Date(timeIntervalSince1970: Double(until) / 1000))) 自动恢复"
    }
}
