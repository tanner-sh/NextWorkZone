import Foundation
import Testing
import NWZWiki
@testable import NWZServices

@Suite struct WeeklyDraftTests {
    @Test func guessesCommitOnlyWhenClear() {
        let issues = ["新增线上团购订单类型", "库存月报合并冻结库存与可用库存", "用户导出报错"].map { WeeklyIssueWork(summary: $0) }
        #expect(WeeklyComposition.guessIssue("新增线上团购订单类型并设置订单方向", issues: issues) == 0)
        #expect(WeeklyComposition.guessIssue("修复库存月报冻结库存解冻后数量计算", issues: issues) == 1)
        #expect(WeeklyComposition.guessIssue("忽略编辑器配置目录", issues: issues) == nil)
        #expect(WeeklyComposition.guessIssue("定时任务执行器", issues: [WeeklyIssueWork(summary: "定时任务执行器报错"), WeeklyIssueWork(summary: "定时任务执行器并发执行")]) == nil)
    }
    @Test func learnsHistoryMergesEvidenceAndKeepsCarryOver() {
        let history = [WeekEntry(sectionTitle: "上周", content: [.init(text: "界面"), .init(level: 1, text: "修复用户导出报错 — 50%"), .init(level: 1, text: "完善账户设置流程 — 20%")])]
        let issue = WeeklyIssueWork(key: "PROJ-123", summary: "修复用户导出报错", project: "项目", progress: "100%", evidence: ["创建"])
        let code = WeeklyCodeWork(kind: "push", keys: ["PROJ-123"], project: "代码", evidence: "推送 2 个提交到 main", standalone: "导出修复")
        let result = WeeklyComposition.compose(from: "2026-10-19", to: "2026-10-25", weeks: history, issues: [issue], code: [code, code], todos: [("核对导出结果", "PROJ-123"), ("整理文档", nil)], daily: ["复盘"], worklogs: [], wiki: [], notes: ["某来源暂时不可用"])
        #expect(result.separator == " — ")
        #expect(result.groups.map(\.source) == ["jira", "todo", "daily"])
        #expect(result.groups[0].title == "界面")
        #expect(result.groups[0].items[0].evidence == ["创建", "推送 2 个提交到 main", "完成待办：核对导出结果"])
        #expect(result.groups[0].items[0].lastWeek == "50%")
        #expect(result.carryOver.map(\.thisWeek) == ["修复用户导出报错 — 100%", nil])
        #expect(result.notes.count == 1)
    }
    @Test func durationRoundsUpToMinutes() {
        #expect(WeeklyComposition.duration(0) == "0m")
        #expect(WeeklyComposition.duration(1) == "1m")
        #expect(WeeklyComposition.duration(3600) == "1h")
        #expect(WeeklyComposition.duration(3661) == "1h 2m")
    }
}
