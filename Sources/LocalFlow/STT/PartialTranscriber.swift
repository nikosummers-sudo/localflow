import Foundation
import LocalFlowStreaming

/// Drives live, DISPLAY-ONLY partial transcriptions while a dictation is in
/// progress. Owns its OWN lightweight WhisperKitEngine (model from the
/// "partialsModel" default, "base" by default) so it never competes with the
/// main high-quality engine used for the final, authoritative transcription.
///
/// The partial text is only ever shown in the HUD — the inserted text always
/// comes from the main engine's pass over the full recording.
@MainActor
final class PartialTranscriber {
    private let engine: WhisperKitEngine
    private var loopTask: Task<Void, Never>?
    private var isActive = false

    /// Minimum audio before a first pass, and the cool-down between passes.
    private let minSeconds: Double = 1.0
    private let cooldownNanos: UInt64 = 600_000_000
    /// Cap the window fed to the cheap model so long dictations stay fast.
    private let maxWindowSeconds: Double = 30.0

    init() {
        let model = UserDefaults.standard.string(forKey: "partialsModel") ?? "base"
        engine = WhisperKitEngine(model: model)
    }

    /// Loads the preview model. Call after the main engine has loaded so the two
    /// don't compete for the download/compile at launch.
    func preload() async {
        try? await engine.preload()
    }

    /// Begins the partial loop, reading a growing snapshot from `recorder` and
    /// publishing display text via `onUpdate` (invoked on the main actor).
    func start(recorder: AudioRecorder, onUpdate: @escaping @MainActor (String) -> Void) {
        guard !isActive else { return }
        isActive = true
        loopTask = Task { [weak self, weak recorder] in
            await self?.runLoop(recorder: recorder, onUpdate: onUpdate)
        }
    }

    /// Cancels the loop and awaits any in-flight pass so a partial transcription
    /// never runs on into the final pass.
    func stop() async {
        isActive = false
        loopTask?.cancel()
        _ = await loopTask?.value
        loopTask = nil
    }

    private func runLoop(recorder: AudioRecorder?, onUpdate: @escaping @MainActor (String) -> Void) async {
        guard let recorder else { return }
        if !engine.isReady { await preload() }

        let sampleRate = AudioRecorder.targetSampleRate
        let minSamples = Int(sampleRate * minSeconds)
        let maxSamples = Int(sampleRate * maxWindowSeconds)

        while isActive && !Task.isCancelled {
            let all = recorder.currentSamples()
            if all.count >= minSamples {
                let truncated = all.count > maxSamples
                let window = truncated ? Array(all.suffix(maxSamples)) : all
                if let text = try? await engine.transcribePartial(samples: window),
                   !text.isEmpty {
                    let display = truncated ? "…" + text : text
                    onUpdate(display)
                }
            }
            if !isActive || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: cooldownNanos)
        }
    }
}
