import AppKit
import Testing
@testable import NextWorkZone

@MainActor
@Suite(.serialized)
struct TrafficLightTests {
    private let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private func makeWindow() throws -> (NSWindow, NSView, TitlebarFix.TrafficLightHitView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView?.superview)
        let overlay = TitlebarFix.TrafficLightHitView(frame: root.bounds, styleMask: window.styleMask)
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.update(visible: true)
        return (window, root, overlay)
    }

    private func point(for button: NSButton, in view: NSView) -> NSPoint {
        button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: view)
    }

    @Test
    func hitTestingStaysInsideOverlayAndPassesThroughOtherPoints() throws {
        let (window, root, overlay) = try makeWindow()
        defer { window.close() }

        for type in types {
            let original = try #require(window.standardWindowButton(type))
            let hit = try #require(overlay.hitTest(point(for: original, in: root)))
            #expect(hit !== original)
            #expect(hit.isDescendant(of: overlay))
        }
        #expect(overlay.hitTest(NSPoint(x: root.bounds.midX, y: root.bounds.midY)) == nil)
        overlay.update(visible: false)
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(overlay.hitTest(point(for: close, in: root)) == nil)
    }

    @Test
    func buttonsFollowOriginalStateAndDispatchCurrentAction() throws {
        let (window, root, overlay) = try makeWindow()
        defer { window.close() }
        let original = try #require(window.standardWindowButton(.closeButton))
        let proxy = try #require(overlay.hitTest(point(for: original, in: root)) as? NSButton)
        let receiver = ActionReceiver()
        original.target = receiver
        original.action = #selector(ActionReceiver.activate(_:))

        proxy.performClick(nil)
        #expect(receiver.calls == 1)
        #expect(receiver.sender === original)

        original.isEnabled = false
        #expect(!proxy.isEnabled)
        proxy.performClick(nil)
        #expect(receiver.calls == 1)
        original.isEnabled = true
        #expect(proxy.isEnabled)

        original.isHidden = true
        #expect(proxy.isHidden)
        original.isHidden = false
        #expect(!proxy.isHidden)
    }
}

@MainActor
private final class ActionReceiver: NSObject {
    var calls = 0
    weak var sender: NSButton?

    @objc func activate(_ sender: NSButton) {
        calls += 1
        self.sender = sender
    }
}
