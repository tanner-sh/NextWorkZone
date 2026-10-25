import Foundation

public struct ServiceEvent: Sendable, Equatable {
    public let name: String
    public let payload: JSONValue
    public init(_ name: String, payload: JSONValue = .null) { self.name = name; self.payload = payload }
}

/// 业务模块只描述平台操作，窗口、通知和快捷键由界面提供。
public protocol AppHost: Sendable {
    func emit(_ event: ServiceEvent)
    func notify(title: String, body: String)
    func openPath(path: String) -> String?
    func setShortcut(action: String, shortcut: String) -> String?
    func shortcutError(action: String) -> String?
    func hideClipboardPanel(restore: Bool)
    func clipboardPaused(paused: Bool)
}

public actor EventBus {
    private var listeners: [UUID: AsyncStream<ServiceEvent>.Continuation] = [:]
    public init() {}
    public func events() -> AsyncStream<ServiceEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ServiceEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    public func emit(_ event: ServiceEvent) { for listener in listeners.values { listener.yield(event) } }
    public func finish() { for listener in listeners.values { listener.finish() }; listeners.removeAll() }
    private func remove(_ id: UUID) { listeners[id] = nil }
}
