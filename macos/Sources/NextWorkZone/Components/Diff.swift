import SwiftUI

/// 统一 diff 格式中的一行。
struct DiffRow: Hashable {
    enum Kind { case hunk, add, del, ctx }
    var kind: Kind
    var oldNo: Int?
    var newNo: Int?
    var text: String
}

enum DiffParser {
    /// 解析统一 diff 格式（GitLab 返回的 diff 不含文件头，直接从 @@ 开始）。
    static func parse(_ diff: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldNo = 0
        var newNo = 0
        for line in diff.components(separatedBy: "\n") {
            if let m = line.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
                oldNo = Int(m.1) ?? 0
                newNo = Int(m.2) ?? 0
                rows.append(DiffRow(kind: .hunk, text: line))
            } else if line.hasPrefix("+") {
                rows.append(DiffRow(kind: .add, newNo: newNo, text: String(line.dropFirst())))
                newNo += 1
            } else if line.hasPrefix("-") {
                rows.append(DiffRow(kind: .del, oldNo: oldNo, text: String(line.dropFirst())))
                oldNo += 1
            } else if line.hasPrefix("\\") {
                continue // \ No newline at end of file
            } else if !rows.isEmpty || !line.isEmpty {
                rows.append(DiffRow(kind: .ctx, oldNo: oldNo, newNo: newNo, text: String(line.dropFirst())))
                oldNo += 1
                newNo += 1
            }
        }
        // 末尾的空行来自 diff 文本结尾的换行
        while let last = rows.last, last.kind == .ctx, last.text.isEmpty { rows.removeLast() }
        return rows
    }

    /// 连续的删除行与紧随其后的新增行逐行配对（第 n 个删除对第 n 个新增）。
    static func pairs(_ rows: [DiffRow]) -> [Int: String] {
        var map: [Int: String] = [:]
        var i = 0
        while i < rows.count {
            guard rows[i].kind == .del else { i += 1; continue }
            var dels: [Int] = []
            while i < rows.count && rows[i].kind == .del { dels.append(i); i += 1 }
            var adds: [Int] = []
            while i < rows.count && rows[i].kind == .add { adds.append(i); i += 1 }
            for (n, d) in dels.enumerated() where n < adds.count {
                map[d] = rows[adds[n]].text
                map[adds[n]] = rows[d].text
            }
        }
        return map
    }

    /// 去掉相同的开头和结尾，突出中间改动的部分。
    static func changed(_ text: String, other: String, tint: Color) -> AttributedString {
        let a = Array(text), b = Array(other)
        var start = 0
        while start < a.count && start < b.count && a[start] == b[start] { start += 1 }
        var end = 0
        while end < a.count - start && end < b.count - start && a[a.count - 1 - end] == b[b.count - 1 - end] { end += 1 }
        var out = AttributedString(String(a[..<start]))
        var mid = AttributedString(String(a[start..<(a.count - end)]))
        mid.backgroundColor = tint.opacity(0.35)
        out += mid
        out += AttributedString(String(a[(a.count - end)...]))
        return out
    }
}

/// 文字差异（Wiki 历史、保存前预览）：成对的删除、新增行中标出改动的部分。
struct TextDiffView: View {
    var diff: String

    var body: some View {
        let rows = DiffParser.parse(diff)
        let pairs = DiffParser.pairs(rows)
        if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("文字内容没有变化。").foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    HStack(alignment: .top, spacing: 6) {
                        Text(r.kind == .add ? "+" : r.kind == .del ? "−" : r.kind == .hunk ? "" : " ").font(.system(.callout, design: .monospaced)).frame(width: 14)
                        if r.kind == .hunk {
                            Text("…").foregroundStyle(.secondary)
                        } else if let other = pairs[i] {
                            Text(DiffParser.changed(r.text, other: other, tint: r.kind == .add ? .green : .red))
                        } else {
                            Text(r.text)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(r.kind == .add ? Color.green.opacity(0.1) : r.kind == .del ? Color.red.opacity(0.1) : .clear)
                    .textSelection(.enabled)
                }
            }
        }
    }
}

/// 改动中的一行：新文件的行号优先，删除的行用旧文件行号。
struct DiffLine: Hashable {
    var oldLine: Int?
    var newLine: Int?

    /// 行的定位键，用于把评论挂到行下面。
    func key(_ path: String) -> String {
        newLine != nil ? "\(path)\n+\(newLine!)" : "\(path)\n-\(oldLine ?? 0)"
    }
}

