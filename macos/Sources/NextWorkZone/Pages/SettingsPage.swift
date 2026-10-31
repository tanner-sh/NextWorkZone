import AppKit
import SwiftUI

/// 设置：工作空间、工具、Jira 本机问题库、Wiki 本机库（修改后立即生效），以及连接的系统地址与凭据（需要保存）。显示在单独的设置窗口中。
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var proxy = ""
    @State private var baseUrls: [Service: String] = [:]
    @State private var tokens: [Service: String] = [:]
    @State private var accounts: [Service: WebAccountInput] = [:]
    @State private var tests: [Service: TestState] = [:]
    @State private var notice: (ok: Bool, text: String)?
    @Namespace private var saveBar
    @State private var saving = false
    @State private var filled = false

    enum TestState {
        case testing
        case ok(ConnectionInfo)
        case failed(String)
    }

    static let serviceMeta: [Service: (kind: String, placeholder: String, icon: String)] = [
        .jira: ("Jira Server / Data Center", "https://jira.example.com", "smallcircle.filled.circle"),
        .confluence: ("Confluence Server / Data Center", "https://wiki.example.com", "text.book.closed"),
        .gitlab: ("GitLab", "https://gitlab.example.com", "arrow.triangle.branch"),
    ]

    private func fill(_ s: Settings) {
        proxy = s.proxy
        baseUrls = Dictionary(uniqueKeysWithValues: s.services.map { ($0.service, $0.baseUrl) })
        tokens = [:]
        accounts = Dictionary(uniqueKeysWithValues: s.services.filter(\.supportsWebLogin).map { ($0.service, WebAccountInput(username: $0.webUsername, password: "")) })
    }

    private var dirty: Bool {
        guard let s = model.settings else { return false }
        return proxy != s.proxy || s.services.contains(where: serviceDirty)
    }

    /// 这个系统的地址或凭据有没保存的修改
    private func serviceDirty(_ svc: ServiceSettings) -> Bool {
        let account = accounts[svc.service]
        return (baseUrls[svc.service] ?? "") != svc.baseUrl
            || !(tokens[svc.service] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || (svc.supportsWebLogin && account != nil && (account!.username != svc.webUsername || !account!.password.isEmpty))
    }

    enum Tab: String { case general, connection, index }
    @AppStorage("nextworkzone.settings.tab") private var tab: Tab = .general

    /// 设置窗口（⌘,）：通用（工作空间、工具）、连接（地址与凭据，需要保存）、本机库（Jira、Wiki 本机问题库，配置好对应系统后出现）。
    var body: some View {
        Group {
            if let settings = model.settings {
                TabView(selection: $tab) {
                    Form {
                        WorkspaceSettingsSection()
                        WeeklySettingsSection()
                        ToolsSettingsSection()
                    }
                    .formStyle(.grouped)
                    .tabItem { Label("通用", systemImage: "gearshape") }
                    .tag(Tab.general)

                    connection(settings)
                        .tabItem { Label("连接", systemImage: "network") }
                        .tag(Tab.connection)

                    if model.isReady(.jira) || model.isReady(.confluence) {
                        Form {
                            if model.isReady(.jira) { JiraToolsSettingsSection() }
                            if model.isReady(.confluence) { WikiToolsSettingsSection() }
                        }
                        .formStyle(.grouped)
                        .tabItem { Label("本机库", systemImage: "internaldrive") }
                        .tag(Tab.index)
                    }
                }
                .onAppear {
                    if !filled {
                        fill(settings)
                        filled = true
                    }
                }
            } else {
                LoadingView()
            }
        }
        .frame(width: 660)
        .frame(minHeight: 460, idealHeight: 620)
    }

    private func connection(_ settings: Settings) -> some View {
        Form {
            Section {
                Text("连接的系统地址与凭据，修改后需要保存，保存后自动测试连接。凭据只保存在本机。").foregroundStyle(.secondary)
            }

            Section {
                TextField("代理", text: $proxy, prompt: Text("留空则使用系统代理，例如 http://127.0.0.1:7890"))
            } header: {
                Label("网络", systemImage: "globe")
            }

            ForEach(settings.services, id: \.service) { s in serviceSection(s) }
        }
        .formStyle(.grouped)
        // 有未保存的修改时浮在底部，滚到哪里都能保存；表单可以滚到它下面。保存的结果也显示在这里（几秒后消失）
        // 保存条与保存结果是同一块玻璃：保存后整条收缩成结果提示，几秒后消散
        .safeAreaBar(edge: .bottom) {
            GlassEffectContainer {
                if dirty {
                    HStack {
                        if let notice, !notice.ok { Text(notice.text).foregroundStyle(.red).lineLimit(2) } else { Text("连接设置有未保存的修改") }
                        Spacer()
                        Button("放弃修改") { fill(settings); notice = nil }.disabled(saving)
                        Button(saving ? "保存中…" : "保存", action: save).buttonStyle(.borderedProminent).disabled(saving).keyboardShortcut("s", modifiers: .command)
                    }
                    .padding(.leading, 18)
                    .padding([.trailing, .vertical], 8)
                    .glassEffect(.regular, in: Capsule())
                    .glassEffectID("bar", in: saveBar)
                } else if let notice {
                    Label(notice.text, systemImage: notice.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(notice.ok ? .green : .red)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())
                        .glassEffectID("bar", in: saveBar)
                }
            }
            .padding(12)
            .animation(.snappy, value: dirty)
            .animation(.snappy, value: notice?.text)
        }
    }

    @ViewBuilder
    private func serviceSection(_ s: ServiceSettings) -> some View {
        let meta = Self.serviceMeta[s.service]!
        let access = model.access(s.service)
        Section {
            TextField("地址", text: Binding(get: { baseUrls[s.service] ?? "" }, set: { baseUrls[s.service] = $0 }), prompt: Text(meta.placeholder))
            SecureField("访问令牌", text: Binding(get: { tokens[s.service] ?? "" }, set: { tokens[s.service] = $0 }), prompt: Text(s.hasToken ? "已保存（留空则不修改）" : "个人访问令牌（Personal Access Token）"))
            HStack {
                Button("测试连接") { test(s.service) }.disabled(serviceDirty(s) || s.baseUrl.isEmpty || !s.hasToken || { if case .testing = tests[s.service] { return true }; return false }())
                if s.hasToken { Button("删除令牌", role: .destructive) { clearToken(s.service) } }
                if serviceDirty(s) { Text("保存后自动测试").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                switch tests[s.service] {
                case .testing: ProgressView().controlSize(.small)
                case .ok(let info): Text("✓ \(info.displayName)（\(info.username)）\(info.serverVersion.map { " · v\($0)" } ?? "")").foregroundStyle(.green)
                case .failed(let m): Text("✗ \(m)").foregroundStyle(.red).lineLimit(2).help(m)
                case nil: EmptyView()
                }
            }
            if s.supportsWebLogin {
                LabeledContent("网页登录") {
                    HStack {
                        Circle().fill(access == .loginRequired ? Color.orange : access == nil ? Color.secondary : Color.green).frame(width: 7, height: 7)
                        Text(access == .token ? "令牌即可访问，无需登录" : access == .session ? "已登录" : access == .loginRequired ? "需要登录" : "检测中")
                        if access == .session {
                            Button("退出网页登录") { Task { try? await API.shared.webLogout(s.service); await model.refreshSessions() } }
                        } else {
                            Button("网页登录") { WebLogin.open(s.service) }.disabled(s.baseUrl.isEmpty || access == .token)
                        }
                    }
                }
                TextField("账号", text: Binding(get: { accounts[s.service]?.username ?? "" }, set: { accounts[s.service, default: WebAccountInput(username: "", password: "")].username = $0 }), prompt: Text("可选，用于登录窗口自动填写"))
                SecureField("密码", text: Binding(get: { accounts[s.service]?.password ?? "" }, set: { accounts[s.service, default: WebAccountInput(username: "", password: "")].password = $0 }), prompt: Text(s.hasWebPassword ? "已保存（留空则不修改）" : "可选"))
            }
        } header: {
            Label(s.label, systemImage: meta.icon)
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.kind)
                if s.supportsWebLogin {
                    Text("附件、图片等网页内容不走 API。若服务器要求单独的网页登录（例如启用了 2FA 或 SSO），在这里登录一次即可。填写账号密码后，登录窗口会自动填写并提交，你只需完成额外的验证步骤。")
                }
            }
        }
    }

    private func save() {
        guard let current = model.settings else { return }
        saving = true
        // 改了代理时所有系统都重新测试，否则只测改过的
        let changed = current.services.filter { proxy != current.proxy || serviceDirty($0) }.map(\.service)
        Task {
            do {
                let input = SettingsInput(
                    proxy: proxy,
                    baseUrls: Dictionary(uniqueKeysWithValues: baseUrls.map { ($0.key.rawValue, $0.value) }),
                    tokens: Dictionary(uniqueKeysWithValues: tokens.map { ($0.key.rawValue, $0.value) }),
                    weeklyPage: current.weeklyPageId,
                    weeklyPersonName: current.weeklyPersonName,
                    webAccounts: Dictionary(uniqueKeysWithValues: accounts.map { ($0.key.rawValue, $0.value) })
                )
                let next = try await API.shared.saveSettings(input)
                model.setSettings(next)
                fill(next)
                tests = [:]
                showNotice(true, "设置已保存")
                for svc in next.services where changed.contains(svc.service) && !svc.baseUrl.isEmpty && svc.hasToken { test(svc.service) }
            } catch {
                guard !isCancellation(error) else { return }
                notice = (false, errorMessage(error))
            }
            saving = false
        }
    }

    /// 成功的提示几秒后消失，失败的一直显示到下次修改
    private func showNotice(_ ok: Bool, _ text: String) {
        notice = (ok, text)
        guard ok else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice?.text == text { notice = nil }
        }
    }

    private func clearToken(_ service: Service) {
        Task {
            do {
                let next = try await API.shared.clearToken(service)
                model.setSettings(next)
                fill(next)
                tests[service] = nil
                showNotice(true, "已删除 \(service.label) 的令牌")
            } catch {
                guard !isCancellation(error) else { return }
                notice = (false, errorMessage(error))
            }
        }
    }

    private func test(_ service: Service) {
        tests[service] = .testing
        Task {
            do { tests[service] = .ok(try await API.shared.testConnection(service)) } catch { if !isCancellation(error) { tests[service] = .failed(errorMessage(error)) } }
        }
    }
}

