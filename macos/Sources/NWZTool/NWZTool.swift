import Foundation
import NWZCore
import NWZServices
import NWZJira
import NWZWiki
import NWZRich

@main
struct NWZTool {
    static func main() async {
        do { exit(try await run(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws -> Int32 {
        let usage = """
            用法：NWZTool ping [jira|wiki|gitlab|all] [--data-dir <目录>]
            NWZTool jira-search <JQL>、jira-issue <问题键>、jira-fields；支持 --data-dir。
            只读查询当前账号与版本；默认读取 NextWorkZone-dev 的配置和凭据。
            """
        if arguments.first?.hasPrefix("jira-") == true { return try await jira(arguments) }
        if arguments.first?.hasPrefix("wiki-") == true || arguments.first == "weekly-load" { return try await wiki(arguments) }
        if arguments == ["--help"] || arguments == ["-h"] { print(usage); return 0 }
        guard arguments.first == "ping" else { throw NWZError.other(usage) }
        var paths = AppPaths(development: true)
        var services = Service.allCases
        var index = 1
        var selectedService = false
        var selectedDirectory = false
        while index < arguments.count {
            let value = arguments[index]
            if value == "--data-dir", !selectedDirectory {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"), !arguments[index + 1].isEmpty else { throw NWZError.other("--data-dir 后需要指定目录") }
                paths = AppPaths(dataDirectory: URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath, isDirectory: true))
                selectedDirectory = true
                index += 2
            } else if !selectedService, ["jira", "wiki", "confluence", "gitlab", "all"].contains(value) {
                services = value == "all" ? Service.allCases : [value == "wiki" ? .confluence : Service(rawValue: value)!]
                selectedService = true
                index += 1
            } else { throw NWZError.other(usage) }
        }
        let settings = try SettingsService(paths: paths, configuration: ConfigurationStore(path: paths.config))
        var failed = false
        for service in services {
            do {
                let result = try await settings.testConnection(service)
                let version = result.serverVersion.map { " · v" + $0 } ?? ""
                print("\(service.label)：\(result.displayName)（\(result.username)）\(version)")
            } catch {
                failed = true
                FileHandle.standardError.write(Data("\(service.label)：\(error.localizedDescription)\n".utf8))
            }
        }
        return failed ? 1 : 0
    }
    private static func jira(_ arguments: [String]) async throws -> Int32 {
        var args = arguments
        var paths = AppPaths(development: true)
        if let index = args.firstIndex(of: "--data-dir") {
            guard index + 1 < args.count else { throw NWZError.other("--data-dir 后需要指定目录") }
            paths = AppPaths(dataDirectory: URL(fileURLWithPath: NSString(string: args[index + 1]).expandingTildeInPath))
            args.removeSubrange(index...(index + 1))
        }
        let settings = try SettingsService(paths: paths, configuration: ConfigurationStore(path: paths.config))
        let client = try await JiraClient(rest: settings.restClient(.jira))
        let value = args.count > 1 ? args[1] : ""
        func output<T: Encodable>(_ value: T) throws { FileHandle.standardOutput.write(try JSONEncoder().encode(value)); FileHandle.standardOutput.write(Data([10])) }
        switch args[0] {
        case "jira-search": try await output(client.search(value, maxResults: 3))
        case "jira-issue":
            var issue = try await client.issue(value)
            let me = try await client.myUsername()
            for index in issue.comments.indices { issue.comments[index].markMine(me) }
            try output(issue)
        case "jira-fields": try await output(client.listFields())
        case "jira-edit-fields": try await output(client.editFields(value))
        case "jira-transitions": try await output(client.transitions(value))
        case "jira-history": try await output(client.history(value))
        case "jira-worklogs": try await output(client.worklogs(value))
        case "jira-watchers": try await output(client.watchers(value))
        case "jira-priorities": try await output(client.priorities())
        case "jira-favourite-filters": try await output(client.favouriteFilters())
        default: throw NWZError.other("未知的只读 Jira 命令")
        }
        return 0
    }

    private static func wiki(_ arguments: [String]) async throws -> Int32 {
        guard arguments.count <= 3 else { throw NWZError.other("Wiki 只读命令的参数过多") }
        let paths = AppPaths(development: true)
        let settings = try SettingsService(paths: paths, configuration: ConfigurationStore(path: paths.config))
        let rest = try await settings.restClient(.confluence)
        let client = WikiClient(rest: rest)
        let value = arguments.count > 1 ? arguments[1] : ""
        func output<T: Encodable>(_ value: T) throws { FileHandle.standardOutput.write(try JSONEncoder().encode(value)); FileHandle.standardOutput.write(Data([10])) }
        switch arguments[0] {
        case "wiki-index-sync":
            let index = try WikiIndex(path: paths.cache.appendingPathComponent("wiki-index.sqlite").path)
            let scope = WikiScope(spaces: settings.configuration.snapshot().wikiTools.indexSpaces)
            let changed = try await index.sync(client: client, scope: scope) { progress in
                FileHandle.standardError.write(Data("\(progress.done)/\(progress.total)\n".utf8))
            }
            try output(["changed": changed, "count": await index.stats().count]); return 0
        case "weekly-load":
            let config = settings.configuration.snapshot().weekly
            guard !config.pageId.isEmpty else { throw NWZError.other("请先在设置中填写周报页面地址") }
            let name = try await client.resolvePersonName(config.personName)
            try await output(client.weeklyLoad(page: config.pageId, name: name, section: value.isEmpty ? nil : value)); return 0
        case "wiki-spaces": try await output(client.spaces()); return 0
        case "wiki-page": try await output(client.pageDetail(value)); return 0
        case "wiki-children": try await output(client.children(value)); return 0
        case "wiki-attachments": try await output(client.attachments(value)); return 0
        case "wiki-versions": try await output(client.versions(value)); return 0
        case "wiki-comments": try await output(client.comments(value)); return 0
        case "wiki-page-version": try await output(client.pageVersion(value)); return 0
        case "wiki-search": try await output(client.cqlSearch(WikiQuery(text: value, kind: "page", limit: 25))); return 0
        case "wiki-edit", "wiki-roundtrip": break
        default: throw NWZError.other("未知的只读 Wiki 命令")
        }
        guard !value.isEmpty else { throw NWZError.other("请指定页面 id") }
        let raw = try await rest.json("GET", "/rest/api/content/" + RESTClient.component(arguments[1]), query: [("expand", "body.storage,version,space")])
        let source = raw["body"]["storage"]["value"].text
        let ed = try WikiEdit.toEditable(source)
        let data: Data
        if arguments[0] == "wiki-edit" { data = try JSONEncoder().encode(ed) }
        else {
            let load = RichEdit.load(ed.html)
            let xhtml = RichEdit.xhtml(segments: load.segments, baseline: load.doc, edited: load.doc)
            let restored = try WikiEdit.fromEditable(xhtml, fragments: ed.fragments)
            data = try JSONEncoder().encode(JSONValue.object([
                "identical": .bool(source == restored),
                "normalizedIdentical": .bool(WikiStorage.normalizeEntities(source) == WikiStorage.normalizeEntities(restored)),
                "bytes": .number(Double(source.utf8.count)), "blocks": .number(Double(load.doc.blocks.count)),
                "fragments": .number(Double(ed.fragments.count)),
            ]))
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
        return 0
    }

}
