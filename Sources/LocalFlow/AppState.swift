import AppKit
import Foundation
import LocalFlowKit
import LocalFlowStreaming
import SwiftUI

/// Default model variant. Overridable via the "modelName" user default (Settings).
let defaultModelName = "large-v3_turbo"

private func configuredModelName() -> String {
    UserDefaults.standard.string(forKey: "modelName") ?? defaultModelName
}

private func restoreClipboardEnabled() -> Bool {
    // Default on when the key has never been set.
    if UserDefaults.standard.object(forKey: "restoreClipboard") == nil { return true }
    return UserDefaults.standard.bool(forKey: "restoreClipboard")
}

/// Instant capture keeps the mic warm so dictation starts instantly and never
/// clips the first words. Default on when the key has never been set.
private func instantCaptureEnabled() -> Bool {
    if UserDefaults.standard.object(forKey: "instantCapture") == nil { return true }
    return UserDefaults.standard.bool(forKey: "instantCapture")
}

/// Whether spoken voice commands ("new line", "scratch that", …) are interpreted.
/// Default on when the key has never been set.
func voiceCommandsEnabled() -> Bool {
    if UserDefaults.standard.object(forKey: "voiceCommandsEnabled") == nil { return true }
    return UserDefaults.standard.bool(forKey: "voiceCommandsEnabled")
}

