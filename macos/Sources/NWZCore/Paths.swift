import Foundation

public struct AppPaths: Sendable {
    public let data: URL
    public let cache: URL
    public let home: URL
    public let development: Bool
    public var config: URL { data.appendingPathComponent("config.json") }
    public var credentialsStore: CredentialsStore { development ? .file(data.appendingPathComponent("dev-credentials.json")) : .keychain }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, development: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.development = development
        let name = development ? "NextWorkZone-dev" : "NextWorkZone"
        #if DEBUG
        if let path = environment["NWZ_DATA_DIR"], !path.isEmpty {
            data = URL(fileURLWithPath: path, isDirectory: true)
            cache = data.appendingPathComponent("cache", isDirectory: true)
            return
        }
        #endif
        data = home.appendingPathComponent("Library/Application Support/" + name, isDirectory: true)
        cache = home.appendingPathComponent("Library/Caches/" + name, isDirectory: true)
    }

    public static func current() -> AppPaths {
        #if DEBUG
        let development = true
        #else
        let development = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        #endif
        return AppPaths(development: development)
    }

    public func createDirectories() throws {
        for directory in [data, cache] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public func syncRoot(in directory: URL) -> URL { directory.appendingPathComponent("NextWorkZone/v2", isDirectory: true) }
}