/// 快捷键录制：点击后按下新的组合键（至少一个修饰键加一个普通键），Esc 取消。
struct ShortcutField: View {
    var value: String
    var defaultValue: String
    var disabled = false
    var onChange: (String) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "按下新的快捷键…（Esc 取消）" : HotKeys.display(value)).frame(minWidth: 120)
            }
            .disabled(disabled)
            if value != defaultValue { Button("恢复默认") { onChange(defaultValue) }.buttonStyle(.borderless).disabled(disabled) }
            if !value.isEmpty { Button("不使用") { onChange("") }.buttonStyle(.borderless).disabled(disabled) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if let shortcut = HotKeys.shortcut(of: event) {
                stop()
                onChange(shortcut)
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - 工作空间

/// 工作空间设置：同步文件夹、快速记录快捷键、Jira 问题自动加入待办。修改后立即生效。
/// 周报：周报所在的 Wiki 页面和表格中自己的名字。改完（回车或离开输入框）立即保存。
private struct WeeklySettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var page = ""
    @State private var name = ""
    @State private var status: (ok: Bool, text: String)?
    @FocusState private var focused: Bool

    var body: some View {
        Section {
            TextField("周报页面", text: $page, prompt: Text("Wiki 页面地址或页面 ID"))
                .focused($focused)
                .onSubmit(save)
            TextField("我的名字", text: $name, prompt: Text("表格第一列中你的名字，留空则使用 Wiki 显示名"))
                .focused($focused)
                .onSubmit(save)
            if let status { Text(status.text).font(.callout).foregroundStyle(status.ok ? .green : .red) }
        } header: {
            Label("周报", systemImage: "square.and.pencil")
        } footer: {
            Text("每周一个以日期范围开头的一级标题，表格中第一列是人名的那一行即为你的周报。\(model.isReady(.confluence) ? "" : "需要先在“连接”中配置 Wiki。")")
        }
        .onAppear {
            page = model.settings?.weeklyPageId ?? ""
            name = model.settings?.weeklyPersonName ?? ""
        }
        .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard let s = model.settings else { return }
        let p = page.trimmingCharacters(in: .whitespacesAndNewlines), n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p != s.weeklyPageId || n != s.weeklyPersonName else { return }
        Task {
            do {
                // 只改周报两项，代理、地址、凭据保持原样
                let next = try await API.shared.saveSettings(SettingsInput(proxy: s.proxy, weeklyPage: p, weeklyPersonName: n))
                model.setSettings(next)
                page = next.weeklyPageId
                name = next.weeklyPersonName
                status = (true, "已保存")
                try? await Task.sleep(for: .seconds(2))
                if status?.ok == true { status = nil }
            } catch {
                guard !isCancellation(error) else { return }
                status = (false, errorMessage(error))
            }
        }
    }
}

private struct WorkspaceSettingsSection: View {
    @State private var settings: WorkspaceSettings?
    @State private var busy = false
    @State private var choosingFolder = false
    @State private var error: String?

    var body: some View {
        Section {
            if let s = settings {
                LabeledContent("同步文件夹") {
                    HStack {
                        Text(s.syncDir.isEmpty ? "未设置，仅保存在本机" : s.syncDir).foregroundStyle(s.syncDir.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                        Button("选择…") { choosingFolder = true }.disabled(busy)
                            .folderPicker(isPresented: $choosingFolder) { update($0, s.jiraTodos) }
                        if !s.syncDir.isEmpty { Button("停止同步") { update("", s.jiraTodos) }.disabled(busy) }
                    }
                }
                if !s.syncDir.isEmpty {
                    LabeledContent("同步状态") {
                        HStack {
                            Text(s.lastError.map { "同步失败：\($0)" } ?? s.lastSync.map { "\(Fmt.time(ms: $0.finishedAt)) 同步完成 · 其他设备 \($0.devices) 台\($0.conflicts > 0 ? " · \($0.conflicts) 个冲突副本" : "")" } ?? "尚未同步")
                                .foregroundStyle(s.lastError != nil ? .red : .secondary)
                            Button("立即同步", systemImage: "arrow.clockwise", action: syncNow).disabled(busy)
                        }
                    }
                }
                LabeledContent("快速记录") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ShortcutField(value: s.captureShortcut, defaultValue: "Alt+Space", disabled: busy) { shortcut in
                            Task {
                                do { settings = try await API.shared.wsSaveCaptureShortcut(shortcut) } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
                            }
                        }
                        if let e = s.captureError { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                }
                Toggle("自动把分配给我的未解决 Jira 问题加入待办（问题解决后自动完成）", isOn: Binding(get: { s.jiraTodos }, set: { update(s.syncDir, $0) })).disabled(busy)
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Label("工作空间", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text("待办、笔记、知识库保存在本机。设置一个同步文件夹（iCloud Drive、坚果云、NAS 等）后，多台电脑会通过它自动同步。快速记录：在任何应用中按下快捷键即可弹出，记一条待办或写一笔日记。")
        }
        .task {
            do { settings = try await API.shared.wsSettings() } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
        }
    }

    private func update(_ dir: String, _ jiraTodos: Bool) {
        busy = true
        error = nil
        Task {
            do {
                settings = try await API.shared.wsSaveSettings(syncDir: dir, jiraTodos: jiraTodos)
                Events.workspaceChanged()
            } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            busy = false
        }
    }

    private func syncNow() {
        busy = true
        error = nil
        Task {
            do {
                _ = try await API.shared.wsSync()
                Events.workspaceChanged()
            } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            settings = (try? await API.shared.wsSettings()) ?? settings
            busy = false
        }
    }
}

// MARK: - 工具

/// 工具：每个工具的简要设置、是否在侧边栏显示，以及进入完整设置。
private struct ToolsSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(Tools.all) { tool in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(tool.name, systemImage: tool.icon).fontWeight(.semibold)
                        Spacer()
                        Button("设置…") { model.navigate(NavTarget(.tools, tool: tool.id, toolTab: "settings")) }
                    }
                    Text(tool.description).font(.caption).foregroundStyle(.secondary)
                    if tool.id == "clipboard" { ClipboardSummary() }
                    Toggle("在侧边栏显示", isOn: Binding(get: { !model.hiddenTools.contains(tool.id) }, set: { show in
                        let next = show ? model.hiddenTools.filter { $0 != tool.id } : model.hiddenTools + [tool.id]
                        Task { if let saved = try? await API.shared.toolsSetHidden(next) { model.hiddenTools = saved } }
                    }))
                }
            }
        } header: {
            Label("工具", systemImage: "wrench.and.screwdriver")
        } footer: {
            Text("提高效率的小工具。每个工具都可以从侧边栏、⌘K 搜索中打开。")
        }
    }
}

