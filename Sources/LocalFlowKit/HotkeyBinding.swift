import CoreGraphics
import Foundation

/// A user-configurable dictation shortcut. Persisted as JSON in UserDefaults under
/// `HotkeyBinding.defaultsKey`. Two shapes, matching the two gestures LocalFlow supports:
///
///  - `.modifierHold`: hold ALL of the given modifier keys to record; release any to
///    finish. Tapping Space while holding locks recording hands-free. This is the
///    classic gesture (default: Right Option alone).
///  - `.comboToggle`: press a key combination once to start recording hands-free, press
///    it again to finish. The combo is swallowed system-wide while LocalFlow runs.
///
/// Keeps to Foundation + CoreGraphics so it stays AppKit-free and unit-testable from the
/// DictCheck CLI (no window server, no NSEvent).
public enum HotkeyBinding: Codable, Equatable {
    /// Hold ALL of these modifier keys to record; release any to finish. Keycodes
    /// (not flags) so left/right modifiers are distinct.
    case modifierHold(keyCodes: Set<Int64>)

    /// Press once to start, press again to finish. `keyCode` is a non-modifier key;
    /// `requiredModifiers` is a normalized set of generic modifier bits.
    case comboToggle(keyCode: Int64, requiredModifiers: UInt64)

    // MARK: - Defaults & persistence keys

    /// UserDefaults key holding the JSON-encoded binding.
    public static let defaultsKey = "hotkeyBinding"

    /// Legacy UserDefaults key: a single modifier keycode from the old fixed picker.
    /// Migrated into `.modifierHold` the first time a binding is loaded.
    public static let legacyKeyCodeDefaultsKey = "hotkeyKeyCode"

    /// Right Option, held — the original (and still default) gesture.
    public static let `default`: HotkeyBinding = .modifierHold(keyCodes: [61])

    // MARK: - Generic modifier bits
    //
    // A device-independent, left/right-collapsed view of the modifier state, used for
    // `comboToggle` matching. Distinct from the per-side keycodes used by `modifierHold`.

    public static let modCommand: UInt64 = 1 << 0
    public static let modControl: UInt64 = 1 << 1
    public static let modOption: UInt64 = 1 << 2
    public static let modShift: UInt64 = 1 << 3
    public static let modFn: UInt64 = 1 << 4

    /// Collapses raw CGEventFlags to just the five generic modifier bits, dropping
    /// caps lock, numeric-pad, help, and coalescing flags.
    public static func normalize(_ flags: CGEventFlags) -> UInt64 {
        var bits: UInt64 = 0
        if flags.contains(.maskCommand) { bits |= modCommand }
        if flags.contains(.maskControl) { bits |= modControl }
        if flags.contains(.maskAlternate) { bits |= modOption }
        if flags.contains(.maskShift) { bits |= modShift }
        if flags.contains(.maskSecondaryFn) { bits |= modFn }
        return bits
    }

    // MARK: - Keycode classification

    /// Left/right modifier keycodes: 58/61 option, 55/54 command, 59/62 control,
    /// 56/60 shift, 63 fn.
    public static let modifierKeyCodes: Set<Int64> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    public static func isModifierKeyCode(_ code: Int64) -> Bool {
        modifierKeyCodes.contains(code)
    }

    /// The generic CGEventFlags mask a given modifier keycode contributes, or nil if
    /// the keycode is not a modifier. Used to detect press vs. release from a
    /// flagsChanged event (the flag is present iff the key is down).
    public static func modifierFlag(forKeyCode code: Int64) -> CGEventFlags? {
        switch code {
        case 54, 55: return .maskCommand
        case 59, 62: return .maskControl
        case 58, 61: return .maskAlternate
        case 56, 60: return .maskShift
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    // MARK: - Combo matching

    /// True iff a keyDown of `eventKeyCode` with `eventFlags` should trigger `binding`.
    /// Only `.comboToggle` can match. The modifier match is EXACT on the five generic
    /// bits (subset AND no extras), so a ⌘D binding does not fire on ⌘⇧D, and vice versa.
    public static func matchesCombo(eventKeyCode: Int64, eventFlags: CGEventFlags, binding: HotkeyBinding) -> Bool {
        guard case let .comboToggle(keyCode, requiredModifiers) = binding else { return false }
        guard eventKeyCode == keyCode else { return false }
        return normalize(eventFlags) == requiredModifiers
    }

    // MARK: - Migration

    /// Converts a legacy single-modifier keycode into a `.modifierHold` binding.
    public static func migrate(legacyKeyCode: Int) -> HotkeyBinding {
        .modifierHold(keyCodes: [Int64(legacyKeyCode)])
    }

    /// Loads the binding: the JSON binding if present, else a migrated legacy keycode,
    /// else the default.
    public static func load(from defaults: UserDefaults = .standard) -> HotkeyBinding {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            return decoded
        }
        let legacy = defaults.integer(forKey: legacyKeyCodeDefaultsKey)
        if legacy != 0 {
            return migrate(legacyKeyCode: legacy)
        }
        return .default
    }

    /// Persists the binding as JSON.
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: HotkeyBinding.defaultsKey)
        }
    }

    // MARK: - Validation

    public enum ValidationResult: Equatable {
        case valid
        case invalid(String)
    }

    /// Keys that type visible characters — binding one of these with no modifier would
    /// swallow normal typing. (Letters, digits, and punctuation; Space is handled
    /// separately since it is reserved for hands-free lock.)
    private static let printableKeyCodes: Set<Int64> = [
        // Letters
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        31, 32, 34, 35, 37, 38, 40, 45, 46,
        // Digits
        18, 19, 20, 21, 22, 23, 25, 26, 28, 29,
        // Punctuation
        24, 27, 30, 33, 39, 41, 42, 43, 44, 47, 50
    ]

    private static let spaceKeyCode: Int64 = 49

    /// Combos macOS reserves that would break paste/quit/close/Spotlight if swallowed.
    private static let reservedCommandKeyCodes: Set<Int64> = [
        9,  // ⌘V paste (also LocalFlow's own synthesized paste)
        8,  // ⌘C copy
        7,  // ⌘X cut
        12, // ⌘Q quit
        13  // ⌘W close
    ]

    /// Rejects bindings that would eat normal input or clash with the system. Returns a
    /// friendly, user-facing message on failure.
    public static func validate(_ binding: HotkeyBinding) -> ValidationResult {
        switch binding {
        case let .modifierHold(keyCodes):
            if keyCodes.isEmpty {
                return .invalid("Pick at least one modifier key to hold.")
            }
            if keyCodes.contains(where: { !isModifierKeyCode($0) }) {
                return .invalid("Hold-to-talk shortcuts must use only modifier keys.")
            }
            return .valid

        case let .comboToggle(keyCode, requiredModifiers):
            if keyCode == spaceKeyCode {
                return .invalid("Space can’t be part of a shortcut — it’s reserved for locking hands-free recording.")
            }
            if requiredModifiers == 0 && printableKeyCodes.contains(keyCode) {
                return .invalid("Add a modifier like ⌘ or ⌃ — a plain key would type while you’re working.")
            }
            if requiredModifiers == modCommand && reservedCommandKeyCodes.contains(keyCode) {
                return .invalid("\(binding.description) is reserved by macOS. Pick another combination.")
            }
            return .valid
        }
    }
}

