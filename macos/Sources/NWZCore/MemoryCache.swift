import Foundation

/// 有数量和大小上限的进程内缓存。过期项仍可作为旧内容展示，由调用方决定何时刷新。
public struct MemoryCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var expiresAt: Date
    }

    private let maxCount: Int
    private let maxCost: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var totalCost = 0

    public init(maxCount: Int, maxCost: Int = .max) {
        self.maxCount = max(0, maxCount)
        self.maxCost = max(0, maxCost)
    }

    public mutating func get(_ key: Key, now: Date = Date()) -> (value: Value, fresh: Bool)? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return (entry.value, entry.expiresAt > now)
    }

    public mutating func put(_ value: Value, for key: Key, cost: Int = 1, ttl: TimeInterval, now: Date = Date()) {
        remove(key)
        let cost = max(0, cost)
        guard maxCount > 0, cost <= maxCost else { return }
        while !order.isEmpty && (entries.count >= maxCount || totalCost > maxCost - cost) {
            remove(order[0])
        }
        entries[key] = Entry(value: value, cost: cost, expiresAt: now.addingTimeInterval(ttl))
        order.append(key)
        totalCost += cost
    }

    public mutating func remove(_ key: Key) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        order.removeAll { $0 == key }
    }

    /// 更新内容但不延长其有效期。
    public mutating func update(_ key: Key, _ change: (inout Value) -> Void) {
        guard var entry = entries[key] else { return }
        change(&entry.value)
        entries[key] = entry
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }
}