/// 行内评论（合并请求）：`threads` 按行的定位键放在对应行下面；
/// 提供 `onComment` 时，可以在某一行发表评论。
struct DiffAnnotations {
    var threads: [String: [Discussion]] = [:]
    var thread: (Discussion) -> AnyView = { _ in AnyView(EmptyView()) }
    var onComment: ((FileDiff, DiffLine, String) async throws -> Void)?
}

/// 多个文件的改动：上方是文件列表，下面逐个文件显示（行数多的文件默认折叠）。
struct DiffListView: View {
    var diffs: [FileDiff]
    var annotations: DiffAnnotations? = nil

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(diffs.enumerated()), id: \.offset) { i, d in
                        Button {
                            withAnimation { proxy.scrollTo("diff-\(i)", anchor: .top) }
                        } label: {
                            HStack(spacing: 6) {
                                FileBadge(diff: d)
                                Text(d.newPath).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                ForEach(Array(diffs.enumerated()), id: \.offset) { i, d in
                    FileDiffView(diff: d, annotations: annotations).id("diff-\(i)")
                }
            }
        }
    }
}

struct FileBadge: View {
    var diff: FileDiff

    var body: some View {
        let (text, tint): (String, Color) = diff.newFile ? ("新增", .green) : diff.deletedFile ? ("删除", .red) : diff.renamedFile ? ("重命名", .blue) : ("修改", .secondary)
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint).padding(.horizontal, 5).padding(.vertical, 1).background(tint.opacity(0.12), in: Capsule())
    }
}

private struct FileDiffView: View {
    var diff: FileDiff
    var annotations: DiffAnnotations?
    /// 行数超过这个值的文件默认折叠。
    static let collapseRows = 400

    @State private var open: Bool?
    @State private var composing: Int?

    var body: some View {
        let rows = DiffParser.parse(diff.diff)
        let added = rows.filter { $0.kind == .add }.count
        let removed = rows.filter { $0.kind == .del }.count
        let hasThreads = annotations?.threads.keys.contains { $0.hasPrefix("\(diff.newPath)\n") } ?? false
        let isOpen = open ?? (rows.count <= Self.collapseRows || hasThreads)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open = !isOpen
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption)
                    FileBadge(diff: diff)
                    Text(diff.renamedFile ? "\(diff.oldPath) → \(diff.newPath)" : diff.newPath).lineLimit(1)
                    Spacer()
                    if hasThreads { Image(systemName: "text.bubble").foregroundStyle(.secondary) }
                    Text("+\(added)").foregroundStyle(.green)
                    Text("−\(removed)").foregroundStyle(.red)
                }
                .font(.callout)
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.35))
            if isOpen {
                if rows.isEmpty {
                    Text("没有可显示的文本改动（可能是二进制文件或改动过大）。").font(.caption).foregroundStyle(.secondary).padding(8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows.indices, id: \.self) { i in
                            row(rows[i], index: i)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    @ViewBuilder
    private func row(_ r: DiffRow, index i: Int) -> some View {
        let line = DiffLine(oldLine: r.kind == .add ? nil : r.oldNo, newLine: r.kind == .del ? nil : r.newNo)
        let key = r.kind == .hunk ? nil : line.key(diff.newPath)
        HStack(alignment: .top, spacing: 0) {
            Text(r.oldNo.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.tertiary)
            Text(r.newNo.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.tertiary)
            Text(r.kind == .add ? "+" : r.kind == .del ? "−" : "").frame(width: 18).foregroundStyle(.secondary)
            Text(r.kind == .hunk ? r.text : r.text.isEmpty ? " " : r.text)
                .foregroundStyle(r.kind == .hunk ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if annotations?.onComment != nil, key != nil {
                Button {
                    composing = composing == i ? nil : i
                } label: { Image(systemName: "plus.bubble") }
                .buttonStyle(.borderless)
                .help("评论这一行")
                .padding(.trailing, 6)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(r.kind == .add ? Color.green.opacity(0.12) : r.kind == .del ? Color.red.opacity(0.12) : r.kind == .hunk ? Color.blue.opacity(0.06) : .clear)
        if let key, let threads = annotations?.threads[key] {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(threads) { d in annotations!.thread(d) }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
        }
        if composing == i, let onComment = annotations?.onComment {
            CommentBox(placeholder: "评论第 \(r.newNo ?? r.oldNo ?? 0) 行（⌘↵ 发送，Esc 取消）", onCancel: { composing = nil }) { body in
                try await onComment(diff, line, body)
                composing = nil
            }
            .padding(10)
        }
    }
}