// MARK: - Human-readable rendering

extension HotkeyBinding {
    public var isHold: Bool {
        if case .modifierHold = self { return true }
        return false
    }

    /// The keys alone, without any verb: "Right Option", "Right ⌘ + Right ⌥", "⌘⇧D".
    public var keysLabel: String {
        switch self {
        case let .modifierHold(keyCodes):
            let sorted = keyCodes.sorted()
            if sorted.count == 1 {
                return HotkeyBinding.modifierHoldName(forKeyCode: sorted[0])
            }
            return sorted.map { HotkeyBinding.modifierShortName(forKeyCode: $0) }.joined(separator: " + ")
        case let .comboToggle(keyCode, requiredModifiers):
            return HotkeyBinding.modifierSymbols(requiredModifiers) + HotkeyBinding.keyName(forKeyCode: keyCode)
        }
    }

    /// A short label for the settings field: "Hold Right Option" or "⌘⇧D".
    public var description: String {
        isHold ? "Hold \(keysLabel)" : keysLabel
    }

    /// The menu-bar hint line under the status.
    public var menuHint: String {
        if isHold {
            return "Hold \(keysLabel) to dictate, or \(keysLabel) + Space to lock hands-free; tap \(keysLabel) to finish"
        }
        return "Press \(keysLabel) to dictate hands-free; press \(keysLabel) again to finish"
    }

    /// The onboarding success-card line.
    public var onboardingHint: String {
        if isHold {
            return "Hold \(keysLabel) to dictate, or press \(keysLabel) + Space to lock hands-free; tap \(keysLabel) to finish."
        }
        return "Press \(keysLabel) to start dictating, then press \(keysLabel) again to finish."
    }

    /// The menu status text while a hands-free recording is in progress.
    public var lockedStatusText: String {
        if isHold {
            return "Recording (locked) — tap \(keysLabel) to finish"
        }
        return "Recording — press \(keysLabel) to finish"
    }

    // MARK: - Name maps

    /// Wordy modifier name for a single-key hold: "Right Option".
    static func modifierHoldName(forKeyCode code: Int64) -> String {
        switch code {
        case 58: return "Left Option"
        case 61: return "Right Option"
        case 55: return "Left Command"
        case 54: return "Right Command"
        case 59: return "Left Control"
        case 62: return "Right Control"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        case 63: return "Fn"
        default: return "Key #\(code)"
        }
    }

    /// Compact side + symbol name for a multi-key hold: "Right ⌥".
    static func modifierShortName(forKeyCode code: Int64) -> String {
        switch code {
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 55: return "Left ⌘"
        case 54: return "Right ⌘"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        case 63: return "fn"
        default: return "#\(code)"
        }
    }

    /// The modifier symbols for a combo, in a fixed order (command first, then ⌃⌥⇧ fn),
    /// so ⌘+Shift renders "⌘⇧".
    static func modifierSymbols(_ bits: UInt64) -> String {
        var out = ""
        if bits & modCommand != 0 { out += "⌘" }
        if bits & modControl != 0 { out += "⌃" }
        if bits & modOption != 0 { out += "⌥" }
        if bits & modShift != 0 { out += "⇧" }
        if bits & modFn != 0 { out += "fn" }
        return out
    }

    /// Human-readable name for a non-modifier key.
    static func keyName(forKeyCode code: Int64) -> String {
        HotkeyBinding.keyNames[code] ?? "key #\(code)"
    }

    private static let keyNames: [Int64: String] = [
        // Letters
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        // Digits
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        // Punctuation
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        // Editing / navigation
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Forward Delete",
        115: "Home", 116: "Page Up", 119: "End", 121: "Page Down", 114: "Help",
        // Arrows
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
}
