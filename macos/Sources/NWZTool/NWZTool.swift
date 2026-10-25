import Foundation
import NWZCore
import NWZServices
import NWZJira

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

}
