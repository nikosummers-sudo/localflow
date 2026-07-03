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
        case loadingModel
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
            case .loadingModel: return "Loading model…"
            case .recording: return "Recording…"
            case .recordingLocked: return "Recording (locked)"
            case .transcribing: return "Transcribing…"
            case .cleaning: return "Cleaning…"
            case .pasting: return "Inserting text…"
            case .noInputField: return "No input field — copied to clipboard"
            case .error(let message): return message
            }
        }

        var symbolName: String {
            switch self {
            case .idle: return "mic"
            case .recording: return "mic.fill"
            case .recordingLocked: return "mic.badge.plus"
            case .loadingModel: return "arrow.down.circle"
            case .transcribing: return "waveform"
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

    /// The current dictation shortcut, mirrored here so menu/HUD copy updates reactively
    /// when the user changes it in Settings. Refreshed via `refreshHotkeyBinding()`.
    @Published private(set) var hotkeyBinding: HotkeyBinding = HotkeyBinding.load()

    /// The menu-bar status line. Locked recording is shown with the shortcut-specific
    /// finish gesture ("tap Right Option to finish", "press ⌘⇧D to finish").
    var statusMenuText: String {
        if status == .recordingLocked { return hotkeyBinding.lockedStatusText }
        return status.menuText
    }

    /// Re-reads the persisted binding after the user changes it in Settings.
    func refreshHotkeyBinding() {
        hotkeyBinding = HotkeyBinding.load()
    }

    /// Live, display-only preview text produced during recording. Never used for
    /// the final inserted text — that always comes from the main engine.
    @Published var partialText: String = ""

    /// Normalized 0–1 microphone level for the HUD's voice-reactive animation.
    /// Fed from the recorder's audio-thread callback (throttled ~15 Hz).
    @Published var audioLevel: Float = 0

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
    private let inserter = TextInserter()
    private let cleaner = TranscriptCleaner()
    private var partials: PartialTranscriber?

    // Streaming pipeline, live only during a dictation.
    private var incremental: IncrementalTranscriber?
    private var liveSource: LiveSampleSource?
    private var supervisorTask: Task<Void, Never>?

    private var errorResetTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?

    private let minRecordingSeconds: TimeInterval = 0.3
    // Streaming makes long recordings cheap, so the hands-free limit is generous.
    private let maxRecordingSeconds: TimeInterval = 600

    private init() {
        engine = SerialTranscriptionEngine(engine: WhisperKitEngine(model: configuredModelName()))
        // The recorder invokes this from the audio tap thread; hop to the main
        // actor to publish so the HUD's @Published binding stays valid.
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        observeForegroundApp()
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
    }

    // MARK: - Model lifecycle

    /// Loads (and if needed downloads) the model. Safe to call at launch.
    func preloadEngine() async {
        setStatus(.loadingModel)
        do {
            try await engine.preload()
            if let note = await engine.statusNote {
                setStatus(.error(note))
            } else if status == .loadingModel {
                setStatus(.idle)
            }
        } catch {
            setStatus(.error("Model load failed: \(error.localizedDescription)"))
        }
    }

    /// Rebuilds the engine after the model choice changes, then reloads.
    func reloadEngine() {
        engine = SerialTranscriptionEngine(engine: WhisperKitEngine(model: configuredModelName()))
        Task { await preloadEngine() }
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

    private func startPartials() {
        guard showLivePreview() else { return }
        if partials == nil { partials = PartialTranscriber() }
        partials?.start(recorder: recorder) { [weak self] text in
            self?.partialText = text
        }
    }

    // MARK: - Dictation pipeline

    func startDictation() {
        switch status {
        case .recording, .recordingLocked, .transcribing, .cleaning, .pasting:
            return
        default:
            break
        }
        do {
            try recorder.beginRecording()
            captureActiveApp()
            partialText = ""
            setStatus(.recording)
            startAutoStop()
            startPartials()
            startStreaming()
        } catch {
            setStatus(.error(error.localizedDescription))
        }
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

    /// Builds the cleanup system-prompt context for this dictation: personal
    /// vocabulary, the active app's tone addendum, and whether voice-command
    /// placeholders must be preserved.
    private func makeCleanupContext() -> CleanupContext {
        CleanupContext(
            vocabularyTerms: LocalFlowConfig.shared.currentTerms(),
            toneAddendum: currentAppRule()?.toneAddendum,
            includePlaceholderRule: voiceCommandsEnabled()
        )
    }

    /// Latches an in-progress hold recording into hands-free (locked) mode. The
    /// recorder and auto-stop timer are untouched — only the surfaced status changes.
    func lockDictation() {
        guard status == .recording else { return }
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
            cleanupContext: makeCleanupContext()
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

        setStatus(.transcribing)
        Task {
            // Finish any in-flight partial before the authoritative final pass so
            // the two never run concurrently.
            await partials?.stop()

            // Stop the supervisor and let any in-flight chunk finish committing so
            // `committedChunkCount` and the tail range are final.
            supervisor?.cancel()
            _ = await supervisor?.value

            guard let transcriber, let source else {
                await runTranscription(finalSamples)
                return
            }

            let committed = await transcriber.committedChunkCount
            guard committed > 0 else {
                // Released before the first chunk committed → EXACTLY the existing
                // single-pass path (one STT + one cleanup).
                await runTranscription(finalSamples)
                return
            }

            // Streaming path: only the short tail is left to transcribe + clean.
            source.finalize(with: finalSamples)
            await transcriber.transcribeTail(source: source)
            if effectiveCleanupEnabled() { setStatus(.cleaning) }
            let result = await transcriber.assembleFinalText()
            await finishInsertion(text: result.text, note: result.note)
        }
    }

    /// The existing single-pass path: one STT over the whole recording, one
    /// cleanup, then insertion. Used for short dictations and when streaming
    /// wasn't active.
    private func runTranscription(_ samples: [Float]) async {
        do {
            let sttText = try await engine.transcribe(samples: samples)
            guard !sttText.isEmpty else {
                partialText = ""
                setStatus(.idle)
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
                let cleaned = await cleaner.clean(raw, context: makeCleanupContext())
                finalText = cleaned.text
                note = cleaned.note
            }

            await finishInsertion(text: finalText, note: note)
        } catch {
            partialText = ""
            setStatus(.error(error.localizedDescription))
        }
    }

    /// Retains the final text, inserts it at the cursor, and drives the closing
    /// status. Shared by the single-pass and streaming paths.
    private func finishInsertion(text rawFinal: String, note: String?) async {
        // Single choke point for BOTH pipelines: resolve voice commands, then
        // apply the personal-dictionary hard replacements, then insert.
        let text = postProcess(rawFinal)

        guard !text.isEmpty else {
            partialText = ""
            setStatus(.idle)
            return
        }

        // Retain the final text before insertion so it can always be re-copied,
        // even if the paste lands nowhere useful.
        lastTranscript = text
        // Record it in history regardless of where the paste lands (pasted /
        // leftOnClipboard / noInputField all produced this same final text).
        appendHistory(text: text)

        setStatus(.pasting)
        let result = await inserter.insert(text, restoreClipboard: restoreClipboardEnabled())
        partialText = ""
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
    private func appendHistory(text: String) {
        guard historyEnabled() else { return }
        let record = DictationRecord(
            text: text,
            appName: activeAppName,
            bundleID: activeAppBundleID,
            durationSeconds: lastRecordingDuration > 0 ? lastRecordingDuration : nil
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

    // MARK: - Helpers

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

        // The voice animation is only meaningful while capturing; settle it to
        // quiet on every other transition.
        if newStatus != .recording && newStatus != .recordingLocked {
            audioLevel = 0
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
}
