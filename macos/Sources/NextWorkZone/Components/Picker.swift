import SwiftUI

/// 边输入边搜索的选择框（Jira 用户、问题、标签等）。`multiple` 为真时可以选多个，已选的显示为标签。
struct SearchPicker<Item: Hashable>: View {
    var selected: [Item]
    var onChange: ([Item]) -> Void
    var search: (String) async throws -> [Item]
    var label: (Item) -> String
    var detail: (Item) -> String = { _ in "" }
    var placeholder = "输入搜索"
    var multiple = false
    /// 获得焦点时（还没有输入）就列出候选
    var searchOnFocus = false
    /// 未输入时候选列表的标题，例如“建议”
    var idleHeading: String? = nil
    /// 允许直接使用输入的文字（例如新标签）
    var allowCustom: ((String) -> Item)? = nil
    /// 候选数据异步加载时传入（例如条数）：变化后重新搜索。否则聚焦时数据还没到，候选列表一直是空的
    var sourceVersion: Int = 0

    @State private var text = ""
    @State private var results: [Item] = []
    @State private var open = false
    @State private var loading = false
    @State private var error: String?
    @State private var active = 0
    @State private var debouncer = Debouncer()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if multiple && !selected.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selected, id: \.self) { item in
                        HStack(spacing: 3) {
                            Text(label(item)).lineLimit(1)
                            Button {
                                onChange(selected.filter { $0 != item })
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .chipBackground()
                    }
                }
            }
            HStack {
                TextField(!multiple && !selected.isEmpty ? label(selected[0]) : placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onChange(of: text) { _, q in query(q) }
                    .onChange(of: focused) { _, f in
                        if f && searchOnFocus && text.isEmpty { query("") }
                    }
                    .onChange(of: sourceVersion) {
                        if focused && (searchOnFocus || !text.isEmpty) { query(text) }
                    }
                    .onKeyPress(.downArrow) { active = min(active + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { active = max(active - 1, 0); return .handled }
                    .onKeyPress(.escape) {
                        guard open else { return .ignored }
                        open = false
                        return .handled
                    }
                    .onSubmit {
                        if results.indices.contains(active) { choose(results[active]) }
                        else if let allowCustom, !text.trimmingCharacters(in: .whitespaces).isEmpty { choose(allowCustom(text.trimmingCharacters(in: .whitespaces))) }
                    }
                if loading { ProgressView().controlSize(.small) }
                if !multiple && !selected.isEmpty {
                    Button("清除", systemImage: "xmark.circle.fill") { onChange([]) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $open, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                candidates
            }
        }
    }

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let idleHeading, text.isEmpty {
                Text(idleHeading).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(10)
            } else if results.isEmpty {
                Text(loading ? "搜索中…" : "没有匹配的结果").font(.callout).foregroundStyle(.secondary).padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.offset) { i, item in
                            Button {
                                choose(item)
                            } label: {
                                HStack {
                                    Text(label(item)).lineLimit(1)
                                    let d = detail(item)
                                    if !d.isEmpty { Text(d).foregroundStyle(.secondary).lineLimit(1) }
                                    Spacer(minLength: 0)
                                    if selected.contains(item) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .selectionBackground(i == active)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 360)
    }

    private func query(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty && !searchOnFocus {
            open = false
            results = []
            return
        }
        loading = true
        debouncer.run(after: .milliseconds(250)) {
            do {
                let list = try await search(trimmed)
                results = list
                error = nil
            } catch {
                self.error = errorMessage(error)
                results = []
            }
            active = 0
            loading = false
            open = focused || !trimmed.isEmpty
        }
    }

    private func choose(_ item: Item) {
        if multiple {
            onChange(selected.contains(item) ? selected.filter { $0 != item } : selected + [item])
        } else {
            onChange([item])
            open = false
        }
        text = ""
        if !multiple { results = [] }
    }
}

/// 自动换行排列（标签等）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
