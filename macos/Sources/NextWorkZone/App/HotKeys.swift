import AppKit
import Carbon.HIToolbox

/// 全局快捷键：快速记录、剪贴板等功能各自登记一个快捷键，互不影响。快捷键写法例如 `CommandOrControl+Alt+V`（保存在配置中）。
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private struct Bound {
        var shortcut: String
        var ref: EventHotKeyRef
    }

    private var bound: [String: Bound] = [:]
    /// 注册失败的原因（例如已被其他应用占用），设置页中显示。
    private var errors: [String: String] = [:]
    private var handlers: [String: () -> Void] = [:]
    private var ids: [UInt32: String] = [:]
    private var nextId: UInt32 = 1
    private var installed = false

    static let labels = ["capture": "快速记录", "clipboard": "剪贴板"]

    func setHandler(_ action: String, _ handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// 启动时注册；失败只记录原因。
    func initial(_ action: String, _ shortcut: String) {
        if let e = set(action, shortcut) { errors[action] = e }
    }

    func error(_ action: String) -> String? { errors[action] }

    /// 把功能的快捷键改为 `shortcut`（为空表示不使用）。新快捷键注册失败时保留原来的并返回错误。
    func set(_ action: String, _ shortcut: String) -> String? {
        installHandler()
        let shortcut = shortcut.trimmingCharacters(in: .whitespaces)
        if !shortcut.isEmpty, let other = bound.first(where: { $0.key != action && $0.value.shortcut.caseInsensitiveCompare(shortcut) == .orderedSame })?.key {
            return "快捷键已被“\(Self.labels[other] ?? other)”使用"
        }
        let old = bound.removeValue(forKey: action)
        if let old { UnregisterEventHotKey(old.ref) }
        if shortcut.isEmpty {
            errors[action] = nil
            return nil
        }
        if let ref = register(action, shortcut) {
            bound[action] = Bound(shortcut: shortcut, ref: ref)
            errors[action] = nil
            return nil
        }
        // 恢复原来的快捷键
        if let old, let ref = register(action, old.shortcut) {
            bound[action] = Bound(shortcut: old.shortcut, ref: ref)
        }
        return "无法使用快捷键 \(Self.display(shortcut))（可能已被其他应用占用）"
    }

    private func register(_ action: String, _ shortcut: String) -> EventHotKeyRef? {
        guard let (code, mods) = Self.parse(shortcut) else { return nil }
        let id = nextId
        nextId += 1
        ids[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(code, mods, EventHotKeyID(signature: OSType(0x4E575A4B), id: id), GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let action = HotKeys.shared.ids[id] { HotKeys.shared.handlers[action]?() }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    // MARK: 写法

    private static let keyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
        "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L, "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
        "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
        "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "SPACE": kVK_Space, "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3,
        "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7, "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
    ]

    static func parse(_ shortcut: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var code: Int?
        for part in shortcut.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part.lowercased() {
            case "commandorcontrol", "cmdorctrl", "command", "cmd", "super", "meta": mods |= UInt32(cmdKey)
            case "control", "ctrl": mods |= UInt32(controlKey)
            case "alt", "option": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            default:
                let key = part.uppercased().replacingOccurrences(of: "KEY", with: "").replacingOccurrences(of: "DIGIT", with: "")
                code = keyCodes[key]
            }
        }
        guard let code else { return nil }
        return (UInt32(code), mods)
    }

    /// 快捷键的显示：用 ⌃⌥⇧⌘ 符号，按 macOS 菜单的惯用顺序。
    static func display(_ shortcut: String) -> String {
        if shortcut.isEmpty { return "未使用" }
        let names = ["CommandOrControl": "⌘", "Command": "⌘", "Super": "⌘", "Alt": "⌥", "Shift": "⇧", "Control": "⌃", "Space": "Space"]
        var parts = shortcut.split(separator: "+").map { names[String($0)] ?? String($0) }
        let order = Array("⌃⌥⇧⌘").map(String.init)
        parts.sort { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
        return parts.joined()
    }

    /// 由按键事件得到快捷键（至少一个修饰键加一个普通键，或单独的功能键）；只按了修饰键时返回 nil。
    static func shortcut(of event: NSEvent) -> String? {
        let code = Int(event.keyCode)
        guard let key = keyCodes.first(where: { $0.value == code })?.key else { return nil }
        let name = key == "SPACE" ? "Space" : key
        let flags = event.modifierFlags
        var mods: [String] = []
        if flags.contains(.command) { mods.append("Command") }
        if flags.contains(.control) { mods.append("Control") }
        if flags.contains(.option) { mods.append("Alt") }
        if flags.contains(.shift) { mods.append("Shift") }
        if mods.isEmpty && !(name.count > 1 && name.hasPrefix("F")) { return nil }
        return (mods + [name]).joined(separator: "+")
    }
}
