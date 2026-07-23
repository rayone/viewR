import AppKit
import Carbon.HIToolbox
import Foundation
import os.log

private let log = Logger(subsystem: "r1.vr", category: "ui")

// MARK: - HotkeyAction

enum HotkeyAction: String, CaseIterable {
    case navigateForward
    case navigateBackward
    case rotateCW
    case rotateCCW
    case delete
    case toggleInfo
    case toggleZoom
    case revealInFinder
    case copyImage

    var displayName: String {
        switch self {
        case .navigateForward:  return "Navigate Forward"
        case .navigateBackward: return "Navigate Backward"
        case .rotateCW:         return "Rotate Clockwise"
        case .rotateCCW:        return "Rotate Counter-Clockwise"
        case .delete:           return "Delete Image"
        case .toggleInfo:       return "Toggle Info HUD"
        case .toggleZoom:       return "Toggle Zoom Mode"
        case .revealInFinder:   return "Reveal in Finder"
        case .copyImage:        return "Copy Image"
        }
    }
}

// MARK: - HotkeyBinding

struct HotkeyBinding: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.control) { parts.append("⌃") }
        if let char = keyCodeToString(keyCode) { parts.append(char) }
        return parts.joined()
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String? {
        let map: [UInt16: String] = [
            123: "←", 124: "→", 125: "↓", 126: "↑",
            51: "⌫", 53: "Esc", 36: "↩", 48: "⇥",
            49: "Space", 122: "F1", 120: "F2", 99: "F3",
        ]
        if let special = map[keyCode] { return special }
        // Use CoreGraphics to translate keycode to character
        let source = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let result = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            0,
            &deadKeyState,
            4,
            &length,
            &chars
        )
        guard result == noErr, length > 0 else { return nil }
        return String(chars.prefix(length).map { Character(UnicodeScalar($0)!) }).uppercased()
    }
}

// MARK: - HotkeyManager

final class HotkeyManager {

    // MARK: - Defaults

    static let defaults: [HotkeyAction: HotkeyBinding] = [
        .navigateForward:  HotkeyBinding(keyCode: 124, modifiers: []),   // →
        .navigateBackward: HotkeyBinding(keyCode: 123, modifiers: []),   // ←
        .rotateCW:         HotkeyBinding(keyCode: 126, modifiers: []),   // ↑
        .rotateCCW:        HotkeyBinding(keyCode: 125, modifiers: []),   // ↓
        .delete:           HotkeyBinding(keyCode: 51,  modifiers: []),   // ⌫
        .toggleInfo:       HotkeyBinding(keyCode: 34,  modifiers: []),   // I (keyCode 34)
        .toggleZoom:       HotkeyBinding(keyCode: 6,   modifiers: []),   // Z (keyCode 6)
        .revealInFinder:   HotkeyBinding(keyCode: 3,   modifiers: []),   // F (keyCode 3)
        .copyImage:        HotkeyBinding(keyCode: 8,   modifiers: [.command]),  // ⌘C
    ]

    static let defaultKeyRateDivider: Int = 1

    static let defaultCacheBudgetImages: Int = 30

    // MARK: - UserDefaults keys

    private enum Keys {
        static let keyCodesPrefix   = "hotkey.keyCode."
        static let modifiersPrefix  = "hotkey.modifiers."
        static let keyRateDivider   = "hotkey.keyRateDivider"
        static let confirmDelete    = "hotkey.confirmDelete"
        static let cacheBudgetImages = "hotkey.cacheBudgetImages"
        static let saveChangesToFiles = "hotkey.saveChangesToFiles"
        static let showTitlebarInfo  = "hotkey.showTitlebarInfo"
    }

    // MARK: - State

    private var bindings: [HotkeyAction: HotkeyBinding] = [:]
    /// key: keyCode, value: [modifiers.rawValue → action]
    private var reverseLookup: [UInt16: [UInt: HotkeyAction]] = [:]

    /// Called on the calling thread whenever cacheBudgetImages changes (including resetToDefaults).
    var onCacheBudgetChanged: ((Int) -> Void)?

    /// Called when showTitlebarInfo changes.
    var onShowTitlebarInfoChanged: ((Bool) -> Void)?

    var keyRateDivider: Int {
        get { UserDefaults.standard.integer(forKey: Keys.keyRateDivider).nonZero ?? Self.defaultKeyRateDivider }
        set { UserDefaults.standard.set(max(1, min(50, newValue)), forKey: Keys.keyRateDivider) }
    }

