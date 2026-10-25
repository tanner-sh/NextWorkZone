import Testing
import NWZWiki

@Suite struct WeeklyReportTests {
    func outline(_ lines: [String]) -> [OutlineItem] {
        lines.map { line in OutlineItem(level: line.prefix(while: { $0 == " " }).count / 2, text: String(line.drop(while: { $0 == " " }))) }
    }
    @Test func progress() {
        for (text, body, progress) in [("修复导入 --100%", "修复导入", "100%"), ("导出功能开发 ------90%", "导出功能开发", "90%"), ("登录问题排查 – 100%", "登录问题排查", "100%"), ("报表字段调整 --转开发解决", "报表字段调整", "转开发解决")] {
            let p = WeeklyReport.splitProgress(text)
            #expect(p.0 == body && p.1 == progress)
        }
        #expect(WeeklyReport.splitProgress("A-1 拆分 x-y").1 == nil)
        #expect(WeeklyReport.splitProgress("没有进度").1 == nil)
        #expect(WeeklyReport.isFinished("100%") && WeeklyReport.isFinished("已完成") && !WeeklyReport.isFinished("80%") && !WeeklyReport.isFinished(nil))
    }
    @Test func similarity() {
        #expect(WeeklyReport.similarity("订单金额计算修复", "【客户】订单金额计算修复（第二轮）") == 1)
        #expect(WeeklyReport.similarity("订单报表增加三个字段", "订单报表增加两个字段") > 0.6)
        #expect(WeeklyReport.similarity("订单报表增加三个字段", "导入数据文件报错") < 0.2)
    }
    @Test func learnsPastWeeks() {
        let last = outline(["产品甲", "  导出功能开发 ------90%", "客户乙", "  订单金额计算修复 --80%", "  已完成的事 --100%"])
        let older = outline(["产品甲", "  别的事 --100%", "客户丙", "  另一件事 --100%"])
        let items = WeeklyReport.pastItems(last), groups = WeeklyReport.pastGroups([last, older])
        #expect(items[1] == PastItem(group: "客户乙", text: "订单金额计算修复", progress: "80%"))
        #expect(groups == ["产品甲", "客户乙", "客户丙"])
        #expect(WeeklyReport.pastSeparator([last, older]) == " --")
        #expect(WeeklyReport.guessGroup("客户乙订单金额计算修复", past: items, groups: groups) == "客户乙")
        #expect(WeeklyReport.guessGroup("客户丙：新需求", past: items, groups: groups) == "客户丙")
        #expect(WeeklyReport.guessGroup("完全无关", past: items, groups: groups) == nil)
        #expect(WeeklyReport.pastItems(outline(["一件事 --100%"])).first?.group == "")
    }
}
