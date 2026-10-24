import AppKit

// 界面偏好要在读取之前沿用过来
PrefsMigration.run()

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
