import SwiftUI

/// GitLab 的共用部分：菜单、状态文字、Markdown、相关问题、提交列表。
@MainActor
enum GitLab {
    /// 当前 GitLab 用户（用于判断哪些评论可以编辑、删除）。
    private static var meTask: Task<GlUser?, Never>?

    static func me() async -> GlUser? {
        if let meTask { return await meTask.value }
        let task = Task { try? await API.shared.glMe() }
        meTask = task
        let me = await task.value
        if me == nil { meTask = nil }
        return me
    }

    /// 合并请求的项目路径（从完整引用 group/project!12 中取）。
    static func projectPath(_ mr: MergeRequest) -> String { mr.reference.components(separatedBy: "!")[0] }

    /// 项目网页地址：去掉合并请求地址的 /-/merge_requests/12 部分。
    static func projectUrl(_ mr: MergeRequest) -> String { mr.webUrl.replacing(/\/-\/merge_requests\/\d+$/, with: "") }

    /// 正文中的 Jira 问题号（形如 ABC-123），按出现顺序去重。
    static func issueKeys(in text: String) -> [String] {
        var out: [String] = []
        for m in text.matches(of: /\b[A-Z][A-Z0-9_]+-\d+\b/) where !out.contains(String(m.0)) { out.append(String(m.0)) }
        return out
    }

    /// 常见的表情短码；其余短码原样显示。
    private static let emoji: [String: String] = [
        "+1": "👍", "-1": "👎", "thumbsup": "👍", "thumbsdown": "👎", "smile": "😄", "laughing": "😆", "joy": "😂", "tada": "🎉", "rocket": "🚀",
        "heart": "❤️", "fire": "🔥", "eyes": "👀", "thinking": "🤔", "pray": "🙏", "clap": "👏", "ok_hand": "👌", "muscle": "💪", "star": "⭐",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "ballot_box_with_check": "☑️", "x": "❌", "negative_squared_cross_mark": "❎",
        "warning": "⚠️", "exclamation": "❗", "question": "❓", "no_entry": "⛔", "no_entry_sign": "🚫", "stop_sign": "🛑",
        "bug": "🐛", "mag": "🔍", "mag_right": "🔎", "memo": "📝", "pencil": "📝", "pencil2": "✏️", "bulb": "💡", "wrench": "🔧", "hammer": "🔨",
        "construction": "🚧", "lock": "🔒", "unlock": "🔓", "key": "🔑", "sparkles": "✨", "zap": "⚡", "boom": "💥", "art": "🎨", "recycle": "♻️",
        "package": "📦", "link": "🔗", "books": "📚", "book": "📖", "clipboard": "📋", "chart_with_upwards_trend": "📈", "hourglass": "⌛",
        "red_circle": "🔴", "large_orange_diamond": "🔶", "large_blue_circle": "🔵", "green_heart": "💚", "information_source": "ℹ️",
        "arrow_right": "➡️", "point_right": "👉", "see_no_evil": "🙈", "rotating_light": "🚨", "wastebasket": "🗑️", "truck": "🚚",
    ]

