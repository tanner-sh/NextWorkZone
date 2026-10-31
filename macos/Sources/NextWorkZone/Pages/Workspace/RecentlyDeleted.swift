import SwiftUI

/// 最近删除：30 天内删除的笔记、日记（或知识库页面），可以恢复。知识库页面连同一起删掉的子页面恢复。
struct RecentlyDeletedSheet: View {
    /// note（笔记和日记）或 page（知识库）
    var kinds: Set<String>
    /// 恢复后打开
    var onRestored: (DocSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var docs: [DocSummary]?
    @State private var error: String?

    static let days = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近删除").font(.headline)
            Text("保留 \(Self.days) 天内删除的内容，恢复后回到原来的位置。").font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(docs ?? []) { doc in
                    HStack {
                        Image(systemName: doc.kind == "daily" ? "calendar" : doc.kind == "page" ? "doc.text" : "note.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.kind == "daily" ? "\(doc.day ?? doc.title) 的日记" : doc.title.isEmpty ? "无标题" : doc.title).lineLimit(1)
                            Text("删除于 \(Fmt.time(ms: doc.updatedAt))\(doc.excerpt.isEmpty ? "" : " · \(doc.excerpt)")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("恢复") { restore(doc) }
                    }
                    .padding(.vertical, 2)
                }
                if docs?.isEmpty == true {
                    Text("没有最近删除的内容").foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)
            .overlay { if docs == nil && error == nil { ProgressView() } }
            if let error { ErrorBox(message: error) }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
    }

    private func load() async {
        do {
            let since = Fmt.nowMs() - Int64(Self.days) * 86_400_000
            docs = try await API.shared.wsDeletedDocs(since: since).filter { kinds.contains($0.kind) }
            error = nil
        } catch {
            guard !isCancellation(error) else { return }
            self.error = errorMessage(error)
        }
    }

    private func restore(_ doc: DocSummary) {
        Task {
            do {
                let count = try await API.shared.wsRestoreDoc(doc.id)
                Events.workspaceChanged()
                toast(count > 1 ? "已恢复（含 \(count - 1) 个子页面）" : "已恢复")
                dismiss()
                onRestored(doc)
            } catch {
                guard !isCancellation(error) else { return }
                self.error = errorMessage(error)
            }
        }
    }
}
