import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: virtual key code + modifiers, plus the label shown in the UI.
struct Shortcut: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var keyLabel: String

    static let `default` = Shortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.command, .shift], keyLabel: "R")

    /// e.g. "⌃⌥⇧⌘R" (Apple's canonical modifier order).
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// Builds a shortcut from a key event; nil if it is not usable as a global hotkey
    /// (needs ⌘, ⌃ or ⌥, unless it is a function key).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let label = Self.label(for: event)
        let isFunctionKey = Self.functionKeys[Int(event.keyCode)] != nil
        guard !label.isEmpty, isFunctionKey || !mods.intersection([.command, .option, .control]).isEmpty else {
            return nil
        }
        self.init(keyCode: event.keyCode, modifiers: mods, keyLabel: label)
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ForwardDelete: "⌦",
    ]

    private static func label(for event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let f = functionKeys[code] { return f }
        if let n = namedKeys[code] { return n }
        return (event.charactersIgnoringModifiers ?? "").uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One system-wide hotkey via Carbon RegisterEventHotKey (no Accessibility permission needed).
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    /// Registers `shortcut` (nil = none). Returns false if the system refused it, usually
    /// because another app already owns that combination.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4D52_4543), id: 1)  // "MREC"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { ref = nil }
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
