import Foundation
import Synchronization

/// 同步保存入口也供过渡期平台回调使用，避免 Rust 设置写回另一份配置。
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