    /// GitLab 的 Markdown（MR 描述、评论）→ 文档模型。项目内的相对地址（`/uploads/…`）补全为项目下的地址；
    /// 换行即换行（与 GitLab 一致）；代码中的内容不做表情替换。
    static func markdown(_ body: String, projectUrl: String) async -> RichDoc {
        var out: [String] = []
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                out.append(line)
                continue
            }
            if inFence { out.append(line); continue }
            var l = line.replacing(/:([a-z0-9_+-]+):/) { m in emoji[String(m.1)] ?? String(m.0) }
            l = l.replacingOccurrences(of: "](/uploads/", with: "](\(projectUrl)/uploads/")
            // 换行即换行：行尾加两个空格作为硬换行
            out.append(l.isEmpty ? l : l + "  ")
        }
        return (try? await Rich.fromMarkdown(out.joined(separator: "\n"))) ?? RichDoc(blocks: [.para([.text(body, [], link: nil, color: nil)])])
    }

    static let stateLabels = IssueCodeSection.stateLabels
    static let pipelineLabels = IssueCodeSection.pipelineLabels

    private static func copy(_ label: String, _ text: String, icon: String? = nil) -> MenuSpec {
        .action(label, icon: icon) {
            Pasteboard.copy(text)
            toast("已复制")
        }
    }

    /// 合并请求；`onOpen` 不提供时（正在查看）不显示“打开”。
    static func mrMenu(_ mr: MergeRequest, onOpen: (@MainActor () -> Void)? = nil) -> [MenuSpec] {
        let keys = AppModel.shared.isReady(.jira) ? issueKeys(in: "\(mr.title) \(mr.sourceBranch)") : []
        var specs: [MenuSpec] = []
        if let onOpen { specs.append(.action("打开", icon: "arrow.triangle.pull", onOpen)) }
        specs.append(.action("打开项目", icon: "folder") { AppModel.shared.navigate(NavTarget(.gitlab, projectId: mr.projectId)) })
        for key in keys { specs.append(.action("打开 \(key)", icon: "smallcircle.filled.circle") { AppModel.shared.navigate(NavTarget(.jira, issueKey: key)) }) }
        specs += [
            .separator,
            copy("复制链接", mr.webUrl, icon: "link"),
            copy("复制引用", mr.reference),
            copy("复制标题", mr.title, icon: "doc.on.doc"),
            copy("复制源分支名", mr.sourceBranch, icon: "arrow.triangle.branch"),
            copy("复制为 Markdown 链接", "[\(projectPath(mr).components(separatedBy: "/").last ?? "")!\(mr.iid) \(mr.title)](\(mr.webUrl))"),
            .separator,
            .share(url: mr.webUrl, title: mr.title),
            .action("在浏览器中打开", icon: "safari") { Links.openInBrowser(mr.webUrl) },
        ]
        return specs
    }

    /// 代码浏览中的文件或目录。
    static func treeEntryMenu(_ entry: TreeEntry, projectUrl: String, ref: String, onOpen: @escaping @MainActor () -> Void) -> [MenuSpec] {
        let encodedPath = entry.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let url = "\(projectUrl)/-/\(entry.kind == "tree" ? "tree" : "blob")/\(ref.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ref)/\(encodedPath)"
        var specs: [MenuSpec] = []
        if entry.kind != "commit" { specs.append(.action("打开", icon: "doc.text", onOpen)) }
        specs += [.separator, copy("复制路径", entry.path, icon: "doc.on.doc"), copy("复制名称", entry.name), copy("复制链接", url, icon: "link"), .separator, .action("在浏览器中打开", icon: "safari") { Links.openInBrowser(url) }]
        return specs
    }

    static func commitMenu(_ c: Commit, onOpen: @escaping @MainActor () -> Void) -> [MenuSpec] {
        var specs: [MenuSpec] = [.action("查看提交", icon: "smallcircle.filled.circle", onOpen), .separator, copy("复制提交 SHA", c.id, icon: "doc.on.doc"), copy("复制短 SHA", c.shortId), copy("复制提交信息", c.message.isEmpty ? c.title : c.message)]
        if let url = c.webUrl {
            specs.append(copy("复制链接", url, icon: "link"))
            specs.append(.separator)
            specs.append(.action("在浏览器中打开", icon: "safari") { Links.openInBrowser(url) })
        }
        return specs
    }

    static func branchMenu(_ b: Branch, projectUrl: String, onOpen: @escaping @MainActor () -> Void, onCreateMr: (@MainActor () -> Void)?) -> [MenuSpec] {
        let url = "\(projectUrl)/-/tree/\(b.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b.name)"
        var specs: [MenuSpec] = [.action("浏览代码", icon: "doc.text", onOpen)]
        if let onCreateMr { specs.append(.action("发起合并请求…", icon: "arrow.triangle.pull", onCreateMr)) }
        specs += [.separator, copy("复制分支名", b.name, icon: "arrow.triangle.branch"), copy("复制最新提交 SHA", b.commit.id), copy("复制链接", url, icon: "link"), .separator, .action("在浏览器中打开", icon: "safari") { Links.openInBrowser(url) }]
        return specs
    }

    /// 从自己最近的标题中学习团队的标题格式：问题号前的固定前缀和多数标题共有的结尾。没有明显规律时都为空。
    static func learnTitlePattern(_ titles: [String]) -> (prefix: String, suffix: String) {
        var prefixes: [String: Int] = [:]
        for t in titles {
            guard let key = issueKeys(in: t).first, let r = t.range(of: key) else { continue }
            let prefix = String(t[..<r.lowerBound])
            if prefix.count <= 15 { prefixes[prefix, default: 0] += 1 }
        }
        let prefix = prefixes.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.first?.key ?? ""
        // 结尾：空白之后的一段文字，至少 3 个、且不少于四成的标题以它结尾
        let need = max(3, Int((Double(titles.count) * 0.4).rounded(.up)))
        var suffix = ""
        for t in titles {
            let chars = Array(t)
            for i in 1..<max(chars.count, 1) {
                guard chars[i - 1].isWhitespace, !chars[i].isWhitespace else { continue }
                let tail = String(chars[i...]).trimmingCharacters(in: .whitespaces)
                if tail.count < 2 || tail.count > 24 || tail.count <= suffix.trimmingCharacters(in: .whitespaces).count { continue }
                let count = titles.filter { x in
                    let trimmed = x.replacing(/\s+$/, with: "")
                    guard trimmed.hasSuffix(tail), trimmed.count > tail.count else { return false }
                    return Array(trimmed)[trimmed.count - tail.count - 1].isWhitespace
                }.count
                if count >= need {
                    // 保留原标题中结尾前的空白
                    let head = String(chars[..<i])
                    let gap = head.firstMatch(of: /\s+$/).map { String($0.0) } ?? " "
                    suffix = gap + tail
                }
            }
        }
        return (prefix, suffix)
    }
}

