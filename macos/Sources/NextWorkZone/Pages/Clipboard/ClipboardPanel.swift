import AppKit
import SwiftUI

/// 全局快捷键弹出的剪贴板面板：显示在鼠标所在屏幕的底部，选中后直接粘贴到之前使用的应用。
/// 面板不激活本应用（与聚焦搜索相同），之前的应用一直在前台，粘贴时不用切换回去。
@MainActor
final class ClipboardPanel {
    static let shared = ClipboardPanel()

    /// 面板高度与离屏幕边缘的距离。
    static let height: CGFloat = 340
    static let margin: CGFloat = 8

    private var panel: Panel?
    let model = ClipPanelModel()
    private var monitor: Any?

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) {}
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 启动时创建好并隐藏，按下快捷键时立即显示。
    func prepare() {
        guard panel == nil else { return }
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: Self.height), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: ClipPanelView(model: model).environment(AppModel.shared))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            // 点到其他地方时收起（右键菜单、确认框打开期间不算）
            MainActor.assumeIsolated {
                let p = ClipboardPanel.shared
                guard p.isVisible, !p.model.menuOpen, NSApp.modalWindow == nil else { return }
                if let key = NSApp.keyWindow, key.level == .popUpMenu || key is NSPanel { return }
                p.hide(restore: false)
            }
        }
    }

    func toggle() {
        if isVisible {
            hide(restore: true)
            return
        }
        // 启动时稍后才创建；在那之前按下快捷键时现在创建
        prepare()
        guard API.shared.clipboard.enabled, let panel else { return }
        let target = API.shared.clipboard.captureTarget()
        place(panel)
        model.open(target: target)
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitor()
    }

    /// 把面板放到鼠标所在屏幕的底部，宽度铺满可用区域。
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let width = max(400, area.width - Self.margin * 2)
        panel.setFrame(NSRect(x: area.minX + Self.margin, y: area.minY + Self.margin, width: width, height: Self.height), display: true)
    }

    /// 隐藏面板；`restore` 为 true 时把焦点交还给打开面板前使用的应用。
    func hide(restore: Bool) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        removeMonitor()
        model.closed()
        guard restore, let target = API.shared.clipboard.target() else { return }
        if target.isSelf {
            // 从本应用打开的面板：回到主窗口
            if MainWindow.isVisible { MainWindow.show() }
        } else if let pid = target.pid, let app = NSRunningApplication(processIdentifier: pid_t(pid)), !app.isActive {
            app.activate()
        }
    }

    /// 从面板跳到主窗口中打开（例如打开问题、进入剪贴板设置）。
    func openMain(_ go: @MainActor () -> Void) {
        hide(restore: false)
        MainWindow.show()
        go()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.model.handleKey(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// 面板的状态与键盘操作。
@MainActor @Observable
final class ClipPanelModel {
    let list = ClipListModel()
    var query = ""
    var index = 0
    /// 多选的条目，按选择顺序
    var marked: [String] = []
    var preview: PreviewMode?
    var target: String?
    var settings: ClipSettings?
    var notice: (text: String, error: Bool)?
    var newBoard: String?
    /// 每次弹出加一：回到开头、播放升起动画、聚焦搜索框
    var opening = 0
    var menuOpen = false
    /// 搜索框是否有焦点（由界面同步；判断 ⌘C、左右键、输入法组字时用）
    @ObservationIgnored var searchFocused = false
    /// 搜索框正在使用的字段编辑器
    private var searchEditor: NSTextView? {
        guard searchFocused, let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor else { return nil }
        return tv
    }
    private let debounce = Debouncer()
    private var noticeTask: Task<Void, Never>?

    enum PreviewMode: Equatable {
        case view, edit
    }

    var items: [ClipItem] { list.items ?? [] }
    var current: ClipItem? { items.isEmpty ? nil : items[min(index, items.count - 1)] }
    var autoPaste: Bool { settings?.config.autoPaste == true && settings?.pasteSupport == "ready" }
    var verb: String { autoPaste ? "粘贴" : "复制" }
    var pasteLabel: String { autoPaste ? "粘贴到 \(target ?? "当前应用")" : "复制" }

    init() {
        NotificationCenter.default.addObserver(forName: Events.name(AppEvent.clipSettings), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSettings() }
        }
    }

    func refreshSettings() {
        Task { if let s = try? await API.shared.clipSettings() { settings = s } }
    }

    func open(target: String?) {
        self.target = target
        query = ""
        list.text = ""
        list.kind = nil
        list.board = nil
        index = 0
        marked = []
        preview = nil
        newBoard = nil
        notice = nil
        opening += 1
        refreshSettings()
        // 拖出、粘贴后条目的顺序可能变了
        list.schedule()
    }

    func closed() {
        preview = nil
        newBoard = nil
    }

    func setQuery(_ q: String) {
        query = q
        debounce.run(after: q.isEmpty ? .zero : .milliseconds(80)) { [weak self] in
            guard let self else { return }
            list.text = q.trimmingCharacters(in: .whitespaces)
            index = 0
            await list.reload()
        }
    }

    func setKind(_ kind: String?) {
        list.kind = kind
        index = 0
        list.schedule()
    }

    func setBoard(_ board: String?) {
        list.board = board
        index = 0
        list.schedule()
    }

    func flash(_ text: String, error: Bool = false) {
        notice = (text, error)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(error ? 4 : 1.8))
            if !Task.isCancelled { notice = nil }
        }
    }

    func selectedIds() -> [String] { !marked.isEmpty ? marked : current.map { [$0.id] } ?? [] }

    func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { if !isCancellation(error) { flash(errorMessage(error), error: true) } }
        }
    }

    func paste(_ ids: [String], plain: Bool? = nil, edited: String? = nil) {
        guard !ids.isEmpty || edited != nil else { return }
        run { _ = try await API.shared.clipPaste(ids, plain: plain, edited: edited) }
    }

    func copy(_ ids: [String]) {
        run {
            try await API.shared.clipCopy(ids)
            ClipboardPanel.shared.hide(restore: true)
        }
    }

    func remove(_ ids: [String]) {
        run {
            try await API.shared.clipDelete(ids)
            self.marked = []
        }
    }

    func pin(_ ids: [String], to board: String?) {
        run { try await API.shared.clipSetPinboard(ids, pinboard: board) }
    }

    func openInMain(url: String) {
        ClipboardPanel.shared.openMain { Links.open(url) }
    }

    func openSettings() {
        ClipboardPanel.shared.openMain { AppModel.shared.navigate(NavTarget(.tools, tool: "clipboard", toolTab: "settings")) }
    }

    func actions(_ item: ClipItem, text: String, issues: [IssueHit]) -> [ClipAction] {
        ClipActions.smart(item, text: text, issues: issues, env: ClipActionEnv(
            emitText: { [weak self] value in self?.paste([item.id], plain: true, edited: value) },
            verb: verb,
            openInApp: { [weak self] in self?.openInMain(url: $0) },
            done: { [weak self] message in
                self?.flash(message)
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    ClipboardPanel.shared.hide(restore: true)
                }
            }
        ))
    }

    func createBoard(_ name: String) {
        newBoard = nil
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let ids = selectedIds()
        let color = ClipKinds.boardColors[list.boards.count % ClipKinds.boardColors.count]
        run {
            let created = try await API.shared.clipSavePinboard(id: nil, name: name, color: color)
            if !ids.isEmpty { try await API.shared.clipSetPinboard(ids, pinboard: created.id) }
            self.setBoard(created.id)
        }
    }

    /// 条目的右键菜单。
    func menu(_ item: ClipItem) async -> [MenuSpec] {
        let ids = marked.contains(item.id) ? marked : [item.id]
        let text = item.truncated ? ((try? await API.shared.clipText(item.id))?.text ?? item.text) : item.text
        let smart = ids.count == 1 ? actions(item, text: text, issues: ClipIssues.shared.hits(ClipFmt.itemIssueKeys(item))) : []
        var specs: [MenuSpec] = [.action(ids.count > 1 ? "\(pasteLabel)（\(ids.count) 条）" : pasteLabel) { self.paste(ids) }]
        if item.textual { specs.append(.action(autoPaste ? "粘贴为纯文本" : "复制为纯文本") { self.paste(ids, plain: true) }) }
        // 不能自动粘贴时第一项已经是“复制”
        if autoPaste { specs.append(.action("复制") { self.copy(ids) }) }
        specs.append(.separator)
        if ids.count == 1 {
            specs.append(.action("预览") { self.select(item); self.preview = .view })
            if item.textual { specs.append(.action(autoPaste ? "编辑后粘贴…" : "编辑后复制…") { self.select(item); self.preview = .edit }) }
        }
        var boards: [MenuSpec] = list.boards.map { b in .action(b.name, checked: item.pinboard == b.id) { self.pin(ids, to: b.id) } }
        if !boards.isEmpty { boards.append(.separator) }
        boards.append(.action("新建置顶板…") { self.newBoard = "" })
        if item.pinboard != nil { boards += [.separator, .action("取消置顶") { self.pin(ids, to: nil) }] }
        specs.append(.submenu("置顶到", children: boards))
        if !smart.isEmpty {
            specs.append(.separator)
            specs += smart.map { a in .action(a.label) { self.run { try await a.run() } } }
        }
        specs += [.separator, .action(ids.count > 1 ? "删除 \(ids.count) 条" : "删除") { self.remove(ids) }]
        return specs
    }

    func popMenu(_ item: ClipItem) {
        Task {
            let specs = await menu(item)
            menuOpen = true
            MenuBuilder.popUp(specs)
            menuOpen = false
        }
    }

    func select(_ item: ClipItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { index = i }
    }

    func click(_ item: ClipItem, modifiers: NSEvent.ModifierFlags) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        if modifiers.contains(.command) {
            if marked.contains(item.id) {
                marked.removeAll { $0 == item.id }
            } else {
                if marked.isEmpty, let c = current, c.id != item.id { marked = [c.id] }
                marked.append(item.id)
            }
        } else if modifiers.contains(.shift), current != nil {
            let (a, b) = (min(index, i), max(index, i))
            marked = items[a...b].map(\.id)
        } else {
            marked = []
        }
        index = i
    }

    /// 拖动的条目：拖的是多选中的一条时，拖动全部选中的（按选择顺序）。
    func dragItems(_ item: ClipItem) -> [ClipItem] {
        marked.contains(item.id) ? marked.compactMap { id in items.first { $0.id == id } } : [item]
    }

    /// 键盘操作：搜索框始终保持焦点，方向键、回车等在这里处理。返回 true 表示已处理。
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let cmd = mods.contains(.command)
        let shift = mods.contains(.shift)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let editor = searchEditor
        let inSearch = editor != nil && NSApp.keyWindow?.firstResponder === editor
        // 输入法正在组字
        if inSearch, editor?.hasMarkedText() == true { return false }
        let typingElsewhere = !inSearch && NSApp.keyWindow?.firstResponder is NSTextView

        switch e.keyCode {
        case 53: // Esc
            if newBoard != nil { newBoard = nil } else if preview != nil { preview = nil } else if !marked.isEmpty { marked = [] } else if !query.isEmpty { setQuery("") } else { ClipboardPanel.shared.hide(restore: true) }
            return true
        default: break
        }
        if typingElsewhere {
            // 预览层编辑时 ⌘↩ 粘贴修改后的内容，其余按键交给编辑框
            return false
        }
        switch e.keyCode {
        case 123, 124: // ← →
            let right = e.keyCode == 124
            // 搜索框中有文字时，不按 Shift 的左右键用于移动光标
            if !query.isEmpty, !shift, !cmd, inSearch, preview == nil, let editor {
                let r = editor.selectedRange()
                let atEnd = r.length == 0 && r.location == (query as NSString).length
                let atStart = r.length == 0 && r.location == 0
                if !(right && atEnd) && !(!right && atStart) { return false }
            }
            guard !items.isEmpty else { return true }
            let next = cmd ? (right ? items.count - 1 : 0) : max(0, min(items.count - 1, index + (right ? 1 : -1)))
            if shift, let c = current {
                for id in [c.id, items[next].id] where !marked.contains(id) { marked.append(id) }
            }
            index = next
            return true
        case 115, 119: // Home End
            index = e.keyCode == 115 ? 0 : max(0, items.count - 1)
            return true
        case 48: // Tab
            let order: [String?] = [nil] + list.boards.map(\.id)
            let at = order.firstIndex(of: list.board) ?? 0
            setBoard(order[(at + (shift ? order.count - 1 : 1)) % order.count])
            return true
        case 36, 76: // 回车
            if newBoard != nil { return false }
            if cmd, preview == .edit { return false }
            paste(selectedIds(), plain: shift ? true : nil)
            return true
        case 49 where query.isEmpty && current != nil: // 空格
            preview = preview == nil ? .view : nil
            return true
        case 51 where cmd: // ⌘⌫
            let ids = selectedIds()
            if !ids.isEmpty { remove(ids) }
            return true
        case 117 where query.isEmpty: // Delete
            let ids = selectedIds()
            if !ids.isEmpty { remove(ids) }
            return true
        default: break
        }
        guard cmd else { return false }
        if let n = Int(chars), (1...9).contains(n) {
            if n <= items.count { paste([items[n - 1].id], plain: shift ? true : nil) }
            return true
        }
        switch chars {
        case "y" where current != nil:
            preview = preview == nil ? .view : nil
        case "e" where current?.textual == true:
            preview = .edit
        case "c":
            // 搜索框中选中了文字时照常复制文字
            if let editor, inSearch, editor.selectedRange().length > 0 { return false }
            copy(selectedIds())
        case "p":
            if let c = current { popMenu(c) }
        case ",":
            openSettings()
        case "a" where query.isEmpty:
            marked = items.map(\.id)
        default:
            return false
        }
        return true
    }
}