/// 剪贴板的简要设置（开关、快捷键、已保存条数）。
struct ClipboardSummary: View {
    @State private var settings: ClipSettings?

    var body: some View {
        HStack {
            if let s = settings {
                Toggle("记录剪贴板历史", isOn: Binding(get: { s.config.enabled }, set: { on in
                    var c = s.config
                    c.enabled = on
                    Task { settings = try? await API.shared.clipSaveSettings(c) }
                }))
                if s.config.enabled { Text("快捷键 \(HotKeys.display(s.config.shortcut)) · 已保存 \(s.stats.items) 条").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task { settings = try? await API.shared.clipSettings() }
        .onEvent(AppEvent.clipSettings) { _ in Task { settings = try? await API.shared.clipSettings() } }
    }
}

// MARK: - Jira 本机问题库

/// Jira 增强功能：本机问题库、到期提醒、模板。修改后立即生效。
private struct JiraToolsSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var settings: JiraToolsSettings?
    @State private var jqlDraft = ""
    @State private var custom = false
    @State private var dateFields: [FieldInfo] = []
    @State private var error: String?
    @State private var busy = false
    @State private var managing = false
    @State private var store = IndexStatusStore.shared

    private static let dayOptions = [(180, "最近半年"), (365, "最近一年"), (730, "最近两年"), (1825, "最近五年"), (0, "全部")]

    var body: some View {
        Section {
            if let s = settings {
                Toggle("启用本机问题库（每 10 分钟同步一次有变化的问题）", isOn: Binding(get: { s.indexEnabled }, set: { v in update { $0.indexEnabled = v } })).disabled(busy)
                if s.indexEnabled {
                    let status = store.status
                    LabeledContent("状态") {
                        HStack {
                            Text(statusText(status)).foregroundStyle(status?.error != nil ? .red : .secondary).lineLimit(2)
                            Button("立即同步", systemImage: "arrow.clockwise") { Task { try? await API.shared.jiraIndexSync() } }.disabled(status?.running == true)
                            Button("重建") { Task { do { _ = try await API.shared.jiraIndexRebuild() } catch { if !isCancellation(error) { self.error = errorMessage(error) } } } }.disabled(status?.running == true).help("清空本机数据后重新同步")
                        }
                    }
                    if let status, !status.projects.isEmpty {
                        LabeledContent("已同步") { Text(status.projects.map { "\($0.name)（\($0.count)）" }.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                    }
                    Picker("范围", selection: Binding(get: { custom }, set: { c in
                        custom = c
                        if !c { update { $0.indexJql = "" } } else if jqlDraft.isEmpty { jqlDraft = "project in ()" }
                    })) {
                        Text("自动：我经办过或报告过问题的项目").tag(false)
                        Text("自定义 JQL").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    if custom {
                        HStack {
                            TextField("", text: $jqlDraft, prompt: Text("例如 project in (ABC, DEF)"))
                            Button("应用") { update { $0.indexJql = jqlDraft } }.disabled(busy || jqlDraft.trimmingCharacters(in: .whitespaces) == s.indexJql)
                        }
                    }
                    Picker("创建时间", selection: Binding(get: { s.indexDays }, set: { v in update { $0.indexDays = v } })) {
                        ForEach(Self.dayOptions, id: \.0) { Text("\($0.1)创建的问题").tag($0.0) }
                    }
                }
                Picker("到期字段", selection: Binding(get: { s.dueField }, set: { v in update { $0.dueField = v } })) {
                    Text("自动识别\(s.dueField.isEmpty ? "（当前：\(model.reminders?.dueField?.name ?? "未识别到")）" : "")").tag("")
                    Text("到期日（duedate）").tag("duedate")
                    ForEach(dateFields.filter { $0.id != "duedate" }) { Text($0.name).tag($0.id) }
                }
                Picker("提前提醒", selection: Binding(get: { s.dueSoonDays }, set: { v in update { $0.dueSoonDays = v } })) {
                    ForEach([0, 1, 2, 3, 5, 7], id: \.self) { d in Text(d == 0 ? "只提醒当天和逾期" : "到期前 \(d) 天").tag(d) }
                }
                Picker("停滞提醒", selection: Binding(get: { s.staleDays }, set: { v in update { $0.staleDays = v } })) {
                    ForEach([0, 3, 5, 7, 14, 30], id: \.self) { d in Text(d == 0 ? "不提醒" : "\(d) 天没有更新").tag(d) }
                }
                Toggle("发送系统通知（逾期、今天到期的问题，每天一次；当天新出现的再单独通知）", isOn: Binding(get: { s.remind }, set: { v in update { $0.remind = v } }))
                LabeledContent("评论与流转模板") {
                    Button("管理模板") { managing = true }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Label("Jira 本机问题库", systemImage: "cylinder.split.1x2")
        } footer: {
            Text("把问题的概要、描述和评论同步到本机，搜索即时出结果、可以离线使用，相似问题也会显示别人的处理过程。只读取 Jira，不做任何修改。修改范围后会重新同步，首次同步上万个问题需要几分钟。到期提醒：我的未解决问题快到期、已逾期或长时间没有更新时，在列表和首页标出。常用的回复和流转可以存为模板，随工作空间同步。")
        }
        .sheet(isPresented: $managing) { ManageTemplatesSheet() }
        .task {
            store.start()
            do {
                let s = try await API.shared.jiraToolsSettings()
                settings = s
                jqlDraft = s.indexJql
                custom = !s.indexJql.isEmpty
            } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            dateFields = ((try? await API.shared.jiraFields()) ?? []).filter { $0.kind == "date" || $0.kind == "datetime" }
        }
    }

    private func statusText(_ status: IndexStatus?) -> String {
        guard let status else { return "读取中…" }
        if status.running { return "正在同步\(status.progress.map { "：\($0.scope) \($0.done)/\($0.total)（第 \($0.finished + 1)/\($0.scopes) 个范围）" } ?? "…") · 已有 \(status.count) 个问题" }
        if let e = status.error { return "同步失败：\(e)" }
        return status.count > 0 ? "\(status.count) 个问题 · \(status.projects.count) 个项目\(status.lastSync.map { " · \(Fmt.time($0)) 同步" } ?? "")" : "尚未同步"
    }

    private func update(_ patch: (inout JiraToolsSettings) -> Void) {
        guard var next = settings else { return }
        patch(&next)
        busy = true
        error = nil
        Task {
            do {
                let saved = try await API.shared.jiraSaveToolsSettings(next)
                settings = saved
                jqlDraft = saved.indexJql
                _ = try? await model.checkReminders(withNotify: false)
            } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            busy = false
        }
    }
}

// MARK: - Wiki 本机库

/// 本机 Wiki 库的状态，同步过程中随进度更新。
@MainActor @Observable
final class WikiIndexStore {
    static let shared = WikiIndexStore()
    var status: WikiIndexStatus?
    private var started = false
    private var pending = false

    func start() {
        guard !started else { refresh(); return }
        started = true
        refresh()
        NotificationCenter.default.addObserver(forName: Events.name(AppEvent.wikiIndex), object: nil, queue: .main) { _ in
            Task { @MainActor in
                let s = WikiIndexStore.shared
                guard !s.pending else { return }
                s.pending = true
                try? await Task.sleep(for: .seconds(1))
                s.pending = false
                s.refresh()
            }
        }
    }

    func refresh() {
        Task { if let s = try? await API.shared.wikiIndexStatus() { status = s } }
    }
}

/// Wiki 增强功能：本机 Wiki 库、页面任务同步为待办、Wiki 动态。修改后立即生效。
private struct WikiToolsSettingsSection: View {
    @State private var settings: WikiToolsSettings?
    @State private var spaces: [WikiSpace] = []
    @State private var mutedDraft = ""
    @State private var error: String?
    @State private var busy = false
    @State private var store = WikiIndexStore.shared

    var body: some View {
        Section {
            if let s = settings {
                Toggle("启用本机 Wiki 库（每 10 分钟同步一次有变化的页面）", isOn: Binding(get: { s.indexEnabled }, set: { v in update { $0.indexEnabled = v } })).disabled(busy)
                if s.indexEnabled {
                    let status = store.status
                    LabeledContent("状态") {
                        HStack {
                            Text(statusText(status)).foregroundStyle(status?.error != nil ? .red : .secondary)
                            Button("立即同步", systemImage: "arrow.clockwise") { Task { try? await API.shared.wikiIndexSync() } }.disabled(status?.running == true)
                            Button("重建") { Task { do { _ = try await API.shared.wikiIndexRebuild() } catch { if !isCancellation(error) { self.error = errorMessage(error) } } } }.disabled(status?.running == true).help("清空本机数据后重新同步")
                        }
                    }
                    Picker("范围", selection: Binding(get: { s.indexSpaces.isEmpty }, set: { all in
                        if all { update { $0.indexSpaces = [] } } else if let first = spaces.first { update { $0.indexSpaces = [first.key] } }
                    })) {
                        Text("全部可见的空间").tag(true)
                        Text("只同步选中的空间").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if !s.indexSpaces.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading) {
                            ForEach(spaces) { space in
                                Toggle(space.name, isOn: Binding(get: { s.indexSpaces.contains(space.key) }, set: { on in
                                    update { $0.indexSpaces = on ? $0.indexSpaces + [space.key] : $0.indexSpaces.filter { $0 != space.key } }
                                }))
                                .toggleStyle(.checkbox)
                                .font(.callout)
                            }
                        }
                    }
                }
                Toggle("把分配给我的页面任务加入待办", isOn: Binding(get: { s.taskTodos }, set: { v in update { $0.taskTodos = v } }))
                Toggle("在动态中显示 Wiki", isOn: Binding(get: { s.activity }, set: { v in update { $0.activity = v } }))
                if s.activity {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("不提示修改的页面（页面地址或 id，每行一个）").font(.callout)
                        TextEditor(text: $mutedDraft).frame(height: 54).font(.callout)
                        HStack {
                            Text("经常被多人修改的汇总页面可以放在这里。").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            let muted = mutedPages
                            Button("保存") { update { $0.mutedPages = muted } }.disabled(busy || muted == s.mutedPages)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Label("Wiki 本机库", systemImage: "cylinder.split.1x2")
        } footer: {
            Text("把页面的标题和正文同步到本机：搜索即时出结果、能搜到两个字的中文词；也用于在 Jira 问题中显示引用它的 Wiki 页面，以及找出分配给你的页面任务。只读取 Wiki，不做任何修改。页面任务：页面中 @你 的未完成任务自动加入待办，在待办中勾选完成时同时勾选页面上的任务。Wiki 动态：在“动态”中显示 Wiki 上的评论、提到、分享，以及你关注或创建的页面被别人修改。")
        }
        .task {
            store.start()
            do {
                let s = try await API.shared.wikiToolsSettings()
                settings = s
                mutedDraft = s.mutedPages.joined(separator: "\n")
            } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            if let cached = try? await API.shared.wikiCachedSpaces() { spaces = cached }
            if let fresh = try? await API.shared.wikiSpaces() { spaces = fresh }
        }
    }

    private var mutedPages: [String] {
        mutedDraft.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).map { s in
            String(s).firstMatch(of: /pageId=(\d+)/).map { String($0.1) } ?? String(s).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private func statusText(_ status: WikiIndexStatus?) -> String {
        guard let status else { return "读取中…" }
        if status.running { return "正在同步\(status.progress.map { "：\($0.done)/\($0.total)" } ?? "…") · 已有 \(status.count) 个页面" }
        if let e = status.error { return "同步失败：\(e)" }
        return status.count > 0 ? "\(status.count) 个页面 · \(status.spaces.count) 个空间\(status.lastSync.map { " · \(Fmt.time($0)) 同步" } ?? "")" : "尚未同步"
    }

    private func update(_ patch: (inout WikiToolsSettings) -> Void) {
        guard var next = settings else { return }
        patch(&next)
        busy = true
        error = nil
        Task {
            do {
                let saved = try await API.shared.wikiSaveToolsSettings(next)
                settings = saved
                mutedDraft = saved.mutedPages.joined(separator: "\n")
            } catch { if !isCancellation(error) { self.error = errorMessage(error) } }
            busy = false
        }
    }
}