/// Owns the dictation pipeline and the observable status shown in the menu bar.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case idle
        /// Optional detail overrides the default "Loading model…" copy — used to
        /// say "Downloading speech model… (first run)" during the initial fetch.
        case loadingModel(String?)
        case recording
        case recordingLocked
        case transcribing
        case cleaning
        case pasting
        case noInputField
        case error(String)

        var menuText: String {
            switch self {
            case .idle: return "Ready"
            case .loadingModel(let detail): return detail ?? "Loading model…"
            case .recording: return "Recording…"
            case .recordingLocked: return "Recording (locked)"
            case .transcribing: return "Transcribing…"
            case .cleaning: return "Cleaning…"
            case .pasting: return "Inserting text…"
            case .noInputField: return "No input field — copied to clipboard"
            case .error(let message): return message
            }
        }

        /// Menu-bar glyph. A waveform identity (not a mic) so it never reads as
        /// macOS's own microphone-in-use indicator. These render as template
        /// (monochrome) images — the menu bar owns their colour, so we don't tint.
        var symbolName: String {
            switch self {
            case .idle: return "waveform.circle"
            case .recording: return "waveform.circle.fill"
            case .recordingLocked: return "lock.circle.fill"
            case .loadingModel: return "arrow.down.circle"
            case .transcribing: return "ellipsis.circle"
            case .cleaning: return "wand.and.stars"
            case .pasting: return "doc.on.clipboard"
            case .noInputField: return "doc.on.clipboard"
            case .error: return "exclamationmark.triangle"
            }
        }

        /// True while audio is being captured, whether held or locked hands-free.
        var isRecording: Bool { self == .recording || self == .recordingLocked }
    }

    @Published private(set) var status: Status = .idle

    /// Background (non-dictation) activity surfaced in the menu bar only — never
    /// in the HUD, and never touching the dictation status machine. Used for the
    /// self-healing cleanup-model download so it can run while dictation proceeds
    /// normally underneath it.
    enum BackgroundActivity: Equatable {
        /// Persists for the whole download; shown in the menu whenever idle.
        case downloadingCleanupModel
        /// A transient one-liner (e.g. "AI cleanup ready") that auto-clears.
        case note(String)
    }

    @Published private(set) var backgroundActivity: BackgroundActivity?
    private var backgroundActivityTask: Task<Void, Never>?

    /// The current dictation shortcut, mirrored here so menu/HUD copy updates reactively
    /// when the user changes it in Settings. Refreshed via `refreshHotkeyBinding()`.
    @Published private(set) var hotkeyBinding: HotkeyBinding = HotkeyBinding.load()

    /// The menu-bar status line. Locked recording is shown with the shortcut-specific
    /// finish gesture ("tap Right Option to finish", "press ⌘⇧D to finish").
    var statusMenuText: String {
        if status == .recordingLocked { return hotkeyBinding.lockedStatusText }
        // While idle, surface background activity (e.g. the cleanup-model download)
        // in the menu. Any real dictation status always takes precedence.
        if status == .idle, let activity = backgroundActivity {
            switch activity {
            case .downloadingCleanupModel: return "Downloading AI cleanup model…"
            case .note(let text): return text
            }
        }
        return status.menuText
    }

    /// Re-reads the persisted binding after the user changes it in Settings.
    func refreshHotkeyBinding() {
        hotkeyBinding = HotkeyBinding.load()
    }

    /// False when Input Monitoring is granted but the event tap is dead — the macOS
    /// "grant doesn't apply to the running process" wedge. Drives the menu bar's
    /// warning icon and "Fix Now" button so the state is never silently invisible.
    /// (Stays true while permissions are simply not granted yet; onboarding owns
    /// that flow.)
    @Published private(set) var hotkeyActive: Bool = true

    func setHotkeyActive(_ active: Bool) {
        guard hotkeyActive != active else { return }
        hotkeyActive = active
    }

    /// Live, display-only preview text produced during recording. Never used for
    /// the final inserted text — that always comes from the main engine.
    @Published var partialText: String = ""

    /// Normalized 0–1 microphone level for the HUD's voice-reactive animation.
    /// Fed from the recorder's audio-thread callback (throttled ~15 Hz).
    @Published var audioLevel: Float = 0

    /// True while recording once ~3 s have elapsed with NO audio above the speech
    /// level — drives the HUD's "Can't hear you" hint. Reverts the instant speech
    /// is detected. Meaningless (always false) outside a recording.
    @Published private(set) var showNoAudioHint: Bool = false

    /// Invoked when a dictation attempt is blocked because the Microphone
    /// permission is denied — asks the app to open the Setup window so the user can
    /// fix it. Wired by AppDelegate (which owns the windows) at launch.
    var onNeedsMicrophoneSetup: (() -> Void)?

    /// Shown (single-pass and streaming) when a recording contained no audible
    /// speech — the true-silence case behind the "it only typed 'you'" reports.
    private let silenceMessage =
        "Couldn't hear you — check your mic input (System Settings → Sound → Input) and the pill's bars while you speak"

    /// The final text of the most recent dictation (post-cleanup), retained so
    /// the user can always re-copy it — the "Copy Last Transcript" safety net.
    @Published private(set) var lastTranscript: String = ""

    /// Bumped whenever a dictation is appended to the history store, so an open
    /// main window can refresh its list without polling.
    @Published private(set) var historyRevision: Int = 0

    /// The most recent app (other than LocalFlow itself) to come to the
    /// foreground. Used by the Settings "Apps" tab to seed a rule for the app the
    /// user was just in, since opening Settings makes LocalFlow frontmost.
    @Published private(set) var lastForegroundBundleID: String?
    @Published private(set) var lastForegroundName: String?

    /// The app that was frontmost when the CURRENT dictation started. Rules bind
    /// to where the user began dictating, so this is captured at start and used
    /// for the whole dictation's cleanup/tone decisions. The name is also recorded
    /// on the saved history entry.
    private var activeAppBundleID: String?
    private var activeAppName: String?

    /// Duration (seconds) of the most recent recording, stamped onto its history
    /// record. Set in `stopDictation` before the transcription branches run.
    private var lastRecordingDuration: Double = 0

    private let recorder = AudioRecorder()
    /// The single main engine, wrapped so a streaming chunk, the post-release
    /// tail, and any other caller never transcribe concurrently.
    private var engine: SerialTranscriptionEngine
    /// Whether the main engine has ever finished loading. Distinguishes the
    /// first-run model download (slow, ~1.6 GB) from a later reload of a cached
    /// model, so the loading status can be honest about which is happening.
    private var engineHasLoadedOnce = false
    private let inserter = TextInserter()
    private let cleaner = TranscriptCleaner()
    private var partials: PartialTranscriber?

    // Streaming pipeline, live only during a dictation.
    private var incremental: IncrementalTranscriber?
    private var liveSource: LiveSampleSource?
    private var supervisorTask: Task<Void, Never>?

    private var errorResetTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?

    /// Whether any frame above the speech level has arrived during THIS dictation.
    /// Cheaply updated from the throttled `onLevel` stream; drives the live hint.
    private var heardAudioThisDictation = false
    private var noAudioHintTask: Task<Void, Never>?
    /// How long to wait after start before showing the "Can't hear you" hint.
    private let noAudioHintDelay: TimeInterval = 3.0
    /// Normalized (0–1) `audioLevel` above which real input is considered present.
    /// ≈0.15 maps to ~0.0075 linear RMS through the recorder's -50…0 dB window —
    /// just above `AudioGate.speechThreshold` (0.006), so ambient noise won't clear
    /// the hint but a real voice will.
    private let audioHeardLevel: Float = 0.15

    /// Last-seen Microphone-permission grant, to detect a false→true transition.
    /// A grant that lands while the audio engine is already running leaves that
    /// engine feeding pre-grant silence until it's rebuilt — the case FIX 5 heals.
    private var lastKnownMicGranted = false
    /// Set when a mic grant is detected mid-dictation; the engine restart is then
    /// deferred to the next `stopDictation` so a live capture isn't disturbed.
    private var pendingMicRestart = false

    private let minRecordingSeconds: TimeInterval = 0.3
    // Streaming makes long recordings cheap, so the hands-free limit is generous.
    private let maxRecordingSeconds: TimeInterval = 600

    private init() {
        AppState.seedDefaultAppRules()
        engine = SerialTranscriptionEngine(engine: WhisperKitEngine(model: configuredModelName()))
        // Seed the transition tracker with the launch-time grant so a returning
        // (already-granted) user never triggers a spurious engine restart.
        lastKnownMicGranted = PermissionsManager.shared.microphoneGranted
        // The recorder invokes this from the audio tap thread; hop to the main
        // actor to publish so the HUD's @Published binding stays valid.
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.updateAudioLevel(level) }
        }
        // Selected mic vanished (USB unplugged, Bluetooth dropped): capture falls
        // back to the system default — tell the user instead of silently recording
        // through a different microphone.
        recorder.onInputDeviceFallback = { [weak self] name in
            Task { @MainActor in
                self?.setBackgroundActivity(.note("Selected mic unavailable — using \(name)"))
            }
        }
        observeForegroundApp()
    }

    /// Surfaces a transient menu-bar note (auto-clears after 5s). For app-level
    /// events like "Updated to v0.4".
    func showNote(_ text: String) {
        setBackgroundActivity(.note(text))
    }

    /// Tracks the last non-LocalFlow app to activate, so the Settings "Apps" tab
    /// can offer a rule for it even after LocalFlow itself becomes frontmost.
    private func observeForegroundApp() {
        let selfID = Bundle.main.bundleIdentifier
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let id = app.bundleIdentifier, id != selfID
            else { return }
            let name = app.localizedName ?? id
            MainActor.assumeIsolated {
                self?.lastForegroundBundleID = id
                self?.lastForegroundName = name
            }
        }

        // Sleep/wake: AVAudioEngine routinely stops across a lid-close and the
        // config-change notification is NOT guaranteed to fire on wake — without
        // this, every post-wake dictation captures silence until relaunch.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    /// Rebuilds audio capture after the machine wakes from sleep. Never disturbs
    /// a live dictation (vanishingly unlikely straight after wake anyway).
    private func handleWake() {
        EventLog.log("system.wake")
        guard !status.isRecording else { return }
        recorder.handleWake()
        refreshContinuousCapture()
    }

    // MARK: - Model lifecycle

    /// Loads (and if needed downloads) the model. Safe to call at launch.
    func preloadEngine() async {
        // First run downloads ~1.6 GB, so say so; a reload of an already-cached
        // model is quick and keeps the plain "Loading model…" copy.
        setStatus(.loadingModel(engineHasLoadedOnce ? nil : "Downloading speech model… (first run)"))
        do {
            try await engine.preload()
            engineHasLoadedOnce = true
            if let note = await engine.statusNote {
                // A fallback to a smaller model is a WORKING state — surface it as
                // an informational note, not a red error.
                setBackgroundActivity(.note(note))
            }
            if case .loadingModel = status {
                setStatus(.idle)
            }
        } catch {
            setStatus(.error("Model load failed: \(error.localizedDescription)"))
        }
    }

    /// Rebuilds the engine after the model choice changes, then reloads.
    func reloadEngine() {
        engine = SerialTranscriptionEngine(engine: WhisperKitEngine(model: configuredModelName()))
        engineHasLoadedOnce = false
        Task { await preloadEngine() }
    }

    /// Thread-safe resume-once guard for hand-rolled continuation races.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        /// Returns true exactly once, for exactly one caller.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Whether the configured model's files already exist on disk — a cached
    /// model loads in well under 90s, so a longer wait means the load is hung,
    /// not slow. (Heuristic path; WhisperKit's layout, verified from source.)
    private func modelLikelyCached() -> Bool {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(configuredModelName())")
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        // A folder left by an INTERRUPTED first download is not a cached model —
        // it must get the full download budget so the resume can finish, or the
        // short budget would timeout-loop forever. The engine drops a sentinel
        // into the folder only after a fully successful load.
        return WhisperKitEngine.modelVerified(configuredModelName())
    }

    /// Shows the honest loading status until the main engine is ready, then flips
    /// to .transcribing and returns true. The wait is BOUNDED: a launch-time load
    /// that hung (e.g. a stalled network check inside WhisperKit) would otherwise
    /// wedge the serial engine chain forever, silently eating every dictation.
    /// On timeout or failure this surfaces an error, abandons the wedged chain
    /// for a fresh engine (reloadEngine), and returns false so the caller bails.
    private func ensureReadyThenTranscribing() async -> Bool {
        if await engine.isReady {
            setStatus(.transcribing)
            return true
        }
        setStatus(.loadingModel(engineHasLoadedOnce ? nil : "Downloading speech model… (first run)"))
        let budget: Double = modelLikelyCached() ? 90 : 900  // download runs need real time
        let engineRef = engine
        // First-resumer-wins race. NOT withTaskGroup: a task group refuses to
        // return until every child finishes, so a hung preload child would hold
        // the "timed-out" group hostage — the timeout could never escape the very
        // hang it exists to escape. The losing task here is simply abandoned
        // (the wedged chain is discarded by reloadEngine below anyway).
        let raceWon = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resumed = ResumeOnce()
            Task {
                let ok = (try? await engineRef.preload()) != nil
                if resumed.claim() { cont.resume(returning: ok) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                if resumed.claim() { cont.resume(returning: false) }
            }
        }
        if raceWon, await engine.isReady {
            engineHasLoadedOnce = true
            EventLog.log("model.load", ["result": "ok"])
            setStatus(.transcribing)
            return true
        }
        EventLog.log("model.load", [
            "result": raceWon ? "failed" : "timeout",
            "budgetS": String(Int(budget)),
        ])
        setStatus(.error("Speech model didn't load — retrying with a fresh engine. Dictate again in a moment."))
        // The old chain (and anything hung inside it) is abandoned, not repaired.
        reloadEngine()
        return false
    }

    // MARK: - Instant capture (keeps the mic warm)

    /// Starts or stops continuous instant-capture to match the setting and the
    /// microphone permission. Safe to call repeatedly — at launch, when the mic
    /// permission is granted, and when the Settings toggle changes. Never disturbs
    /// an in-progress dictation.
    func refreshContinuousCapture() {
        guard !status.isRecording else { return }
        let want = instantCaptureEnabled() && PermissionsManager.shared.microphoneGranted
        if want {
            if !recorder.isCapturing {
                // If the engine can't start (e.g. no mic yet), fall back silently
                // to legacy per-recording capture — dictation still works.
                try? recorder.startContinuousCapture()
            }
        } else if recorder.isCapturing {
            recorder.stopContinuousCapture()
        }
    }

    /// Rebuilds capture against a newly-chosen input device (Settings mic picker).
    func reconfigureInputDevice() {
        guard !status.isRecording else { return }
        if recorder.isCapturing {
            recorder.reconfigureInputDevice()
        } else {
            // Not continuously capturing (instant capture off / mic ungranted):
            // the next dictation opens the engine and picks up the new device.
            refreshContinuousCapture()
        }
    }

    /// Reacts to a Microphone-permission change (called from every permission hook:
    /// onboarding's poll, and the in-dictation request prompt). On a false→true
    /// transition the audio engine — if it was already running — is still feeding
    /// pre-grant silence, so we rebuild it against the now-granted mic. Idempotent:
    /// a non-transition (e.g. an Input-Monitoring grant that also fires this) just
    /// reconciles capture to the current state, exactly as before.
    func handleMicrophonePermissionChange() {
        let granted = PermissionsManager.shared.microphoneGranted
        let transitionedToGranted = granted && !lastKnownMicGranted
        lastKnownMicGranted = granted

        guard transitionedToGranted else {
            refreshContinuousCapture()
            return
        }
        // Don't rebuild under a live dictation — defer to the next stop. (Under the
        // start-time mic gate this is nearly unreachable, but it keeps the restart
        // unconditionally safe.)
        if status.isRecording {
            pendingMicRestart = true
            return
        }
        restartCaptureAfterGrant()
    }

    /// Rebuilds capture with a fresh engine after a mic grant. If capture is already
    /// running it's the stale, silence-delivering engine → tear down and restart it;
    /// if it isn't running (the usual case, since capture is gated on the grant),
    /// start it fresh now. A no-op when instant capture is off — legacy per-dictation
    /// capture then starts its own fresh engine on the next press, post-grant.
    private func restartCaptureAfterGrant() {
        if recorder.isCapturing {
            // recorder.restartContinuousCapture logs its own engine.restart outcome.
            try? recorder.restartContinuousCapture()
        } else {
            EventLog.log("engine.restart", ["reason": "mic-grant", "result": "fresh-start"])
            refreshContinuousCapture()
        }
    }

    // MARK: - Live partials & cleanup warm-up

    /// Whether the optional live text preview is on. Default OFF — the pill's
    /// voice animation is always shown during dictation, but the partial-text
    /// tail (and its transcriber) only run when the user opts in.
    private func showLivePreview() -> Bool {
        UserDefaults.standard.bool(forKey: "showLivePreview")
    }

    /// Loads the preview model, but only if live preview is enabled. Call at
    /// launch AFTER the main engine has loaded so the two don't compete. When
    /// preview is off the transcriber is never built, saving memory/compute.
    func preloadPartialsIfEnabled() async {
        guard showLivePreview() else { return }
        if partials == nil { partials = PartialTranscriber() }
        await partials?.preload()
    }

    /// Tears down and (if still enabled) rebuilds the preview transcriber after a
    /// Settings change to the live-preview toggle or preview model.
    func reloadPartials() {
        Task {
            await partials?.stop()
            partials = nil
            await preloadPartialsIfEnabled()
        }
    }

    /// Fire-and-forget: warm the Ollama cleanup model into memory so the first
    /// real cleanup isn't a cold start. No-op when cleanup is disabled.
    func warmCleanupModel() {
        guard TranscriptCleaner.isEnabled else { return }
        let model = TranscriptCleaner.model
        Task.detached { await OllamaClient().preload(model: model) }
    }

    /// Guards against two heals running at once (launch + a Settings change).
    private var cleanupHealTask: Task<Void, Never>?

    /// Self-heals a missing cleanup model. When cleanup is enabled and the Ollama
    /// server is reachable but doesn't have the configured model, this downloads
    /// it in the background so cleanup starts working without the user ever
    /// touching a terminal — the exact silent failure a fresh install hit.
    ///
    /// Fire-and-forget and non-blocking: dictation keeps working throughout, with
    /// cleanup falling back to inserting the raw transcript until the model lands.
    /// No-op when cleanup is off or the server is down (cleanup just degrades
    /// gracefully, as before). Safe to call repeatedly — at launch and whenever
    /// the cleanup model changes in Settings; a newer call supersedes an older one.
    func healCleanupModelIfNeeded() {
        guard TranscriptCleaner.isEnabled else {
            // Cleanup was turned off — drop any stale download indicator.
            cleanupHealTask?.cancel()
            cleanupHealTask = nil
            if backgroundActivity != nil { setBackgroundActivity(nil) }
            return
        }
        cleanupHealTask?.cancel()
        let model = TranscriptCleaner.model
        cleanupHealTask = Task { [weak self] in
            let client = OllamaClient()
            // nil = server unreachable → leave it alone (cleanup degrades to raw).
            guard let available = await client.availableModels() else { return }
            if OllamaClient.modelListContains(available, model) {
                // Already present — clear any leftover download indicator.
                self?.setBackgroundActivity(nil)
                return
            }
            guard !Task.isCancelled else { return }

            self?.setBackgroundActivity(.downloadingCleanupModel)
            do {
                try await client.pullModel(model)
                // Confirm it actually landed before declaring success.
                let ready = await client.hasModel(model)
                self?.setBackgroundActivity(
                    ready ? .note("AI cleanup ready")
                          : .note("AI cleanup unavailable — dictation still works"))
            } catch {
                // A cancellation means a newer heal took over — say nothing.
                if Task.isCancelled { return }
                // Name the model: a typo in the Settings field should be
                // self-diagnosing, not a silent fallback to raw text forever.
                self?.setBackgroundActivity(.note("Cleanup model “\(model)” not found — inserting raw text"))
            }
        }
    }

    /// Sets the menu-bar background activity. A `.note` auto-clears after 5s (like
    /// the transient error notes); the `.downloadingCleanupModel` indicator
    /// persists until explicitly replaced or cleared.
    private func setBackgroundActivity(_ activity: BackgroundActivity?) {
        backgroundActivity = activity
        backgroundActivityTask?.cancel()
        backgroundActivityTask = nil
        guard case .note = activity else { return }
        backgroundActivityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .note = self.backgroundActivity { self.backgroundActivity = nil }
        }
    }

    private func startPartials() {
        guard showLivePreview() else { return }
        if partials == nil { partials = PartialTranscriber() }
        partials?.start(recorder: recorder) { [weak self] text in
            self?.partialText = text
        }
    }

    // MARK: - Dictation pipeline

    /// True while a released dictation is still being processed (transcribe →
    /// clean → paste). Guards startDictation against re-entering the pipeline —
    /// notably during a first-run model download, where dictation #1 parks in
    /// .loadingModel (which the status guard below deliberately allows, so users
    /// CAN dictate while the launch preload runs) and #2 would otherwise overwrite
    /// its streaming handles and interleave two pipelines.
    private var pipelineActive = false
    /// Set by cancelDictation() and the stuck-state watchdog; in-flight pipeline
    /// stages check it and unwind without inserting.
    private var pipelineCancelled = false
    /// Recovery net of last resort for processing states (see setStatus).
    private var processingWatchdogTask: Task<Void, Never>?

    func startDictation() {
        // A pipeline that's been cancelled/watchdogged is already abandoned — it
        // unwinds inertly, so a fresh dictation may start over it.
        guard !pipelineActive || pipelineCancelled else { return }
        switch status {
        case .recording, .recordingLocked, .transcribing, .cleaning, .pasting:
            return
        default:
            break
        }

        // Microphone-permission gate. A denied or not-yet-granted mic doesn't
        // error on macOS — it feeds zeros — so without this we'd "record" silence
        // and let Whisper hallucinate "you"/"Thank you." from it. Refuse to record
        // until the mic is actually granted.
        switch PermissionsManager.shared.microphoneStatus {
        case .notDetermined:
            // Trigger the system prompt, but don't record this attempt — capture
            // would be silent until the user answers. On grant this routes through
            // the transition handler, which starts capture with a FRESH engine so
            // the just-granted mic delivers real audio (not pre-grant silence).
            PermissionsManager.shared.requestMicrophone { [weak self] _ in
                Task { @MainActor in self?.handleMicrophonePermissionChange() }
            }
            EventLog.log("permission.blocked", ["permission": "microphone", "status": "notDetermined"])
            setStatus(.error("Grant Microphone access, then try again"))
            return
        case .denied:
            EventLog.log("permission.blocked", ["permission": "microphone", "status": "denied"])
            setStatus(.error("Microphone permission is off — enable it in the Setup window"))
            onNeedsMicrophoneSetup?()
            return
        case .granted:
            break
        }

        do {
            try recorder.beginRecording()
            captureActiveApp()
            partialText = ""
            pipelineCancelled = false
            setStatus(.recording)
            startAutoStop()
            startNoAudioHint()
            startPartials()
            startStreaming()

            // Diagnostics only (no transcript content): the input mode and the mic
            // the OS handed us. A wrong/unexpected device or sample rate here is a
            // strong tell for the "it only heard silence" reports.
            let input = recorder.inputDescription()
            EventLog.log("dictation.start", [
                "mode": hotkeyBinding.isHold ? "hold" : "toggle",
                "device": input.deviceName ?? "unknown",
                "inputHz": String(format: "%.0f", input.sampleRate),
            ])
        } catch {
            EventLog.log("dictation.start", ["result": "error", "error": String(describing: error)])
            setStatus(.error(error.localizedDescription))
            // The hotkey layer advanced to "recording" on key-down; tell it the
            // start didn't take so a Space/lock gesture can't latch a dead recording.
            onDictationFailedToStart?()
        }
    }

    /// Fired when a hotkey-triggered start is refused (permissions, audio error),
    /// so the hotkey state machine can reset instead of believing it's recording.
    var onDictationFailedToStart: (() -> Void)?

    /// Abandons the current dictation wherever it is: a live recording is
    /// discarded, in-flight processing unwinds without inserting. Driven by Esc
    /// (while recording), the menu-bar Cancel item, and the stuck-state watchdog.
    func cancelDictation() {
        guard status != .idle else { return }
        EventLog.log("dictation.cancel", ["from": status.isRecording ? "recording" : "processing"])
        pipelineCancelled = true
        autoStopTask?.cancel()
        autoStopTask = nil
        if status.isRecording {
            _ = recorder.endRecording()
            if pendingMicRestart {
                pendingMicRestart = false
                restartCaptureAfterGrant()
            }
        }
        supervisorTask?.cancel()
        liveSource = nil
        incremental = nil
        supervisorTask = nil
        let p = partials
        Task { await p?.stop() }
        partialText = ""
        setStatus(.idle)
    }

    /// Records which app is frontmost as dictation begins. LocalFlow is a menu-bar
    /// app and never steals focus, so the frontmost app here is the one the user
    /// is dictating into — the correct binding for per-app rules.
    private func captureActiveApp() {
        let front = NSWorkspace.shared.frontmostApplication
        activeAppBundleID = front?.bundleIdentifier
        activeAppName = front?.localizedName
    }

    // MARK: - Per-app rules & cleanup context

    /// One-time seeding of rules for apps known to hide their inputs from
    /// macOS accessibility. Runs once ever (flagged), so a user who deletes
    /// the seeded rule doesn't get it back on every launch.
    static func seedDefaultAppRules() {
        let flag = "seededClaudeInsertionRule"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let claudeID = "com.anthropic.claudefordesktop"
        guard LocalFlowConfig.shared.rule(forBundleID: claudeID) == nil else { return }
        var rules = LocalFlowConfig.shared.appRules
        rules.append(AppRule(bundleID: claudeID, appName: "Claude", insertionMode: "paste"))
        LocalFlowConfig.shared.appRules = rules
        EventLog.log("apps.seeded", ["bundle": claudeID, "insertion": "paste"])
    }

    private func currentAppRule() -> AppRule? {
        guard let id = activeAppBundleID else { return nil }
        return LocalFlowConfig.shared.rule(forBundleID: id)
    }

    /// The cleanup toggle for this dictation: a per-app override wins, otherwise
    /// the global setting.
    private func effectiveCleanupEnabled() -> Bool {
        if let override = currentAppRule()?.cleanupEnabled { return override }
        return TranscriptCleaner.isEnabled
    }

    /// The user's chosen cleanup style. `.clean` (safe, default) fixes fillers
    /// and punctuation; `.refine` reformats rambling speech so the point lands.
    private func cleanupMode() -> CleanupMode {
        CleanupMode(rawValue: UserDefaults.standard.string(forKey: "cleanupMode") ?? "") ?? .clean
    }

    /// Builds the cleanup system-prompt context for this dictation: personal
    /// vocabulary, the active app's tone addendum, whether voice-command
    /// placeholders must be preserved, and the cleanup style. `forceCleanMode`
    /// pins `.clean` for the streaming per-chunk cleaner — refining a 10-second
    /// window in isolation would reformat fragments incoherently; refine only
    /// makes sense over the full assembled text.
    private func makeCleanupContext(forceCleanMode: Bool = false) -> CleanupContext {
        CleanupContext(
            vocabularyTerms: LocalFlowConfig.shared.currentTerms(),
            toneAddendum: currentAppRule()?.toneAddendum,
            includePlaceholderRule: voiceCommandsEnabled(),
            mode: forceCleanMode ? .clean : cleanupMode()
        )
    }

    /// Latches an in-progress hold recording into hands-free (locked) mode. The
    /// recorder and auto-stop timer are untouched — only the surfaced status changes.
    func lockDictation() {
        guard status == .recording else { return }
        EventLog.log("dictation.lock")
        setStatus(.recordingLocked)
    }

    /// Spins up the streaming supervisor for this dictation: it transcribes and
    /// cleans whole chunks while the user keeps talking, so key-release only has
    /// the short tail left to process.
    private func startStreaming() {
        let source = LiveSampleSource(recorder: recorder)
        let transcriber = IncrementalTranscriber(
            engine: engine,
            cleanupEnabled: effectiveCleanupEnabled(),
            voiceCommandsEnabled: voiceCommandsEnabled(),
            cleanupContext: makeCleanupContext(forceCleanMode: true)
        )
        liveSource = source
        incremental = transcriber
        supervisorTask = Task { await transcriber.runSupervisor(source: source) }
    }

    func stopDictation() {
        guard status.isRecording else { return }
        autoStopTask?.cancel()
        autoStopTask = nil

        let finalSamples = recorder.endRecording()
        let duration = Double(finalSamples.count) / AudioRecorder.targetSampleRate
        lastRecordingDuration = duration

        // Diagnostics: peak input level over the whole recording is the single most
        // telling number for a silence report (0 → the mic delivered nothing).
        EventLog.log("dictation.stop", [
            "durationS": String(format: "%.2f", duration),
            "samples": String(finalSamples.count),
            "maxRMS": String(format: "%.4f", AudioGate.maxFrameRMS(finalSamples, sampleRate: AudioRecorder.targetSampleRate)),
        ])

        // A mic grant that landed mid-dictation deferred its engine rebuild to here
        // (this recording used the pre-grant engine, so it may be silent — the
        // silence guard covers that — but the NEXT one must use a fresh engine).
        if pendingMicRestart {
            pendingMicRestart = false
            restartCaptureAfterGrant()
        }

        // Detach the streaming handles for this dictation.
        let source = liveSource
        let transcriber = incremental
        let supervisor = supervisorTask
        liveSource = nil
        incremental = nil
        supervisorTask = nil

        guard duration >= minRecordingSeconds else {
            supervisor?.cancel()
            Task {
                _ = await supervisor?.value
                await partials?.stop()
            }
            partialText = ""
            setStatus(.idle)
            return
        }

        // Immediate feedback on release. ensureReadyThenTranscribing() below turns
        // this into the honest loading/transcribing status once the engine state is
        // known — critical on first run, when the speech model is still downloading
        // and a bare "Transcribing…" would read as a multi-minute hang.
        setStatus(engineHasLoadedOnce ? .transcribing : .loadingModel("Downloading speech model… (first run)"))
        Task {
            pipelineActive = true
            defer { pipelineActive = false }

            // Finish any in-flight partial before the authoritative final pass so
            // the two never run concurrently.
            await partials?.stop()
            EventLog.log("pipeline.stage", ["at": "partialsStopped"])

            // Stop the supervisor and let any in-flight chunk finish committing so
            // `committedChunkCount` and the tail range are final.
            supervisor?.cancel()
            _ = await supervisor?.value
            EventLog.log("pipeline.stage", ["at": "supervisorDone"])
            guard !pipelineCancelled else { partialText = ""; return }

            // Never show "Transcribing…" while the model is still loading: surface
            // the loading status and wait (bounded) for the engine to be ready.
            // A hung load self-heals via a fresh engine; this dictation is lost
            // but the error says so and the next one works.
            guard await ensureReadyThenTranscribing() else {
                partialText = ""
                return
            }
            EventLog.log("pipeline.stage", ["at": "engineReady"])

            guard let transcriber, let source else {
                EventLog.log("pipeline.stage", ["at": "singlePass.noStreamHandles"])
                await runTranscription(finalSamples)
                return
            }

            let committed = await transcriber.committedChunkCount
            EventLog.log("pipeline.stage", ["at": "committedCount", "n": String(committed)])
            guard committed > 0 else {
                // Released before the first chunk committed → EXACTLY the existing
                // single-pass path (one STT + one cleanup).
                await runTranscription(finalSamples)
                return
            }

            // Streaming path: only the short tail is left to transcribe + clean.
            source.finalize(with: finalSamples)
            await transcriber.transcribeTail(source: source)

            // Silence guard: if not one chunk or the tail cleared the speech gate,
            // the whole recording was silent (denied/muted/wrong mic). Surface the
            // hint instead of inserting nothing — matches the single-pass path.
            guard await transcriber.heardSpeech else {
                EventLog.log("silence.blocked", ["path": "streaming"])
                partialText = ""
                setStatus(.error(silenceMessage))
                return
            }

            if effectiveCleanupEnabled() { setStatus(.cleaning) }
            let result = await transcriber.assembleFinalText()

            // Refine mode: the chunks were cleaned conservatively while the user
            // talked; now run ONE refine pass so the reformatting sees the whole
            // point. It consumes the RAW assembled transcript — refining the
            // chunk-cleaned text doesn't work (field-tested): neatly punctuated
            // waffle looks "already fine" to the model and it backs off. Falls
            // back to the chunk-cleaned assembly on any guard failure or timeout,
            // so refine is never worse than clean mode.
            var finalText = result.text
            var historyRaw: String?
            let note = result.note
            if cleanupMode() == .refine, effectiveCleanupEnabled() {
                let rawAssembled = await transcriber.assembledRawText()
                if rawAssembled.count >= TranscriptCleaner.minLength {
                    setStatus(.cleaning)
                    let refined = await cleaner.clean(
                        rawAssembled,
                        budgetSeconds: TranscriptCleaner.refineBudgetSeconds(for: rawAssembled),
                        context: makeCleanupContext()
                    )
                    // Reason is one of the cleaner's fixed note strings — never
                    // transcript content.
                    EventLog.log("refine", [
                        "path": "streaming",
                        "result": refined.note == nil ? "ok" : "fallback",
                        "reason": refined.note ?? "none",
                        "chars": String(rawAssembled.count),
                    ])
                    if refined.note == nil {
                        finalText = refined.text
                        historyRaw = rawAssembled
                    }
                }
            }
            // Keep what was actually said recoverable whenever refine rewrote it.
            await finishInsertion(text: finalText, note: note, raw: historyRaw)
        }
    }

    /// True when the pipeline is mid-processing (used by the menu to offer Cancel).
    var canCancelDictation: Bool {
        status.isRecording || pipelineActive
    }

    /// The existing single-pass path: one STT over the whole recording, one
    /// cleanup, then insertion. Used for short dictations and when streaming
    /// wasn't active.
    private func runTranscription(_ samples: [Float]) async {
        EventLog.log("pipeline.stage", ["at": "singlePass.enter", "samples": String(samples.count)])
        // Single-pass silence guard (both single-pass entry points route here).
        // A recording with no audible speech is the true-silence case behind the
        // "it only typed 'you'" reports: don't transcribe it, don't insert, don't
        // record history — tell the user their mic delivered nothing instead.
        guard AudioGate.containsSpeech(samples) else {
            EventLog.log("silence.blocked", [
                "path": "single-pass",
                "maxRMS": String(format: "%.4f", AudioGate.maxFrameRMS(samples, sampleRate: AudioRecorder.targetSampleRate)),
            ])
            partialText = ""
            setStatus(.error(silenceMessage))
            return
        }
        // Watchdog + fresh-engine retry: a CoreML/ANE-level stall (sample-confirmed
        // in the wild) can hang a transcription forever and poison the serial
        // chain. Time it out, discard the wedged engine, retry once on a fresh one
        // (which reloads the model, hence the larger second budget).
        var sttResult = await engine.transcribeOrTimeout(samples: samples, seconds: 30)
        if sttResult == nil {
            EventLog.log("stt.stalled", ["path": "single-pass", "action": "freshEngineRetry"])
            setStatus(.loadingModel("Recovering speech engine…"))
            reloadEngine()
            sttResult = await engine.transcribeOrTimeout(samples: samples, seconds: 120)
        }
        guard let sttText = sttResult else {
            EventLog.log("stt.failed", ["path": "single-pass", "error": "stalled twice"])
            partialText = ""
            if !pipelineCancelled { setStatus(.error("Transcription stalled — please dictate that again")) }
            return
        }
        // Cancelled while STT ran (user cancel or watchdog): unwind without inserting.
        guard !pipelineCancelled else {
            partialText = ""
            return
        }
        guard !sttText.isEmpty else {
            // NEVER a silent drop: an empty decode must tell the user (and the log).
            EventLog.log("stt.empty", ["path": "single-pass", "samples": String(samples.count)])
            partialText = ""
            setStatus(.error("Didn't catch that — try dictating again"))
            return
        }

        // Encode command phrases on the RAW transcript, before cleanup runs.
        let raw = voiceCommandsEnabled() ? encodeCommands(sttText) : sttText

        // Optional meaning-preserving cleanup. Gated by the effective (per-app
        // aware) flag; falls back to raw on any issue, with `note` explaining why.
        var finalText = raw
        var note: String?
        if effectiveCleanupEnabled(), raw.count >= TranscriptCleaner.minLength {
            setStatus(.cleaning)
            let context = makeCleanupContext()
            // Refine generates ~input-length output; give it a size-scaled budget.
            let budget = context.mode == .refine
                ? TranscriptCleaner.refineBudgetSeconds(for: raw)
                : TranscriptCleaner.defaultTimeBudgetSeconds
            let cleaned = await cleaner.clean(raw, budgetSeconds: budget, context: context)
            finalText = cleaned.text
            note = cleaned.note
            EventLog.log("cleanup", [
                "path": "single-pass",
                "mode": context.mode.rawValue,
                "result": note == nil ? "ok" : "fallback",
            ])
        }

        // Keep the pre-cleanup transcript when cleanup changed it: a bad cleanup
        // must never be the ONLY surviving copy of what the user said.
        await finishInsertion(text: finalText, note: note, raw: finalText != raw ? raw : nil)
    }

    /// Retains the final text, inserts it at the cursor, and drives the closing
    /// status. Shared by the single-pass and streaming paths. `raw` is the
    /// pre-cleanup transcript when cleanup produced something different — stored
    /// in history so the user's words are always recoverable.
    private func finishInsertion(text rawFinal: String, note: String?, raw: String? = nil) async {
        // A cancelled pipeline (user cancel or watchdog recovery) inserts nothing;
        // the canceller already set the closing status.
        guard !pipelineCancelled else {
            partialText = ""
            return
        }
        // Single choke point for BOTH pipelines: resolve voice commands, then
        // apply the personal-dictionary hard replacements, then insert.
        let text = postProcess(rawFinal)

        guard !text.isEmpty else {
            partialText = ""
            // Empty final text: normally a benign no-op (nothing intelligible), but
            // if a note came through (e.g. every voiced chunk failed STT) surface it
            // so the failure never vanishes silently.
            if let note {
                EventLog.log("insert.empty", ["note": "1"])
                setStatus(.error(note))
            } else {
                setStatus(.idle)
            }
            return
        }

        // Retain the final text before insertion so it can always be re-copied,
        // even if the paste lands nowhere useful.
        lastTranscript = text
        // Record it in history regardless of where the paste lands (pasted /
        // leftOnClipboard / noInputField all produced this same final text).
        appendHistory(text: text, raw: raw)

        setStatus(.pasting)
        // Per-app insertion override: apps whose inputs hide from accessibility
        // (some Electron apps) can be set to always paste, skipping detection.
        let insertBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let forcePaste = insertBundleID
            .flatMap { LocalFlowConfig.shared.rule(forBundleID: $0) }?.alwaysPaste ?? false
        if forcePaste, let insertBundleID {
            EventLog.log("insert.forcedPaste", ["bundle": insertBundleID])
        }
        let result = await inserter.insert(
            text, restoreClipboard: restoreClipboardEnabled(), forcePaste: forcePaste
        )
        partialText = ""
        // Character count only — never the inserted text itself.
        EventLog.log("insert", [
            "result": String(describing: result),
            "chars": String(text.count),
            "note": note == nil ? "0" : "1",
        ])
        switch result {
        case .pasted:
            // Insert first; then, if cleanup fell back, surface the note in the
            // menu for 5s via the existing error auto-reset.
            if let note {
                setStatus(.error(note))
            } else {
                setStatus(.idle)
            }
        case .leftOnClipboard:
            setStatus(.error("Copied — grant Accessibility to auto-paste"))
        case .noInputField:
            // No text field focused: the transcript is on the clipboard,
            // ready to paste. Surface the copy affordance transiently.
            setStatus(.noInputField)
        }
    }

    /// Final text transformations shared by both pipelines, applied once to the
    /// assembled transcript. Order matters: decode voice commands FIRST (so a
    /// "scratch that" retraction happens before words are rewritten), tidy the
    /// resulting newlines, then apply the dictionary's hard replacements.
    private func postProcess(_ raw: String) -> String {
        var text = raw
        if voiceCommandsEnabled() {
            text = decodeCommands(text)
            text = normalizeAfterCommands(text)
        }
        let replacements = LocalFlowConfig.shared.dictionary.replacements
        if !replacements.isEmpty {
            text = applyReplacements(text, replacements)
        }
        return text
    }

    /// Whether new dictations are saved to the on-disk history. Default on when
    /// the key has never been set; mirrors the Settings toggle.
    private func historyEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: "historyEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "historyEnabled")
    }

    /// Appends the just-produced final text to the history store (newest first)
    /// and signals any open main window to refresh. No-op when history is off.
    private func appendHistory(text: String, raw: String? = nil) {
        guard historyEnabled() else { return }
        let record = DictationRecord(
            text: text,
            appName: activeAppName,
            bundleID: activeAppBundleID,
            durationSeconds: lastRecordingDuration > 0 ? lastRecordingDuration : nil,
            raw: raw
        )
        HistoryStore.shared.append(record)
        historyRevision &+= 1
    }

    /// Puts the most recent dictation back on the clipboard. Drives the menu-bar
    /// "Copy Last Transcript" safety net; no-op when nothing has been dictated.
    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastTranscript, forType: .string)
    }

    /// The clipboard content a dictation displaced without restoring (paste into
    /// a non-text surface, or a rapid follow-up dictation). Surfaced in the menu
    /// so "my copied link is gone" is recoverable with one click.
    var displacedClipboard: String? { inserter.lastDisplacedClipboard }

    /// Puts the displaced clipboard content back and confirms in the menu bar.
    func restoreDisplacedClipboard() {
        guard let displaced = displacedClipboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displaced, forType: .string)
        showNote("Previous clipboard restored")
    }

    /// One-click support bundle: zips the app + updater logs and version/OS info
    /// to the Desktop and reveals it in Finder. Contains NO transcript content —
    /// both logs are metadata-only by contract, and history.json is deliberately
    /// excluded.
    func saveDiagnostics() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appendingPathComponent("LocalFlow-diagnostics-\(UUID().uuidString)")
            let out = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/LocalFlow-diagnostics.zip")
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let home = fm.homeDirectoryForCurrentUser
                let sources = [
                    home.appendingPathComponent("Library/Logs/LocalFlow.log"),
                    home.appendingPathComponent(".localflow/update.log"),
                ]
                for src in sources where fm.fileExists(atPath: src.path) {
                    try? fm.copyItem(at: src, to: staging.appendingPathComponent(src.lastPathComponent))
                }
                let info = """
                LocalFlow \(short) (build \(build))
                macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
                generated \(Date())
                """
                try info.write(to: staging.appendingPathComponent("versions.txt"), atomically: true, encoding: .utf8)

                try? fm.removeItem(at: out)
                let zip = Process()
                zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                zip.arguments = ["-c", "-k", staging.path, out.path]
                try zip.run()
                zip.waitUntilExit()
                try? fm.removeItem(at: staging)

                await MainActor.run {
                    AppState.shared.showNote("Diagnostics saved to Desktop")
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                await MainActor.run {
                    AppState.shared.showNote("Couldn't save diagnostics: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Publishes the live mic level and, cheaply off the same stream, records
    /// whether real input has been heard this dictation — clearing the "Can't hear
    /// you" hint the moment a voice comes through.
    private func updateAudioLevel(_ level: Float) {
        audioLevel = level
        guard level >= audioHeardLevel else { return }
        heardAudioThisDictation = true
        if showNoAudioHint { showNoAudioHint = false }
    }

    /// Arms the live "Can't hear you" hint for a fresh dictation: resets the
    /// heard-audio flag and, after `noAudioHintDelay`, shows the hint if still
    /// recording and nothing audible has arrived. Cancelled/reset on every stop via
    /// `setStatus`, so it's safe across rapid start/stop.
    private func startNoAudioHint() {
        heardAudioThisDictation = false
        showNoAudioHint = false
        noAudioHintTask?.cancel()
        noAudioHintTask = Task { [weak self] in
            let delay = self?.noAudioHintDelay ?? 3.0
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.status.isRecording && !self.heardAudioThisDictation {
                self.showNoAudioHint = true
            }
        }
    }

    private func startAutoStop() {
        autoStopTask?.cancel()
        let limit = maxRecordingSeconds
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.status.isRecording { self.stopDictation() }
        }
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        syncBusyMarker(for: newStatus)
        armProcessingWatchdog(for: newStatus)

        // The voice animation and the "Can't hear you" hint are only meaningful
        // while capturing; settle both on every other transition. (A .recording →
        // .recordingLocked change is still "recording", so the in-flight hint timer
        // survives locking.)
        if newStatus != .recording && newStatus != .recordingLocked {
            audioLevel = 0
            showNoAudioHint = false
            noAudioHintTask?.cancel()
            noAudioHintTask = nil
        }

        errorResetTask?.cancel()
        errorResetTask = nil

        // Transient states auto-return to idle: errors after 5s, the
        // no-input-field notice after 4s.
        let autoResetSeconds: Double?
        switch newStatus {
        case .error: autoResetSeconds = 5
        case .noInputField: autoResetSeconds = 4
        default: autoResetSeconds = nil
        }
        guard let autoResetSeconds else { return }
        errorResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(autoResetSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            switch self.status {
            case .error, .noInputField: self.status = .idle
            default: break
            }
        }
    }

    // MARK: - Updater busy marker & stuck-state recovery

    /// While a dictation is active, `~/.localflow/dictating` exists (its mtime
    /// refreshed on every transition); the hourly auto-updater refuses to relaunch
    /// the app while a FRESH marker is present, so an update can never destroy an
    /// in-flight dictation. A stale marker (crash mid-dictation) is ignored by the
    /// updater after 10 minutes. File ops run off the main thread.
    private static let busyMarkerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".localflow/dictating")
    private func syncBusyMarker(for newStatus: Status) {
        let busy: Bool
        switch newStatus {
        case .recording, .recordingLocked, .transcribing, .cleaning, .pasting: busy = true
        default: busy = false
        }
        let url = Self.busyMarkerURL
        DispatchQueue.global(qos: .utility).async {
            if busy {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Recovery net of last resort: no processing state may live longer than 90s.
    /// Every known stall is individually bounded (STT watchdogs, load budgets,
    /// cleanup timeouts) — if an unknown one slips through, this turns "wedged
    /// forever" into a 90-second hiccup with an honest error. Recording states are
    /// excluded (bounded by autoStop) and .loadingModel is excluded (first-run
    /// downloads legitimately run for many minutes under their own budget).
    private func armProcessingWatchdog(for newStatus: Status) {
        processingWatchdogTask?.cancel()
        processingWatchdogTask = nil
        switch newStatus {
        case .transcribing, .cleaning, .pasting:
            let snapshot = newStatus
            processingWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
                guard let self, !Task.isCancelled, self.status == snapshot else { return }
                EventLog.log("watchdog.forcedRecovery", ["stuck": snapshot.menuText])
                self.pipelineCancelled = true
                self.supervisorTask?.cancel()
                self.liveSource = nil
                self.incremental = nil
                self.supervisorTask = nil
                self.partialText = ""
                self.reloadEngine()
                self.setStatus(.error("That dictation got stuck — recovered. Please dictate it again."))
            }
        default:
            break
        }
    }
}
