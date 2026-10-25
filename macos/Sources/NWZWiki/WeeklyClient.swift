import Foundation
import NWZCore

extension WikiClient {
    public func weeklyLoad(page id: String, name: String, section: String? = nil, today: Date = Date()) async throws -> WeeklyView {
        let page = try await page(id), overview = try Weekly.overview(page.storage, today: today)
        let title = section ?? overview.defaultSection
        let entry = try title.map { try Weekly.entry(page.storage, section: $0, name: name) }
        return WeeklyView(pageId: page.id, pageTitle: page.title, pageUrl: pageURL(page.id), version: page.version, modifiedBy: page.modifiedBy, modifiedAt: page.modifiedAt, personName: name, sections: overview.sections, currentWeekTitle: overview.currentWeekTitle, currentWeekExists: overview.currentWeekExists, entry: entry)
    }
    public func weeklyHistory(page id: String, name: String, section: String, today: Date = Date(), count: Int = 4) async throws -> [WeekEntry] {
        let page = try await page(id), overview = try Weekly.overview(page.storage, today: today)
        guard let i = overview.sections.firstIndex(where: { $0.title == section }) else { return [] }
        return overview.sections.dropFirst(i + 1).prefix(max(0, count)).compactMap { try? Weekly.entry(page.storage, section: $0.title, name: name) }.filter(\.rowFound)
    }
    public func weeklySave(page id: String, name: String, section: String, expected: (String, String), content: [OutlineItem], risk: [OutlineItem]) async throws -> SaveResult {
        for _ in 0..<3 {
            let page = try await page(id)
            let edit = try Weekly.applyEntry(page.storage, section: section, name: name, expected: expected, content: content, risk: risk)
            if !edit.changed { return SaveResult(changed: false, version: page.version) }
            do {
                let version = try await updatePage(page, storage: edit.storage, message: "\(name) 更新周报（NextWorkZone）")
                return SaveResult(changed: true, version: version)
            } catch NWZError.conflict { continue }
        }
        throw NWZError.conflict("页面正被频繁修改，请稍后重试")
    }
    public func weeklyCreateWeek(page id: String, today: Date = Date()) async throws -> String {
        for _ in 0..<3 {
            let page = try await page(id), title = try Weekly.overview(page.storage, today: today).currentWeekTitle
            let storage = try Weekly.insertWeek(page.storage, title: title)
            do { _ = try await updatePage(page, storage: storage, message: "新建 \(title) 周报小节（NextWorkZone）"); return title }
            catch NWZError.conflict { continue }
        }
        throw NWZError.conflict("页面正被频繁修改，请稍后重试")
    }
}
