import Foundation
import NWZCore
import NWZServices

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
            只读查询当前账号与版本；默认读取 NextWorkZone-dev 的配置和凭据。
            """
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
}