// MARK: - 视图

struct ClipPanelView: View {
    @Bindable var model: ClipPanelModel
    @State private var issues = ClipIssues.shared
    @State private var entering = false
    @FocusState private var searchFocused: Bool

    private var list: ClipListModel { model.list }

    var body: some View {
        VStack(spacing: 0) {
            bar
            strip
            foot
        }
        .overlay {
            if let mode = model.preview, let current = model.current {
                ClipPreviewLayer(model: model, item: current, edit: mode == .edit).id("\(current.id)-\(mode == .edit)")
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
        .onChange(of: model.opening) {
            searchFocused = true
            entering = true
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(.spring(duration: 0.45)) { entering = false }
            }
        }
        .onChange(of: model.preview) { _, p in if p == nil { searchFocused = true } }
        .onChange(of: list.items?.count) { model.index = max(0, min(model.index, (list.items?.count ?? 1) - 1)) }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: Binding(get: { model.query }, set: { model.setQuery($0) }), prompt: Text("搜索剪贴板…"))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: searchFocused, initial: true) { _, f in model.searchFocused = f }
                if !model.query.isEmpty {
                    Button { model.setQuery("") } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("清空").accessibilityLabel("清空")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 260)
            .background(Theme.fieldFill, in: Capsule())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    boardButton(nil, label: "剪贴板历史", icon: "list.clipboard")
                    ForEach(list.boards) { b in boardButton(b.id, label: b.name, dot: b.color).help("\(b.count) 条") }
                    if let name = model.newBoard {
                        TextField("", text: Binding(get: { name }, set: { model.newBoard = $0 }), prompt: Text("置顶板名称，回车创建"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit { model.createBoard(name) }
                    } else {
                        Button { model.newBoard = "" } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("新建置顶板（会把选中的条目放进去）").accessibilityLabel("新建置顶板（会把选中的条目放进去）")
                    }
                }
            }
            .verticalWheelScrollsHorizontally()
            HStack(spacing: 2) {
                ForEach(ClipKinds.all, id: \.self) { k in
                    let meta = ClipKinds.of(k)
                    Button { model.setKind(list.kind == k ? nil : k) } label: {
                        Image(systemName: meta.icon).frame(width: 26, height: 22)
                            .selectionBackground(list.kind == k)
                    }
                    .buttonStyle(.plain)
                    .help("只看\(meta.label)")
                }
            }
            if model.settings?.pausedUntil != nil {
                Button("已暂停记录 · 恢复", systemImage: "pause.fill") { Task { model.settings = try? await API.shared.clipPause(minutes: 0) } }
                    .buttonStyle(.borderless).foregroundStyle(.orange)
            }
            Button { model.openSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("剪贴板设置（⌘,）").accessibilityLabel("剪贴板设置（⌘,）")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func boardButton(_ id: String?, label: String, icon: String? = nil, dot: String? = nil) -> some View {
        Button { model.setBoard(id) } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                if let dot { Circle().fill(ClipFmt.color(dot)).frame(width: 7, height: 7) }
                Text(label)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(list.board == id ? AnyShapeStyle(Theme.chipFill) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        card(item, index: i)
                            .id(item.id)
                            .offset(y: entering ? 60 : 0)
                            .opacity(entering ? 0 : 1)
                            .animation(.spring(duration: 0.45).delay(Double(min(i, 12)) * 0.025), value: entering)
                            .onAppear { if i >= model.items.count - 8 { list.loadMore() } }
                    }
                    if list.items != nil && model.items.isEmpty {
                        Text(emptyText).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)
            .verticalWheelScrollsHorizontally()
            .onChange(of: model.current?.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id) }
            }
            .onChange(of: model.opening) { if let first = model.items.first { proxy.scrollTo(first.id, anchor: .leading) } }
        }
    }

    private var emptyText: String {
        if !model.query.isEmpty || list.kind != nil { return "没有找到匹配的内容" }
        if list.board != nil { return "这个置顶板还是空的：在条目上右键，选择“置顶到”" }
        return model.settings?.pausedUntil != nil ? "已暂停记录" : "复制一些内容，就会出现在这里"
    }

    private func card(_ item: ClipItem, index i: Int) -> some View {
        let selected = model.current?.id == item.id
        let mark = model.marked.firstIndex(of: item.id).map { $0 + 1 }
        let head = ClipFmt.head(item)
        let board = list.boards.first { $0.id == item.pinboard }
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.isEmpty ? ClipKinds.of(item.kind).label : item.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(ClipFmt.time(item.copiedAt)).font(.caption2).opacity(0.85)
                }
                Spacer(minLength: 0)
                if let board { Image(systemName: "pin.fill").font(.caption).foregroundStyle(ClipFmt.color(board.color)).help("置顶于 \(board.name)") }
                ClipAppIcon(item: item, size: 28)
            }
            .foregroundStyle(ClipFmt.readable(on: head))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ClipFmt.color(head))
            cardBody(item, index: i)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            HStack {
                Text(ClipFmt.meta(item)).lineLimit(1)
                Spacer()
                if let mark {
                    Text("\(mark)").font(.caption2.bold()).foregroundStyle(.white).frame(width: 18, height: 18).background(Color.accentColor, in: Circle())
                } else if i < 9 {
                    Text("⌘\(i + 1)").font(.caption2.monospaced())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(width: 230, height: 236)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(selected || mark != nil ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : mark != nil ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .scaleEffect(selected ? 1.0 : 0.98)
        .animation(.snappy(duration: 0.15), value: selected)
        .overlay {
            ClipMouse(
                onClick: { mods in
                    model.click(item, modifiers: mods)
                    searchFocused = true
                },
                onDoubleClick: { model.paste([item.id]) },
                menu: { [] },
                dragItems: { model.dragItems(item) },
                onDragError: { model.flash($0, error: true) },
                onRightClick: {
                    if !model.marked.contains(item.id) {
                        model.marked = []
                        model.select(item)
                    }
                    // 菜单中的智能操作需要完整文字，查询后再弹出
                    model.popMenu(item)
                }
            )
        }
    }

    @ViewBuilder
    private func cardBody(_ item: ClipItem, index: Int) -> some View {
        // 只有前面的卡片查询问题信息
        let hits = index < 40 ? issues.hits(ClipFmt.itemIssueKeys(item)) : []
        switch item.kind {
        case "image":
            AssetImage(path: "clip/thumb/\(item.id)").frame(maxWidth: .infinity, maxHeight: .infinity)
        case "color":
            let hex = ClipFmt.colorFormats(item.text)?.first?.1 ?? "#000000"
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.body.monospaced())
                .foregroundStyle(ClipFmt.readable(on: hex))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ClipFmt.color(hex), in: RoundedRectangle(cornerRadius: 8))
        case "file":
            ClipFileList(files: item.files, limit: 5)
        case "link":
            VStack(alignment: .leading, spacing: 4) {
                Text(ClipFmt.host(item.text) ?? item.text).font(.callout.weight(.semibold)).lineLimit(1)
                Text(highlighted(item.text.trimmingCharacters(in: .whitespacesAndNewlines), model.list.text)).font(.caption).foregroundStyle(.blue).lineLimit(4)
                if let label = ClipFmt.inAppLabel(item.text) { Label(label, systemImage: "macwindow").font(.caption).foregroundStyle(.secondary) }
                if let hit = hits.first { ClipIssueLine(issue: hit) }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hits) { ClipIssueLine(issue: $0) }
                Text(highlighted(String(item.text.prefix(600)), model.list.text))
                    .font(item.kind == "code" ? .caption.monospaced() : .callout)
                    .lineLimit(nil)
            }
        }
    }

    private var foot: some View {
        HStack(spacing: 12) {
            if let notice = model.notice {
                Text(notice.text).foregroundStyle(notice.error ? .red : .primary)
            } else if model.settings?.config.autoPaste == true && model.settings?.pasteSupport == "needsPermission" {
                Label("在系统设置中允许 NextWorkZone 控制电脑（辅助功能）后，选中即可直接粘贴到 \(model.target ?? "之前的应用")；现在只会复制。", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                Button("去授权") { model.run { try await API.shared.clipRequestPermission() } }.buttonStyle(.link)
            } else {
                Group {
                    Label(model.pasteLabel, systemImage: "return")
                    Text("⇧↩ 纯文本")
                    if model.autoPaste { Text("⌘C 复制") }
                    Text("空格 预览")
                    Text("⌘E 编辑")
                    Text("⌘1–9 快速粘贴")
                    Text("Tab 切换置顶板")
                    Text("⌘⌫ 删除")
                    Text("拖动卡片到其他应用")
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.marked.isEmpty {
                Text("已选 \(model.marked.count) 条 · ↩ 按顺序一起粘贴").foregroundStyle(Color.accentColor)
            } else if let s = model.settings {
                Text("\(s.stats.items.formatted()) 条").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }
}

/// 空格打开的预览层：完整内容、命名、编辑后粘贴、智能操作。
struct ClipPreviewLayer: View {
    var model: ClipPanelModel
    var item: ClipItem
    var edit: Bool
    @State private var text = ""
    @State private var draft: String?
    @State private var title = ""
    @State private var issues = ClipIssues.shared
    @FocusState private var editorFocused: Bool
    @FocusState private var titleFocused: Bool

    var body: some View {
        let hits = issues.hits(ClipFmt.itemIssueKeys(item))
        let actions = model.actions(item, text: text, issues: hits)
        HStack(spacing: 0) {
            Group {
                if let d = draft {
                    TextEditor(text: Binding(get: { d }, set: { draft = $0 }))
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            model.paste([item.id], plain: true, edited: d)
                            return .handled
                        }
                } else {
                    ClipPreviewBody(item: item, text: text, issues: hits)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ClipAppIcon(item: item, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.appName ?? "未知来源")
                        Text([ClipFmt.time(item.copiedAt), item.copyCount > 1 ? "复制过 \(item.copyCount) 次" : nil, item.hasHtml ? "带格式" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.preview = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("关闭（Esc）").accessibilityLabel("关闭（Esc）")
                }
                TextField("", text: $title, prompt: Text("命名（方便搜索，例如“签名”）"))
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                    .onChange(of: titleFocused) { _, f in if !f { saveTitle() } }
                HStack {
                    if let d = draft {
                        Button("\(model.verb)修改后的内容 ⌘↩") { model.paste([item.id], plain: true, edited: d) }.buttonStyle(.borderedProminent)
                        Button("保存修改") {
                            model.run {
                                _ = try await API.shared.clipUpdateText(item.id, text: d)
                                text = d
                                draft = nil
                            }
                        }
                        .disabled(d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || d == text)
                    } else {
                        Button("\(model.pasteLabel) ↩") { model.paste([item.id]) }.buttonStyle(.borderedProminent)
                        if item.textual { Button("编辑 ⌘E") { model.preview = .edit } }
                    }
                }
                .controlSize(.small)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(actions) { a in
                            Button { model.run { try await a.run() } } label: {
                                Label(a.label, systemImage: a.icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 300)
        }
        // 盖在面板上的同一种玻璃（两层叠起来更不透明，预览的文字更好读）
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
        .task {
            text = item.text
            title = item.title
            if item.truncated {
                do { text = try await API.shared.clipText(item.id).text } catch { if !isCancellation(error) { model.flash(errorMessage(error), error: true) } }
            }
            if edit {
                draft = text
                editorFocused = true
            }
        }
    }

    private func saveTitle() {
        guard title.trimmingCharacters(in: .whitespaces) != item.title else { return }
        model.run { _ = try await API.shared.clipRename(item.id, title: title) }
    }
}
