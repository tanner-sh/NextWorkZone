import Foundation
import Testing
import NWZCore
@testable import NWZJira
@testable import NWZWiki

/// 本机问题库、Wiki 库对单个关键词的快速查法，结果必须与完整查询一模一样（包括顺序）。
struct SearchShortcutTests {
    /// 固定种子的伪随机数，保证每次生成的数据相同。
    struct Random {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
    }

    static let words = ["导出", "报表", "接口", "凭证", "单据", "升级", "数据", "权限", "日志", "缓存", "export", "excel", "导入文件", "数据库升级"]

    func text(_ random: inout Random, _ count: Int) -> String {
        (0..<count).map { _ in random.next(4) == 0 ? Self.words[random.next(Self.words.count)] : "其他内容" }.joined(separator: " ")
    }

    @Test func jiraShortcutMatchesFullQuery() async throws {
        var random = Random(state: 7)
        let index = try IssueIndex()
        let issues = (0..<300).map { i -> IndexedIssue in
            // 更新时间各不相同，排序没有并列
            let updated = String(format: "2026-%02d-%02dT%02d:%02d:00.000+0800", 1 + i % 9, 1 + i % 27, i % 24, i % 60)
            let raw: JSONValue = ["key": .string("ABC-\(i)"), "fields": ["summary": .string(text(&random, 2)), "description": .string(text(&random, 6)), "status": ["name": "处理中", "statusCategory": ["key": "indeterminate"]], "project": ["name": "测试项目"], "resolution": i % 3 == 0 ? ["name": "已修复"] : .null, "updated": .string(updated), "created": "2026-01-01T10:00:00.000+0800", "comment": ["comments": .array((0..<random.next(3)).map { _ in ["author": ["name": "zs", "displayName": "张三"], "created": "2026-01-02T10:00:00.000+0800", "body": .string(text(&random, 3))] })]]]
            return IndexedIssue(raw: JSONDocument(value: raw))
        }
        try await index.upsert(issues)
        for word in Self.words {
            for limit in [3, 8, 50] {
                for state in ["all", "resolved"] {
                    let query = IndexQuery(text: word, project: "", state: state, mine: false, limit: limit)
                    let fast = try await index.search(query, me: "", shortcut: true).map(\.key)
                    let full = try await index.search(query, me: "", shortcut: false).map(\.key)
                    #expect(fast == full, "\(word) limit=\(limit) state=\(state)")
                }
            }
        }
    }

    @Test func wikiShortcutMatchesFullQuery() async throws {
        var random = Random(state: 11)
        let index = try WikiIndex()
        let pages = (0..<300).map { i in
            let modified = String(format: "2026-%02d-%02dT%02d:%02d:00.000+08:00", 1 + i % 9, 1 + i % 27, i % 24, i % 60)
            return IndexedWikiPage(id: String(1000 + i), kind: "page", spaceKey: i % 2 == 0 ? "A" : "B", spaceName: "空间", title: text(&random, 2), ancestors: [], author: "me", authorName: "我", modified: modified, version: 1, storage: "<p>" + text(&random, 8) + "</p>")
        }
        try await index.upsert(pages)
        for word in Self.words {
            for limit in [3, 8, 50] {
                for space: String? in [nil, "A"] {
                    let query = WikiQuery(text: word, space: space, limit: limit)
                    let fast = try await index.search(query, shortcut: true).map(\.id)
                    let full = try await index.search(query, shortcut: false).map(\.id)
                    #expect(fast == full, "\(word) limit=\(limit) space=\(space ?? "")")
                }
            }
        }
    }
}
