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

    /// Cap for the decoding-prompt token count. WhisperKit trims to its own
    /// (larger) limit by keeping the suffix; we cap tighter so the prompt can't
    /// crowd out the actual transcription context.
    private static let maxPromptTokens = 180

    /// Encoded vocabulary prompt, cached so we only re-tokenize when the terms
    /// actually change (the prompt is rebuilt on every transcribe call).
    private var cachedVocabSignature = ""
    private var cachedPromptTokens: [Int]?

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
    }

    /// Runs a throwaway transcription of one second of silence so CoreML/ANE
    /// compilation and caching happen at launch, not on the user's first real
    /// dictation. Result and errors are intentionally ignored.
    private func warmUp() async {
        guard let whisperKit else { return }
        let silence = [Float](repeating: 0, count: 16000)
        _ = try? await whisperKit.transcribe(audioArray: silence, decodeOptions: decodingOptions(promptTokens: nil))
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

        let prompt = vocabularyPromptTokens()
        let results = try await engine.transcribe(
            audioArray: samples, decodeOptions: decodingOptions(promptTokens: prompt)
        )
        var text = WhisperKitEngine.clean(results.map(\.text).joined(separator: " "))

        // A vocabulary prompt can drive Whisper's decoder straight to end-of-text
        // on SHORT clips, yielding an empty transcription (field-observed: short
        // dictations "vanished" once the personal dictionary had its first term).
        // Decode once more without the prompt — dictionary bias is a nice-to-have;
        // the user's words are not.
        if text.isEmpty, prompt != nil {
            EventLog.log("stt.emptyWithPrompt", [
                "samples": String(samples.count), "action": "retryNoPrompt",
            ])
            let retry = try await engine.transcribe(
                audioArray: samples, decodeOptions: decodingOptions(promptTokens: nil)
            )
            text = WhisperKitEngine.clean(retry.map(\.text).joined(separator: " "))
        }
        return text
    }

    /// Decoding options tuned for dictation latency:
    ///  - `withoutTimestamps` skips generating timestamp tokens we never use.
    ///  - `chunkingStrategy: .vad` splits long audio at silence and decodes the
    ///    chunks concurrently — a large win on long, hands-free dictations.
    private func decodingOptions(promptTokens: [Int]?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )
    }

    /// Tokenizes the user's personal-dictionary terms into a decoding prompt so
    /// WhisperKit biases toward those spellings. Returns nil when there is no
    /// vocabulary or the tokenizer isn't ready yet. WhisperKit filters out any
    /// special tokens and prepends its own <|startofprev|>, so we pass the raw
    /// encoded phrase tokens. Cached by term signature to avoid re-encoding on
    /// every chunk. Safe because all transcribe calls are serialized through the
    /// SerialTranscriptionEngine actor.
    private func vocabularyPromptTokens() -> [Int]? {
        guard let tokenizer = whisperKit?.tokenizer else { return nil }
        let terms = LocalFlowConfig.shared.currentTerms()
        let signature = terms.joined(separator: "\u{1}")
        if signature == cachedVocabSignature { return cachedPromptTokens }

        cachedVocabSignature = signature
        guard !terms.isEmpty else {
            cachedPromptTokens = nil
            return nil
        }

        let phrase = "Vocabulary: " + terms.joined(separator: ", ") + "."
        var tokens = tokenizer.encode(text: phrase)
        if tokens.count > WhisperKitEngine.maxPromptTokens {
            // Keep the most recent terms (the suffix); the oldest fall off.
            tokens = Array(tokens.suffix(WhisperKitEngine.maxPromptTokens))
        }
        cachedPromptTokens = tokens
        return tokens
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
