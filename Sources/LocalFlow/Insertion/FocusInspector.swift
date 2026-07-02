import ApplicationServices

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

    /// Classifies the focused element. `.notEditable` is only returned when we
    /// positively have (or positively lack) a focused element and none of the
    /// editable indicators hold; every error/ambiguity yields `.unknown`.
    static func classifyFocusedElement() -> FocusTarget {
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
