import Foundation
import NWZCore
import Testing

struct MemoryCacheTests {
    @Test func expiredContentCanBeShownWhileRefreshing() {
        var cache = MemoryCache<String, String>(maxCount: 2)
        let now = Date(timeIntervalSince1970: 1_000)
        cache.put("页面", for: "a", ttl: 15, now: now)
        #expect(cache.get("a", now: now.addingTimeInterval(14))?.fresh == true)
        let expired = cache.get("a", now: now.addingTimeInterval(15))
        #expect(expired?.value == "页面" && expired?.fresh == false)
    }

    @Test func leastRecentlyUsedAndOversizedItemsAreEvicted() {
        var cache = MemoryCache<String, String>(maxCount: 2, maxCost: 6)
        cache.put("A", for: "a", cost: 3, ttl: 15)
        cache.put("B", for: "b", cost: 3, ttl: 15)
        #expect(cache.get("a")?.value == "A")
        cache.put("C", for: "c", cost: 3, ttl: 15)
        #expect(cache.get("b")?.value == nil)
        #expect(cache.get("a")?.value == "A" && cache.get("c")?.value == "C")
        cache.put("too large", for: "a", cost: 7, ttl: 15)
        #expect(cache.get("a")?.value == nil && cache.get("c")?.value == "C")
        cache.removeAll()
        #expect(cache.get("c")?.value == nil)
    }
}
