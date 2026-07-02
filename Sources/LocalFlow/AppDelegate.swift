import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyMonitor = HotkeyMonitor()
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var hotkeyRetryTimer: Timer?
    private var hudController: HUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyMonitor.onKeyDown = { AppState.shared.startDictation() }
        hotkeyMonitor.onKeyUp = { AppState.shared.stopDictation() }
        hotkeyMonitor.onLockEngaged = { AppState.shared.lockDictation() }

        // Keep the login-item registration in sync with the saved setting (default on).
        LaunchAtLogin.reconcile()

        let tapStarted = hotkeyMonitor.start()

        // The HUD observes AppState and shows/hides itself as dictation proceeds.
        hudController = HUDController(appState: .shared)

        // Load the main model first, then the lighter preview model so they don't
        // compete for the initial download/compile.
        Task {
            await AppState.shared.preloadEngine()
            await AppState.shared.preloadPartialsIfEnabled()
        }
        // Warm the Ollama cleanup model in parallel — it's independent of WhisperKit.
        AppState.shared.warmCleanupModel()

        // Start continuous instant capture if the setting is on and the mic is
        // already granted; the permission-change hook below covers granting later.
        AppState.shared.refreshContinuousCapture()

        if !PermissionsManager.shared.allGranted {
            showOnboarding()
        }

        // Without Input Monitoring the tap can't be created; poll and start it once granted.
        if !tapStarted {
            startHotkeyRetry()
        }
    }

    /// LocalFlow is a menu-bar app with no dock window, so double-clicking it in
    /// Finder/Launchpad otherwise appears to do nothing. Reopen the setup window
    /// (which shows a success card once all permissions are granted).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showOnboarding()
        return true
    }

    // MARK: - Windows

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                onRelaunch: { [weak self] in self?.relaunch() },
                onPermissionsChanged: { [weak self] in
                    self?.restartHotkeyIfPossible()
                    // Mic may have just been granted — start instant capture now.
                    AppState.shared.refreshContinuousCapture()
                }
            )
            onboardingWindow = makeWindow(title: "LocalFlow Setup", width: 460, height: 540, content: view)
        }

        // Register (and prompt for) Input Monitoring as setup opens, so LocalFlow's row
        // exists in the pane before the user ever looks — no manual "+" needed. Fired here
        // (not at bare launch) so it doesn't stack on top of the microphone prompt.
        if !PermissionsManager.shared.inputMonitoringGranted {
            PermissionsManager.shared.requestInputMonitoring()
        }

        present(onboardingWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                onModelChanged: { AppState.shared.reloadEngine() },
                onHotkeyChanged: { [weak self] in
                    self?.hotkeyMonitor.restart()
                    AppState.shared.refreshHotkeyBinding()
                },
                onPartialsChanged: { AppState.shared.reloadPartials() },
                onCleanupChanged: { AppState.shared.warmCleanupModel() },
                onInstantCaptureChanged: { AppState.shared.refreshContinuousCapture() }
            )
            settingsWindow = makeWindow(title: "LocalFlow Settings", width: 520, height: 640, content: view)
        }
        present(settingsWindow)
    }

    private func makeWindow<Content: View>(title: String, width: CGFloat, height: CGFloat, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Hotkey recovery

    private func restartHotkeyIfPossible() {
        if PermissionsManager.shared.inputMonitoringGranted && !hotkeyMonitor.isRunning {
            hotkeyMonitor.restart()
        }
    }

    private func startHotkeyRetry() {
        hotkeyRetryTimer?.invalidate()
        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard PermissionsManager.shared.inputMonitoringGranted else { return }
                self.hotkeyMonitor.restart()
                if self.hotkeyMonitor.isRunning {
                    timer.invalidate()
                    self.hotkeyRetryTimer = nil
                }
            }
        }
    }

    // MARK: - Relaunch (used after granting permissions that require a restart)

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
