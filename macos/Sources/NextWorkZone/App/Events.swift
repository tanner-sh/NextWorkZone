import Combine
import Foundation
import SwiftUI
import NWZCore

/// 应用层发出的事件（见 [`AppEvent`]），以及界面内部的通知，经 NotificationCenter 分发到主线程。
enum Events {
    static func post(_ event: ServiceEvent) {
        let data = try? JSONEncoder().encode(event.payload)
        post(event.name, payload: data.map { String(decoding: $0, as: UTF8.self) } ?? "null")
    }

    static func name(_ event: String) -> Notification.Name { Notification.Name("nwz." + event) }

    /// 发出事件；`payload` 为 JSON 文本。
    static func post(_ event: String, payload: String = "null") {
        let send: @Sendable () -> Void = { NotificationCenter.default.post(name: name(event), object: nil, userInfo: ["payload": payload]) }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }

    static func publisher(_ events: String...) -> AnyPublisher<Notification, Never> {
        Publishers.MergeMany(events.map { NotificationCenter.default.publisher(for: name($0)) }).receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// 本地数据有修改：通知其他界面刷新，并在稍后同步到其他设备（连续修改只同步一次）。
    @MainActor static func workspaceChanged() {
        post(local.workspaceChanged)
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            _ = try? await API.shared.wsSync()
        }
    }

    @MainActor private static var syncTask: Task<Void, Never>?

    /// 界面内部的事件。
    enum local {
        static let workspaceChanged = "local.workspace-changed"
        static let activityFeed = "local.activity-feed"
        static let issueViewed = "local.issue-viewed"
        static let reminders = "local.reminders"
        static let inbox = "local.inbox"
    }
}

extension View {
    /// 收到事件时执行。
    func onEvent(_ events: String..., perform: @escaping (Notification) -> Void) -> some View {
        onReceive(Publishers.MergeMany(events.map { NotificationCenter.default.publisher(for: Events.name($0)) }).receive(on: DispatchQueue.main), perform: perform)
    }

    /// 本地或其他设备的工作空间数据变化时执行。
    func onWorkspaceChange(perform: @escaping () -> Void) -> some View {
        onEvent(Events.local.workspaceChanged, AppEvent.workspaceSynced) { _ in perform() }
    }
}