/// 合并请求的状态。
struct MrStatePill: View {
    var state: String

    var body: some View {
        StatusPill(status: JiraStatus(name: GitLab.stateLabels[state] ?? state, category: state == "merged" ? "done" : state == "opened" ? "indeterminate" : "new"))
    }
}

/// 提到这个分支、提交或合并请求的 Jira 问题：标题等中的问题键，以及问题中链接了它的。没有时不显示。
struct RelatedIssuesSection: View {
    var target: CodeTarget
    @State private var issues: [IssueHit]?
    @State private var menu = IssueMenu()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0)
            if let issues, !issues.isEmpty {
                BlockSection(title: "相关问题", icon: "checkmark.seal", count: "\(issues.count)") {
                    VStack(spacing: 6) {
                        ForEach(issues) { i in
                            HStack(spacing: 6) {
                                SysImage(service: .jira, src: i.issueType.iconUrl, size: 16)
                                Text(i.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                                Text(i.summary).lineLimit(1).help(i.snippet?.text ?? i.summary)
                                Spacer()
                                Text(i.via == "key" ? "提到问题键" : i.snippet?.author.map { "\($0) 的评论中链接了它" } ?? "问题中链接了它").font(.caption).foregroundStyle(.secondary)
                                StatusPill(status: i.status)
                            }
                            .rowTap { AppModel.shared.navigate(NavTarget(.jira, issueKey: i.key)) }
                            .contextMenu(specs: { menu.specs(.summary(i.summaryValue)) })
                        }
                    }
                }
            }
        }
        .issueMenuDialogs(menu)
        .task(id: target) {
            guard AppModel.shared.isReady(.jira) else { return }
            issues = nil
            issues = (try? await API.shared.codeRelatedIssues(target)) ?? []
        }
    }
}

struct CommitListView: View {
    var commits: [Commit]
    var onOpen: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(commits) { c in
                HStack(spacing: 10) {
                    Avatar(name: c.authorName, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).lineLimit(1)
                        Text("\(c.authorName) · \(Fmt.time(c.authoredDate))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(c.shortId).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .padding(6)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(c.id) }
                .contextMenu(specs: { GitLab.commitMenu(c) { onOpen(c.id) } })
            }
        }
    }
}
