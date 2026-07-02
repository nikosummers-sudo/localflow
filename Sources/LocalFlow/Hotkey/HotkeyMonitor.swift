import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a single "dictation" modifier key (Right Option by default) system-wide
/// via a CGEventTap, and drives a small state machine that supports two gestures:
///
///  - Hold: press-and-hold the hotkey to record, release to finish (`holdRecording`).
///  - Lock: while holding the hotkey, tap Space to lock recording hands-free
///    (`lockedRecording`); release the hotkey and it keeps going; tap the hotkey
///    again to finish.
///
/// Locking requires swallowing the Space keystroke so it never reaches the focused
/// app, which needs an ACTIVE tap (`.defaultTap`). Active taps require Input
/// Monitoring; when the OS refuses one we fall back to a listen-only tap so lock
/// mode still works, only the Space can no longer be consumed (`canConsumeEvents`).
final class HotkeyMonitor {
    static let defaultsKey = "hotkeyKeyCode"

    /// Right Option. Also supported: 54 (Right Command), 62 (Right Control).
    static let defaultKeyCode: Int64 = 61

    /// Space — locks recording while the hotkey is held.
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
    private(set) var keyCode: Int64
    private var state: State = .idle

    /// True when the tap is active and can swallow the Space that engages lock mode.
    /// False when we had to fall back to a listen-only tap.
    private(set) var canConsumeEvents = false

    init() {
        let stored = UserDefaults.standard.integer(forKey: HotkeyMonitor.defaultsKey)
        keyCode = stored == 0 ? HotkeyMonitor.defaultKeyCode : Int64(stored)
    }

    var isRunning: Bool { eventTap != nil }

    /// Starts the tap. Returns false if it could not be created (missing Input Monitoring).
    @discardableResult
    func start() -> Bool {
        stop()

        // flagsChanged tracks the modifier; keyDown lets us catch (and consume) Space.
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // Consume only the Space that engages lock mode; pass everything else through.
            if monitor.handle(type: type, event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Prefer an active tap so Space can be swallowed.
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
            return true
        }

        // Fall back to listen-only: lock mode still works, but Space can't be consumed.
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
            return true
        }

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
    }

    /// Re-reads the configured keycode and restarts the tap.
    @discardableResult
    func restart() -> Bool {
        let stored = UserDefaults.standard.integer(forKey: HotkeyMonitor.defaultsKey)
        keyCode = stored == 0 ? HotkeyMonitor.defaultKeyCode : Int64(stored)
        return start()
    }

    /// Handles one tapped event. Returns true iff the event should be consumed
    /// (only ever the Space that engages lock mode). Runs on the main run loop,
    /// so it reads/writes `state` synchronously and keeps its work trivial.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap that blocks too long or on user input; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            if code == HotkeyMonitor.spaceKeyCode, state == .holdRecording {
                state = .lockedRecording
                fire(onLockEngaged)
                return true // swallow the Space so it doesn't type into the focused app
            }
            return false
        }

        guard type == .flagsChanged, code == keyCode else { return false }

        let pressed = event.flags.contains(flagMask(for: keyCode))
        if pressed {
            switch state {
            case .idle:
                state = .holdRecording
                fire(onKeyDown)
            case .lockedRecording:
                // Tap the hotkey again to finish a hands-free recording.
                state = .idle
                fire(onKeyUp)
            case .holdRecording:
                break
            }
        } else {
            switch state {
            case .holdRecording:
                state = .idle
                fire(onKeyUp)
            case .lockedRecording, .idle:
                // Locked: releasing the hotkey keeps recording. Idle: this is the
                // release that follows a tap-to-finish — ignore it cleanly.
                break
            }
        }
        return false
    }

    private func fire(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }

    private func flagMask(for keyCode: Int64) -> CGEventFlags {
        switch keyCode {
        case 54: return .maskCommand   // Right Command
        case 62: return .maskControl   // Right Control
        default: return .maskAlternate // Right Option (61)
        }
    }
}
