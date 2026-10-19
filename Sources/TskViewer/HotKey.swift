import AppKit
import Carbon.HIToolbox
import TskCore

/// A global shortcut stored as Carbon key code + modifiers; Carbon hot keys need no Accessibility permission.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var label: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey | optionKey), label: "⌥⌘T")
    private static let key = "globalShortcut"
    private static let disabledKey = "globalShortcutDisabled"

    /// nil means the user removed the shortcut.
    static var stored: Shortcut? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: disabledKey) { return nil }
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Shortcut.self, from: data) else { return standard }
        return value
    }

    static func store(_ shortcut: Shortcut?) {
        let defaults = UserDefaults.standard
        defaults.set(shortcut == nil, forKey: disabledKey)
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
    }

    /// Builds a shortcut from a key press; plain keys and Shift-only combinations are rejected.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; symbols += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: UInt32(carbon), label: symbols + Self.keyName(event))
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = label
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: L("Space", pl: "Spacja")
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ shortcut: Shortcut?) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let shortcut else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5453_4B56), id: 1) // "TSKV"
        RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
