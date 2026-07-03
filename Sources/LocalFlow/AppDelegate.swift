import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyMonitor = HotkeyMonitor()
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var hotkeyRetryTimer: Timer?
    private var hudController: HUDController?

    /// Whether the app should show a Dock icon. Defaults to true when the key has
    /// never been set. Info.plist ships LSUIElement=true so a fresh process starts as
    /// an accessory (no Dock flash for users who turn this off); we promote to a
    /// regular app here at launch when the setting is on.
    static var showInDockSetting: Bool {
        if UserDefaults.standard.object(forKey: "showInDock") == nil { return true }
        return UserDefaults.standard.bool(forKey: "showInDock")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.showInDockSetting {
            NSApp.setActivationPolicy(.regular)
        }

        hotkeyMonitor.onKeyDown = { AppState.shared.startDictation() }
        hotkeyMonitor.onKeyUp = { AppState.shared.stopDictation() }
        hotkeyMonitor.onLockEngaged = { AppState.shared.lockDictation() }

        // A dictation blocked by a denied Microphone permission asks us to open
        // Setup so the user can turn it on (AppState can't reach the windows).
        AppState.shared.onNeedsMicrophoneSetup = { [weak self] in self?.showOnboarding() }

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
        // Self-heal a missing cleanup model: if Ollama is up but the model was
        // never pulled (the silent fresh-install failure), download it in the
        // background. Never blocks dictation; cleanup falls back to raw meanwhile.
        AppState.shared.healCleanupModelIfNeeded()

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

    /// Fired when the user clicks the Dock icon (when shown) or double-clicks the app
    /// in Finder/Launchpad. Opens the main window — the app's home for reviewing,
    /// re-copying, and correcting past dictations.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Shows or hides the Dock icon live from the Settings toggle. Switching to
    /// `.accessory` can drop key status and hide the app's windows, so re-activate and
    /// re-front the Settings window afterwards so the toggle doesn't appear to close it.
    func setDockVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Windows

    /// The main interface: the dictation-history browser. A single resizable
    /// window, lazily created and reused across reopens.
    func showMainWindow() {
        if mainWindow == nil {
            let view = MainWindowView(
                onOpenSettings: { [weak self] in self?.showSettings() },
                onOpenSetup: { [weak self] in self?.showOnboarding() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "LocalFlow"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 400)
            window.center()
            mainWindow = window
        }
        present(mainWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                onRelaunch: { [weak self] in self?.relaunch() },
                onPermissionsChanged: { [weak self] in
                    self?.restartHotkeyIfPossible()
                    // Mic may have just been granted. Route through the transition
                    // handler: on a fresh grant it rebuilds the audio engine so it
                    // doesn't keep feeding pre-grant silence; otherwise it just
                    // reconciles continuous capture as before.
                    AppState.shared.handleMicrophonePermissionChange()
                },
                onOpenMain: { [weak self] in
                    self?.showMainWindow()
                    // Setup is done — step aside for the app's home window.
                    self?.onboardingWindow?.orderOut(nil)
                }
            )
            onboardingWindow = makeWindow(title: "LocalFlow Setup", width: 460, height: 600, content: view)
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
                onCleanupChanged: {
                    // Fires for both the cleanup toggle and the model field: warm
                    // the model, and heal (download) it if it's now missing.
                    AppState.shared.warmCleanupModel()
                    AppState.shared.healCleanupModelIfNeeded()
                },
                onInstantCaptureChanged: { AppState.shared.refreshContinuousCapture() },
                onDockVisibilityChanged: { [weak self] visible in self?.setDockVisible(visible) }
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