    var confirmDelete: Bool {
        get { UserDefaults.standard.object(forKey: Keys.confirmDelete) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: Keys.confirmDelete) }
    }

    var saveChangesToFiles: Bool {
        get { UserDefaults.standard.object(forKey: Keys.saveChangesToFiles) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.saveChangesToFiles) }
    }

    var cacheBudgetImages: Int {
        get { UserDefaults.standard.integer(forKey: Keys.cacheBudgetImages).nonZero ?? Self.defaultCacheBudgetImages }
        set {
            let clamped = max(10, min(400, newValue))
            UserDefaults.standard.set(clamped, forKey: Keys.cacheBudgetImages)
            onCacheBudgetChanged?(clamped)
        }
    }

    var showTitlebarInfo: Bool {
        get { UserDefaults.standard.object(forKey: Keys.showTitlebarInfo) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.showTitlebarInfo)
            onShowTitlebarInfoChanged?(newValue)
        }
    }

    // MARK: - Init

    init() {
        loadFromDefaults()
        rebuildReverseLookup()
    }

    // MARK: - Lookup

    func action(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HotkeyAction? {
        let relevantMods = modifiers.intersection([.command, .option, .shift, .control]).rawValue
        return reverseLookup[keyCode]?[relevantMods]
    }

    func binding(for action: HotkeyAction) -> HotkeyBinding? {
        bindings[action]
    }

    // MARK: - Mutation

    /// Returns the action that was displaced (if any).
    @discardableResult
    func setBinding(_ binding: HotkeyBinding, for action: HotkeyAction) -> HotkeyAction? {
        let relevantMods = binding.modifiers.intersection([.command, .option, .shift, .control]).rawValue
        let displaced = reverseLookup[binding.keyCode]?[relevantMods]

        if let conflict = displaced, conflict != action {
            // Remove conflicting action's binding
            bindings.removeValue(forKey: conflict)
        }

        bindings[action] = binding
        persist(binding, for: action)
        rebuildReverseLookup()
        return displaced == action ? nil : displaced
    }

    func resetToDefaults() {
        for action in HotkeyAction.allCases {
            UserDefaults.standard.removeObject(forKey: Keys.keyCodesPrefix + action.rawValue)
            UserDefaults.standard.removeObject(forKey: Keys.modifiersPrefix + action.rawValue)
        }
        UserDefaults.standard.removeObject(forKey: Keys.keyRateDivider)
        UserDefaults.standard.removeObject(forKey: Keys.confirmDelete)
        UserDefaults.standard.removeObject(forKey: Keys.cacheBudgetImages)
        UserDefaults.standard.removeObject(forKey: Keys.saveChangesToFiles)
        UserDefaults.standard.removeObject(forKey: Keys.showTitlebarInfo)
        loadFromDefaults()
        rebuildReverseLookup()
        onCacheBudgetChanged?(Self.defaultCacheBudgetImages)
        onShowTitlebarInfoChanged?(true)
        log.info("Hotkeys reset to defaults")
    }

    // MARK: - Persistence

    private func persist(_ binding: HotkeyBinding, for action: HotkeyAction) {
        UserDefaults.standard.set(Int(binding.keyCode), forKey: Keys.keyCodesPrefix + action.rawValue)
        UserDefaults.standard.set(Int(binding.modifiers.rawValue), forKey: Keys.modifiersPrefix + action.rawValue)
    }

    private func loadFromDefaults() {
        bindings = [:]
        for action in HotkeyAction.allCases {
            let kcKey  = Keys.keyCodesPrefix + action.rawValue
            let modKey = Keys.modifiersPrefix + action.rawValue
            if UserDefaults.standard.object(forKey: kcKey) != nil {
                let kc   = UInt16(UserDefaults.standard.integer(forKey: kcKey))
                let mods = NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: modKey)))
                let b    = HotkeyBinding(keyCode: kc, modifiers: mods)
                // Basic validation: keyCode must be non-zero
                if kc > 0 || Self.defaults[action]?.keyCode == 0 {
                    bindings[action] = b
                    continue
                }
            }
            // Fall back to default
            if let def = Self.defaults[action] {
                bindings[action] = def
            }
        }
    }

    private func rebuildReverseLookup() {
        reverseLookup = [:]
        for (action, binding) in bindings {
            let mods = binding.modifiers.intersection([.command, .option, .shift, .control]).rawValue
            if reverseLookup[binding.keyCode] == nil { reverseLookup[binding.keyCode] = [:] }
            reverseLookup[binding.keyCode]?[mods] = action
        }
    }
}

// MARK: - Helpers

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
