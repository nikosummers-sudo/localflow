import AppKit
import LocalFlowKit
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
        hotkeyMonitor.onCancel = { AppState.shared.cancelDictation() }
        // A refused start (permissions, audio error) resets the gesture machine so
        // a Space press can't latch a "recording" that never began.
        AppState.shared.onDictationFailedToStart = { [weak self] in
            self?.hotkeyMonitor.resetGesture()
        }

        // Surface "what changed" after an auto-update: the updater swaps builds
        // silently, so the first launch of a new build says so in the menu bar.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let seen = UserDefaults.standard.string(forKey: "lastSeenBuild")
        if let seen, seen != build {
            AppState.shared.showNote("Updated to v\(short) (build \(build))")
        }
        UserDefaults.standard.set(build, forKey: "lastSeenBuild")

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

        if tapStarted {
            // Recovered (or never stuck) — clear the legacy one-time relaunch guard.
            UserDefaults.standard.removeObject(forKey: Self.pendingTapRelaunchKey)
        } else {
            // Without Input Monitoring the tap can't be created; poll and start it
            // once granted. The retry loop also detects the macOS "grant doesn't
            // apply to the running process" wedge and relaunches to cure it.
            startHotkeyRetry()
        }
        syncHotkeyHealth()
    }

    /// The macOS quirk: the FIRST time Input Monitoring is granted, the already-
    /// running process often still can't create its event tap — only a fresh
    /// process can. The retry loop watches for that exact state (grant present,
    /// restart still failing) and calls this. One auto-relaunch per process, and
    /// only if the LAST auto-relaunch was over 10 minutes ago (persisted timestamp,
    /// so a genuinely-broken machine never relaunch-loops). If a relaunch didn't
    /// cure it, we stop and surface onboarding guidance instead.
    private static let pendingTapRelaunchKey = "pendingTapRelaunch" // legacy boolean, cleared on success
    private static let tapRelaunchAtKey = "tapRelaunchAt"
    private var attemptedAutoRelaunch = false
    private var shownStuckGuidance = false
    private func attemptTapAutoRelaunch() {
        guard !attemptedAutoRelaunch else { return }
        attemptedAutoRelaunch = true
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.tapRelaunchAtKey)
        if now - last < 600 {
            // The previous process already auto-relaunched into this one and the tap
            // is STILL dead — relaunching again won't help. Guide the user instead.
            if !shownStuckGuidance {
                shownStuckGuidance = true
                EventLog.log("tap.autorelaunch", ["result": "stillStuck-showingGuidance"])
                showOnboarding()
            }
            return
        }
        UserDefaults.standard.set(now, forKey: Self.tapRelaunchAtKey)
        EventLog.log("tap.autorelaunch", ["result": "relaunching"])
        relaunch()
    }

    /// Publishes the "wedged" state — Input Monitoring granted but no tap — so the
    /// menu bar can show a warning with a one-click fix instead of looking normal
    /// while the shortcut is silently dead.
    private func syncHotkeyHealth() {
        let wedged = !hotkeyMonitor.isRunning && PermissionsManager.shared.inputMonitoringGranted
        AppState.shared.setHotkeyActive(!wedged)
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
            // Remember size/position across launches (overrides the center()
            // default once a saved frame exists).
            window.setFrameAutosaveName("LocalFlowMain")
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
                    // Restarting the tap resets its gesture machine — finish (not
                    // discard) any live recording first so the user's words land.
                    if AppState.shared.status.isRecording { AppState.shared.stopDictation() }
                    self?.hotkeyMonitor.restart()
                    self?.syncHotkeyHealth()
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
                onDockVisibilityChanged: { [weak self] visible in self?.setDockVisible(visible) },
                onInputDeviceChanged: { AppState.shared.reconfigureInputDevice() }
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
        syncHotkeyHealth()
    }

    /// Consecutive retry ticks where Input Monitoring was granted but the tap still
    /// failed to create. Three in a row (~6 s of granted-but-dead) is the wedge.
    private var grantedTapFailures = 0

    private func startHotkeyRetry() {
        hotkeyRetryTimer?.invalidate()
        grantedTapFailures = 0
        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard PermissionsManager.shared.inputMonitoringGranted else {
                    self.grantedTapFailures = 0
                    return
                }
                self.hotkeyMonitor.restart()
                self.syncHotkeyHealth()
                if self.hotkeyMonitor.isRunning {
                    timer.invalidate()
                    self.hotkeyRetryTimer = nil
                    self.grantedTapFailures = 0
                    UserDefaults.standard.removeObject(forKey: Self.pendingTapRelaunchKey)
                } else {
                    // Granted, restarted, still no tap: the running process can't use
                    // the fresh grant (macOS applies it only to NEW processes). After
                    // three consecutive failures, relaunch to pick the grant up.
                    self.grantedTapFailures += 1
                    if self.grantedTapFailures >= 3 {
                        self.attemptTapAutoRelaunch()
                    }
                }
            }
        }
    }

    // MARK: - Relaunch (used after granting permissions that require a restart,
    // and by the menu bar's "Fix Now" button when the shortcut is wedged)

    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
