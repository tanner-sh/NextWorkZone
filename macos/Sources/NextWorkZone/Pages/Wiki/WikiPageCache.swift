import Foundation
import NWZCore

/// 最近阅读的页面只保存在内存中；超时后仍可先显示，再向服务器确认。
@MainActor
final class WikiPageCache {
    struct Entry {
        var page: WikiPageDetail
        var doc: RichDoc
        var sections: [(doc: RichDoc, headingStart: Int)]
        var headings: [(level: Int, text: String, index: Int)]
        var issueKeys: [String]
    }

    static let shared = WikiPageCache()
    private let maxCost = 32 * 1_024 * 1_024
    private var pages = MemoryCache<String, Entry>(maxCount: 20, maxCost: 32 * 1_024 * 1_024)
    private var metadata = MemoryCache<String, WikiPageMeta>(maxCount: 20)

    func get(_ id: String) -> (value: Entry, fresh: Bool)? { pages.get(id) }

    func put(_ entry: Entry) {
        // 文档模型和分段引用共享存储；按 HTML 的四倍估算，超大页面不进入缓存。
        let bytes = entry.page.html.utf8.count
        let cost = bytes > maxCost / 4 ? maxCost + 1 : max(1, bytes * 4)
        pages.put(entry, for: entry.page.id, cost: cost, ttl: 15)
    }

    func meta(_ id: String) -> (value: WikiPageMeta, fresh: Bool)? { metadata.get(id) }
    func putMeta(_ value: WikiPageMeta, id: String) { metadata.put(value, for: id, ttl: 15) }

    func remove(_ id: String) { pages.remove(id); metadata.remove(id) }
    func clear() { pages.removeAll(); metadata.removeAll() }
}
