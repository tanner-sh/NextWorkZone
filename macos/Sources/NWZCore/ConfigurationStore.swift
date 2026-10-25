import Foundation
import Synchronization

/// 应用配置（config.json）：读取时取内存中的快照，修改时先写入文件再替换快照，各服务看到的始终是同一份配置。
public final class ConfigurationStore: Sendable {
    public let path: URL
    private let value: Mutex<AppConfig>
    public init(path: URL) throws {
        self.path = path
        value = Mutex(try AppConfig.load(from: path))
    }
    public func snapshot() -> AppConfig { value.withLock { $0 } }
    public func update(_ change: (inout AppConfig) throws -> Void) throws {
        try value.withLock { current in
            var next = current
            try change(&next)
            try next.save(to: path)
            current = next
        }
    }
    public func replace(_ next: AppConfig) throws { try update { $0 = next } }
}
