import Foundation
import LocalFlowKit
import WhisperKit

/// WhisperKit-backed transcription engine. Runs entirely on-device; the only
/// network access is WhisperKit's one-time model download from Hugging Face,
/// which lands under ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml.
public final class WhisperKitEngine: TranscriptionEngine {
    /// Model variant WhisperKit downloads and loads (matched against the
    /// argmaxinc/whisperkit-coreml repo).
    private let requestedModel: String
    private let fallbackModel = "base"

    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    /// Special tokens Whisper can emit (e.g. <|startoftranscript|>, <|en|>, <|0.00|>).
    private static let specialTokenPattern = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>")

    /// Empty marker file dropped inside a model folder once that model has fully
    /// downloaded AND loaded at least once. See `markVerified` / `modelVerified`.
    static let verifiedSentinelName = ".localflow-verified"

    /// Whether `model` has previously completed a full download + load, i.e. its
    /// verified sentinel exists. The app layer uses this instead of a bare folder
    /// existence check: WhisperKit downloads ~1.6 GB on first run and, if the app
    /// dies mid-download, the model FOLDER exists but is incomplete — a plain
    /// folder check then grants only the short "cached" load budget forever, a
    /// permanent timeout loop. Mirrors WhisperKit's on-disk layout (same
    /// convention AppState.modelLikelyCached uses): ~/Documents/huggingface/
    /// models/argmaxinc/whisperkit-coreml/openai_whisper-<model>/.localflow-verified.
    public static func modelVerified(_ model: String) -> Bool {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)"
            )
        let sentinel = folder.appendingPathComponent(verifiedSentinelName)
        return FileManager.default.fileExists(atPath: sentinel.path)
    }

    public var isReady: Bool { whisperKit != nil }

    /// Human-readable note about what actually loaded (used for status messaging
    /// when a fallback happens). Nil until preload succeeds.
    public private(set) var statusNote: String?

    public init(model: String) {
        self.requestedModel = model
    }

    public func preload() async throws {
        // IDEMPOTENT: the engine loads at most once. Callers retry/race preload
        // freely (launch, the dictation readiness gate) — without this guard,
        // every extra call reloaded the full model and occupied the serial
        // chain for ~40s each, so dictations made while the model was loading
        // appeared to vanish. Model changes use a fresh engine (reloadEngine).
        guard whisperKit == nil else { return }
        do {
            whisperKit = try await makeWhisperKit(model: requestedModel)
            loadedModel = requestedModel
            statusNote = nil
        } catch {
            // The configured model may be unavailable on this device — fall back to a
            // small, always-available model so dictation still works.
            guard requestedModel != fallbackModel else { throw error }
            whisperKit = try await makeWhisperKit(model: fallbackModel)
            loadedModel = fallbackModel
            statusNote = "Could not load \"\(requestedModel)\"; using \"\(fallbackModel)\" instead."
        }
        await warmUp()
        // Download + load + a real inference all succeeded: mark the model folder
        // verified so a future launch can trust the short "cached" load budget.
        markVerified()
    }

    /// Drops an empty sentinel inside the loaded model's folder to record that the
    /// model completed a full download + load. Written only here, after warm-up,
    /// so a folder left behind by a half-finished download never carries it. Best
    /// effort: if the write fails the only cost is a longer load budget next
    /// launch. Uses WhisperKit's own `modelFolder` (the exact folder it loaded
    /// from) so the path always exists; for the argmaxinc models this resolves to
    /// the same openai_whisper-<model> folder `modelVerified` checks.
    private func markVerified() {
        guard let folder = whisperKit?.modelFolder else { return }
        let sentinel = folder.appendingPathComponent(WhisperKitEngine.verifiedSentinelName)
        try? Data().write(to: sentinel)
    }

    /// Drops the loaded model so ARC can free its ~1.5 GB of weights. Called when
    /// a transcribe call has stalled at the CoreML/ANE layer and the engine is
    /// being abandoned: nil-ing the stored reference here means that once the
    /// parked call finally unwinds, the model is released instead of a dead engine
    /// pinning it for the process lifetime (repeated stalls otherwise stack toward
    /// OOM). A later transcribe on this instance transparently reloads via the
    /// preload guard.
    public func discardModel() {
        whisperKit = nil
        loadedModel = nil
    }

    /// Runs a throwaway transcription of one second of silence so CoreML/ANE
    /// compilation and caching happen at launch, not on the user's first real
    /// dictation. Result and errors are intentionally ignored.
    private func warmUp() async {
        guard let whisperKit else { return }
        let silence = [Float](repeating: 0, count: 16000)
        _ = try? await whisperKit.transcribe(audioArray: silence, decodeOptions: decodingOptions())
    }

    public func transcribe(samples: [Float]) async throws -> String {
        let engine: WhisperKit
        if let whisperKit {
            engine = whisperKit
        } else {
            try await preload()
            guard let ready = whisperKit else { return "" }
            engine = ready
        }

        let results = try await engine.transcribe(
            audioArray: samples, decodeOptions: decodingOptions()
        )
        return WhisperKitEngine.clean(results.map(\.text).joined(separator: " "))
    }

    /// Decoding options tuned for dictation latency:
    ///  - `withoutTimestamps` skips generating timestamp tokens we never use.
    ///  - `chunkingStrategy: .vad` splits long audio at silence and decodes the
    ///    chunks concurrently — a large win on long, hands-free dictations.
    ///  - `noSpeechThreshold`/`compressionRatioThreshold` are hallucination
    ///    guards: reject a decoded segment whose no-speech probability is high or
    ///    whose text is pathologically repetitive, so a silent or near-silent
    ///    clip can't emit invented words. Set explicitly to pin the intent; these
    ///    values match WhisperKit 0.18's own defaults.
    ///
    /// We deliberately pass NO `promptTokens`. A vocabulary prompt built from the
    /// personal dictionary biased Whisper's decoder toward those terms and, on
    /// quiet or ambiguous audio, made it hallucinate and REPEAT them — "n8n n8n
    /// n8n" in speech that never contained the word (field-reported 2026-07-10).
    /// This is the well-known `initial_prompt` failure mode; a post-hoc guard
    /// still leaks stray single insertions, so we remove the bias at the source.
    /// Learned terms now drive only the deterministic find→replace rule and the
    /// cleanup spelling hint, never the STT decoder.
    private func decodingOptions() -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: 2.4,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
    }

    /// Cheap decode for live preview passes over short clips: no VAD chunking
    /// (unnecessary overhead for a few seconds of audio) and no model load — if
    /// the engine isn't ready yet the pass just yields "" and the loop retries.
    /// The result is DISPLAY-ONLY and never used for the final inserted text.
    public func transcribePartial(samples: [Float]) async throws -> String {
        guard let engine = whisperKit else { return "" }
        let options = DecodingOptions(
            task: .transcribe,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await engine.transcribe(audioArray: samples, decodeOptions: options)
        let joined = results.map(\.text).joined(separator: " ")
        return WhisperKitEngine.clean(joined)
    }

    private func makeWhisperKit(model: String) async throws -> WhisperKit {
        // load: true is required — with only a model name (no local folder) WhisperKit
        // downloads but does not auto-load the model otherwise.
        let config = WhisperKitConfig(
            model: model,
            verbose: false,
            logLevel: .error,
            load: true,
            download: true
        )
        return try await WhisperKit(config)
    }

    public static func clean(_ text: String) -> String {
        var result = text
        if let pattern = specialTokenPattern {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
