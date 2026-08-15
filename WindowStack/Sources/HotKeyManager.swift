import AppKit
import Carbon.HIToolbox

enum HotKeyAction: String, Codable, CaseIterable {
    case tile
    case cascade
    case restore
}

struct HotKeySpec: Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
}

/// 全局快捷键管理：基于 Carbon RegisterEventHotKey，系统级热键、无需"输入监控"授权。
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x5753_5441   // "WSTA"

    private init() {
        installEventHandler()
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let ref = hotKeyRef else { return nil }
        hotKeys[id] = ref
        actions[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = hotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: id)
    }

    func unregisterAll() {
        for id in Array(hotKeys.keys) {
            unregister(id)
        }
    }

    /// NSEvent 修饰键 → Carbon 修饰键位掩码。
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    /// 录制事件 → 显示字符串（⌘⇧⌥⌃ + 键名）。
    static func displayString(for event: NSEvent) -> String {
        var parts = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        return parts + (chars.isEmpty ? "?" : chars)
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }
            if hotKeyID.signature == HotKeyManager.shared.signature {
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    HotKeyManager.shared.actions[id]?()
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &handlerRef)
    }
}
