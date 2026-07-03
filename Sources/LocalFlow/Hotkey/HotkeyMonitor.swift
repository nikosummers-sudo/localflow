import ApplicationServices
import CoreGraphics
import Foundation
import LocalFlowKit

/// Watches the user's configured dictation shortcut system-wide via a CGEventTap and
/// drives a small state machine supporting two gesture families:
///
///  - Modifier hold (`.modifierHold`): hold ALL the configured modifier keys to record,
///    release any to finish (`holdRecording`). While holding, tap Space to lock recording
///    hands-free (`lockedRecording`); release the modifiers and it keeps going; press a
///    configured modifier again to finish. Single-modifier holds behave exactly like the
///    original Right Option gesture.
///  - Combo toggle (`.comboToggle`): press a key combination once to start recording
///    hands-free, press it again to finish. The matching key events are swallowed so they
///    never reach the focused app; Space is not special in this mode.
///
/// Locking (and combo swallowing) needs an ACTIVE tap (`.defaultTap`), which requires
/// Input Monitoring. When the OS refuses one we fall back to a listen-only tap: gestures
/// still fire, but key events can no longer be consumed (`canConsumeEvents`).
final class HotkeyMonitor {
    /// Space — locks recording while a modifier-hold shortcut is held.
    private static let spaceKeyCode: Int64 = 49

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onLockEngaged: (() -> Void)?

    private enum State {
        case idle
        case holdRecording
        case lockedRecording
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var binding: HotkeyBinding
    private var state: State = .idle

    /// For `.modifierHold`: which of the target modifier keycodes are currently down.
    private var heldTargets: Set<Int64> = []
    /// For `.comboToggle`: the keycode whose next keyUp we should consume (it pairs with
    /// a keyDown we already swallowed).
    private var pendingKeyUpConsume: Int64?

    /// True when the tap is active and can swallow keys; false on the listen-only fallback.
    private(set) var canConsumeEvents = false

    init() {
        binding = HotkeyBinding.load()
    }

    var isRunning: Bool { eventTap != nil }

    /// Starts the tap. Returns false if it could not be created (missing Input Monitoring).
    @discardableResult
    func start() -> Bool {
        stop()

        // flagsChanged tracks held modifiers; keyDown catches combo keys and the Space
        // that locks; keyUp lets us swallow the release paired with a consumed combo key.
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if monitor.handle(type: type, event: event) {
                return nil // consume (Space lock, or a combo key + its keyUp)
            }
            return Unmanaged.passUnretained(event)
        }

        // Prefer an active tap so keys can be swallowed.
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) {
            canConsumeEvents = true
            install(tap)
            EventLog.log("tap.created", ["mode": "active"])
            return true
        }

        // Fall back to listen-only: gestures still fire, but keys can't be consumed.
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) {
            canConsumeEvents = false
            install(tap)
            EventLog.log("tap.created", ["mode": "listenOnly"])
            return true
        }

        EventLog.log("tap.failed", [
            "inputMonitoring": PermissionsManager.shared.inputMonitoringGranted ? "granted" : "denied",
        ])
        return false
    }

    private func install(_ tap: CFMachPort) {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        state = .idle
        heldTargets = []
        pendingKeyUpConsume = nil
    }

    /// Re-reads the configured binding and restarts the tap.
    @discardableResult
    func restart() -> Bool {
        binding = HotkeyBinding.load()
        return start()
    }

    /// Handles one tapped event. Returns true iff the event should be consumed. Runs on
    /// the main run loop, so it reads/writes state synchronously and keeps work trivial.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap that blocks too long or on heavy input; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)

        switch binding {
        case let .modifierHold(keyCodes):
            return handleModifierHold(type: type, event: event, code: code, targets: keyCodes)
        case .comboToggle:
            return handleComboToggle(type: type, event: event, code: code)
        }
    }

    // MARK: - Modifier hold

    private func handleModifierHold(type: CGEventType, event: CGEvent, code: Int64, targets: Set<Int64>) -> Bool {
        if type == .keyDown {
            if code == HotkeyMonitor.spaceKeyCode, state == .holdRecording {
                state = .lockedRecording
                fire(onLockEngaged)
                return true // swallow the Space so it doesn't type into the focused app
            }
            return false
        }

        guard type == .flagsChanged, targets.contains(code) else { return false }
        guard let flag = HotkeyBinding.modifierFlag(forKeyCode: code) else { return false }

        let wasHeld = heldTargets.contains(code)
        let isPressed = event.flags.contains(flag)
        if isPressed { heldTargets.insert(code) } else { heldTargets.remove(code) }
        let allHeld = targets.isSubset(of: heldTargets)

        switch state {
        case .idle:
            // Start once every target modifier is held together.
            if allHeld { state = .holdRecording; fire(onKeyDown) }
        case .holdRecording:
            // Releasing any target finishes the hold recording.
            if !allHeld { state = .idle; fire(onKeyUp) }
        case .lockedRecording:
            // Locked and hands-free: a fresh press of any target finishes; releases
            // (the user letting go after locking) are ignored.
            if isPressed && !wasHeld { state = .idle; fire(onKeyUp) }
        }
        return false
    }

    // MARK: - Combo toggle

    private func handleComboToggle(type: CGEventType, event: CGEvent, code: Int64) -> Bool {
        // Swallow the keyUp that pairs with a keyDown we already consumed, so the
        // release never reaches the focused app.
        if type == .keyUp {
            if pendingKeyUpConsume == code {
                pendingKeyUpConsume = nil
                return true
            }
            return false
        }

        guard type == .keyDown else { return false } // ignore flagsChanged in combo mode

        guard HotkeyBinding.matchesCombo(eventKeyCode: code, eventFlags: event.flags, binding: binding) else {
            return false
        }

        // Consume every matching keyDown (including autorepeat) so it never types, but
        // only toggle on the first press — autorepeat must not flip recording on/off.
        pendingKeyUpConsume = code
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            switch state {
            case .idle:
                // Start recording hands-free: fire start, then engage lock so the HUD
                // and menu reflect the hands-free state.
                state = .lockedRecording
                fire(onKeyDown)
                fire(onLockEngaged)
            case .holdRecording, .lockedRecording:
                state = .idle
                fire(onKeyUp)
            }
        }
        return true
    }

    private func fire(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }
}
