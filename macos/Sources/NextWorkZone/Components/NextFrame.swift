import AppKit
import QuartzCore

/// 等到屏幕下一次刷新（当前这一帧已经提交）之后再继续，用来把不急的界面工作推迟到首帧之后。
///
/// 不能用 `.task`、`Task {}` 或 `DispatchQueue.main.async` 推迟：主线程的运行循环在还有排队的任务时
/// 会先执行它们，再把这一轮的界面改动提交到屏幕，所以用这些方式“推迟”的工作仍然算在同一帧里，
/// 点击后要等它们也做完才看到新内容。屏幕刷新回调在下一次垂直同步时才到，那时这一帧已经提交。
@MainActor
enum NextFrame {
    private final class Waiter: NSObject {
        var continuations: [CheckedContinuation<Void, Never>] = []
        var link: CADisplayLink?

        @objc func tick(_ link: CADisplayLink) {
            link.invalidate()
            self.link = nil
            let waiting = continuations
            continuations = []
            for c in waiting { c.resume() }
        }
    }

    private static let waiter = Waiter()

    /// 多处同时等待时共用一个回调。没有屏幕（例如合上盖子外接显示器也没有）时立即返回。
    static func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if waiter.link == nil {
                guard let screen = NSScreen.main ?? NSScreen.screens.first else { c.resume(); return }
                let link = screen.displayLink(target: waiter, selector: #selector(Waiter.tick(_:)))
                link.add(to: .main, forMode: .common)
                waiter.link = link
            }
            waiter.continuations.append(c)
        }
    }
}
