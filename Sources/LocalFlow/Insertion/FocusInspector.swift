import AppKit
import ApplicationServices
import LocalFlowKit

/// Classification of the system-wide focused UI element for deciding whether a
/// synthesized paste will actually land somewhere useful.
enum FocusTarget {
    /// The focused element accepts text entry — safe to paste.
    case editable
    /// We positively determined the focus is NOT a text entry surface.
    case notEditable
    /// Any AX error, missing permission, or ambiguity. Callers should bias
    /// toward pasting here — a false `.notEditable` is worse than a wasted paste.
    case unknown
}

/// Inspects the currently focused UI element via the Accessibility API to decide
/// whether dictated text can be pasted into it. Only meaningful when the process
/// is AX-trusted; callers must gate on `AXIsProcessTrusted()`.
enum FocusInspector {
    /// Roles that unambiguously accept text entry. Web/Electron content usually
    /// surfaces its inputs through the web area with these same roles.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        "AXSearchField",
        kAXComboBoxRole,
    ]

    /// Subroles that indicate a text-entry surface even when the role is generic.
    private static let editableSubroles: Set<String> = [
        "AXSecureTextField",
        "AXSearchField",
        "AXTextInput",
    ]

    /// Once-per-process cache of Electron-unlock attempts so a stubborn app
    /// doesn't pay the re-check wait on every dictation.
    private static var unlockAttemptedPIDs = Set<pid_t>()
    private static let unlockLock = NSLock()

    /// Classifies the focused element. When the first pass says `.notEditable`,
    /// tries the Electron unlock once per app process and re-checks: Electron
    /// apps only build their accessibility tree when an assistive client asks
    /// (Slack does this by itself; the Claude desktop app doesn't), so setting
    /// AXManualAccessibility can turn an opaque "not editable" into the truth.
    static func classifyFocusedElement() -> FocusTarget {
        let first = classifyOnce()
        guard first == .notEditable,
              let app = NSWorkspace.shared.frontmostApplication else { return first }

        let pid = app.processIdentifier
        unlockLock.lock()
        let alreadyTried = unlockAttemptedPIDs.contains(pid)
        if !alreadyTried { unlockAttemptedPIDs.insert(pid) }
        unlockLock.unlock()
        guard !alreadyTried else { return first }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        usleep(250_000)  // give the app a beat to build its tree
        let second = classifyOnce()
        EventLog.log("ax.electronUnlock", [
            "bundle": app.bundleIdentifier ?? "?",
            "after": String(describing: second),
        ])
        return second
    }

    /// Single classification pass. `.notEditable` is only returned when we
    /// positively have (or positively lack) a focused element and none of the
    /// editable indicators hold; every error/ambiguity yields `.unknown`.
    private static func classifyOnce() -> FocusTarget {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )

        // A definitive "there is no focused element" (e.g. Finder desktop) is a
        // positive signal that a paste has nowhere to go.
        if err == .noValue || err == .attributeUnsupported {
            return .notEditable
        }
        guard err == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let element = focusedRef as! AXUIElement

        if let role = copyStringAttribute(element, kAXRoleAttribute), editableRoles.contains(role) {
            return .editable
        }
        if let subrole = copyStringAttribute(element, kAXSubroleAttribute), editableSubroles.contains(subrole) {
            return .editable
        }

        // A settable value attribute is the general signal for an editable field
        // (covers custom/native inputs that don't report a standard role).
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable
        }

        // contenteditable surfaces (Slack/Notion/Docs composers) can report generic
        // roles with a non-settable value. A SETTABLE selected-text attribute means
        // typing can replace the selection — a true editability signal. Mere
        // presence of a selection range is NOT enough: static web pages expose
        // selection ranges too (any page lets you select text), which would
        // mis-flag e.g. a YouTube page as editable.
        var selectedTextSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &selectedTextSettable
        ) == .success, selectedTextSettable.boolValue {
            return .editable
        }

        // We have a real focused element but nothing marks it as text-editable.
        return .notEditable
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return (value as! CFString) as String
    }
}
