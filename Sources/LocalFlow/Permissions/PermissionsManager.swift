import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid

/// Central place for the three TCC permissions LocalFlow needs, each with a live
/// status check, a request action, and a deep link to the relevant System Settings pane.
final class PermissionsManager {
    static let shared = PermissionsManager()

    enum Status {
        case granted
        case denied
        case notDetermined
    }

    // MARK: - Microphone

    var microphoneStatus: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    var microphoneGranted: Bool { microphoneStatus == .granted }

    func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Accessibility (needed to synthesize the paste keystroke)

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Input Monitoring (needed for the global hotkey event tap)

    var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - Aggregate

    var allGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }

    // MARK: - System Settings deep links

    func openMicrophoneSettings() { open("Privacy_Microphone") }
    func openAccessibilitySettings() { open("Privacy_Accessibility") }
    func openInputMonitoringSettings() { open("Privacy_ListenEvent") }

    private func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
