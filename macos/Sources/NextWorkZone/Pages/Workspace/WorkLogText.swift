import Foundation

/// 工作记录的整理：时间线、日报、写入日记，与 src/pages/workspace/WorkLog.tsx 相同。
enum WorkLogText {
    private static let section = "## 工作记录"

    private static let kindText = [
        "create": "创建", "transition": "流转", "comment": "评论", "assign": "分配", "update": "修改", "push": "推送", "mr_open": "发起合并请求",
        "mr_merge": "合并", "mr_approve": "批准", "mr_close": "关闭合并请求", "edit": "修改页面", "done": "完成待办",
    ]

    static func clock(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    static func icon(_ system: String) -> String {
        switch system {
        case "jira": "smallcircle.filled.circle"
        case "gitlab": "arrow.triangle.branch"
        case "wiki": "text.book.closed"
        default: "checkmark.square"
        }
    }

    /// 一件事的一行说明（时间线中显示）。
    static func eventText(_ e: WorkEvent) -> String {
        let action = e.system == "wiki" && e.kind == "create" ? "新建页面" : e.system == "wiki" && e.kind == "comment" ? "评论页面" : kindText[e.kind] ?? e.kind
        let subject = e.system == "jira" ? "\(e.key ?? "") \(e.title)" : e.system == "gitlab" && e.key != nil ? "\(e.title) \(e.key!)" : e.title
        return "\(action) · \(subject)\(e.detail.isEmpty ? "" : "：\(e.detail)")"
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// 同一个问题上的几件事合成一句。
    static func describeJira(_ list: [WorkEvent]) -> String {
        var parts: [String] = []
        for e in list {
            if e.kind == "transition" { parts.append(e.detail) }
            else if e.kind == "create" { parts.append("新建") }
            else if e.kind == "assign" { parts.append(e.detail) }
        }
        let comments = list.filter { $0.kind == "comment" }
        if comments.count == 1 { parts.append("评论：\(comments[0].detail)") } else if comments.count > 1 { parts.append("评论 \(comments.count) 条") }
        let fields = unique(list.filter { $0.kind == "update" }.flatMap { $0.detail.replacing(/^修改了/, with: "").components(separatedBy: "、") })
        if !fields.isEmpty { parts.append("修改了\(fields.joined(separator: "、"))") }
        let head = "\(list[0].key ?? "") \(list[0].title)"
        return parts.isEmpty ? head : "\(head)：\(unique(parts).joined(separator: "；"))"
    }

    /// 同一个项目上的推送、合并请求、评论合成一句。
    static func describeCode(_ list: [WorkEvent]) -> String {
        var parts: [String] = []
        let pushes = list.filter { $0.kind == "push" }
        if !pushes.isEmpty {
            let commits = unique(pushes.map { $0.detail.replacing(/（[^（）]*）$/, with: "") }).filter { !$0.isEmpty }
            parts.append("提交：\(commits.prefix(5).joined(separator: "；"))\(commits.count > 5 ? " 等 \(commits.count) 项" : "")")
        }
        for kind in ["mr_open", "mr_merge", "mr_approve", "mr_close"] {
            let mrs = unique(list.filter { $0.kind == kind }.map { "\($0.key ?? "") \($0.detail)".trimmingCharacters(in: .whitespaces) })
            if !mrs.isEmpty { parts.append("\(kindText[kind]!) \(mrs.joined(separator: "、"))") }
        }
        let comments = list.filter { $0.kind == "comment" }.count
        if comments > 0 { parts.append("评论 \(comments) 条") }
        return "\(list[0].title)：\(parts.joined(separator: "；"))"
    }

    static func describeWiki(_ list: [WorkEvent]) -> String {
        let kinds = Set(list.map(\.kind))
        let action = [kinds.contains("create") ? "新建" : kinds.contains("edit") ? "更新" : "", kinds.contains("comment") ? "评论" : ""].filter { !$0.isEmpty }.joined(separator: "并")
        return "\(action)页面：\(list[0].title)"
    }

    private static func grouped(_ list: [WorkEvent], key: (WorkEvent) -> String) -> [[WorkEvent]] {
        var order: [String] = []
        var map: [String: [WorkEvent]] = [:]
        for e in list {
            let k = key(e)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(e)
        }
        return order.map { map[$0]! }
    }

    /// 按对象整理成日报：Jira 问题按问题、代码按项目、Wiki 按页面合并，完成的待办列一组。
    static func summarize(_ log: WorkLog) -> [(title: String, items: [String])] {
        var groups: [(String, [String])] = []
        let jira = grouped(log.events.filter { $0.system == "jira" }) { $0.key ?? $0.title }.map(describeJira)
        if !jira.isEmpty { groups.append(("Jira 问题", jira)) }
        let code = grouped(log.events.filter { $0.system == "gitlab" }) { $0.title }.map(describeCode)
        if !code.isEmpty { groups.append(("代码", code)) }
        let wiki = grouped(log.events.filter { $0.system == "wiki" }) { $0.key ?? $0.title }.map(describeWiki)
        if !wiki.isEmpty { groups.append(("Wiki", wiki)) }
        let todos = unique(log.events.filter { $0.system == "todo" }.map(\.title)).filter { !$0.isEmpty }
        if !todos.isEmpty { groups.append(("完成的待办", todos)) }
        return groups
    }

    /// 日报正文（纯文本，可以直接粘贴到聊天工具或 Wiki）。
    static func report(_ log: WorkLog) -> String {
        let groups = summarize(log)
        var lines = ["\(log.day) \(Fmt.weekday(log.day)) 工作日报", ""]
        let numerals = Array("一二三四五六七八").map(String.init)
        for (i, g) in groups.enumerated() {
            lines.append("\(i < numerals.count ? numerals[i] : String(i + 1))、\(g.title)")
            for (n, item) in g.items.enumerated() { lines.append("\(n + 1). \(item)") }
            lines.append("")
        }
        if groups.isEmpty { lines.append("（没有找到当天的工作记录）") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把日记中的“工作记录”小节替换为最新内容（没有时追加到末尾）。
    static func withWorkSection(_ content: String, _ log: WorkLog) -> String {
        let body = summarize(log).map { (["**\($0.title)**"] + $0.items.map { "- \($0)" }).joined(separator: "\n") }.joined(separator: "\n\n")
        let sectionText = "\(section)\n\n\(body.isEmpty ? "（没有找到当天的工作记录）" : body)\n"
        guard let start = content.range(of: section) else {
            let trimmed = content.replacing(/\s+$/, with: "")
            return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sectionText : "\(trimmed)\n\n\(sectionText)"
        }
        let rest = content[start.upperBound...]
        let next = rest.firstMatch(of: try! Regex("\\n#{1,2} "))
        return String(content[..<start.lowerBound]) + sectionText + (next.map { String(rest[$0.range.lowerBound...]) } ?? "")
    }

    /// 连续几分钟内对同一个对象做的事合成时间线中的一行。
    static func timeline(_ events: [WorkEvent]) -> [(at: Int64, first: WorkEvent, text: String)] {
        var rows: [[WorkEvent]] = []
        for e in events {
            if let prev = rows.last?.last, prev.system == e.system, prev.title == e.title, prev.key == e.key, e.at - prev.at <= 5 * 60_000, ["jira", "gitlab", "wiki"].contains(e.system) {
                rows[rows.count - 1].append(e)
            } else {
                rows.append([e])
            }
        }
        return rows.map { list in
            let first = list[0]
            let text = list.count == 1 ? eventText(first) : first.system == "jira" ? describeJira(list) : first.system == "gitlab" ? describeCode(list) : describeWiki(list)
            return (first.at, first, text)
        }
    }

    static func target(_ e: WorkEvent) -> NavTarget? {
        if (e.system == "jira" || e.system == "todo"), let key = e.key { return NavTarget(.jira, issueKey: key) }
        if e.system == "wiki", let key = e.key { return NavTarget(.wiki, wikiPage: key) }
        if e.system == "gitlab", let pid = e.projectId {
            if let key = e.key, key.hasPrefix("!"), let iid = Int(key.dropFirst()) { return NavTarget(.gitlab, projectId: pid, mrIid: iid) }
            return NavTarget(.gitlab, projectId: pid)
        }
        return nil
    }
}
