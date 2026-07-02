import Foundation

/// Per-dictation inputs to the cleanup system prompt. All three are optional
/// layers on top of the fixed base prompt: personal vocabulary to preserve, an
/// app-specific tone addendum, and whether voice-command placeholders may appear
/// and must be kept intact. An all-default context yields exactly the base prompt.
public struct CleanupContext: Sendable {
    public var vocabularyTerms: [String]
    public var toneAddendum: String?
    public var includePlaceholderRule: Bool

    public init(
        vocabularyTerms: [String] = [],
        toneAddendum: String? = nil,
        includePlaceholderRule: Bool = false
    ) {
        self.vocabularyTerms = vocabularyTerms
        self.toneAddendum = toneAddendum
        self.includePlaceholderRule = includePlaceholderRule
    }
}

/// Meaning-preserving cleanup of a raw speech-to-text transcript via a local
/// Ollama model. Cleanup is best-effort and MUST NEVER block or replace a valid
/// transcript: any failure, timeout, or suspicious divergence falls back to the
/// raw text with an explanatory note the caller can surface.
public struct TranscriptCleaner: Sendable {
    /// Transcripts shorter than this are inserted as-is — too little to clean and
    /// not worth a model round-trip.
    public static let minLength = 50

    /// Default wall-clock budget for a cleanup pass. On expiry we fall back to
    /// raw. Callers on a latency-critical path (e.g. the streamed tail) can pass
    /// a much tighter budget to `clean(_:budgetSeconds:)`.
    public static let defaultTimeBudgetSeconds: Double = 15

    private let client: OllamaClient

    public init(client: OllamaClient = OllamaClient()) {
        self.client = client
    }

    // MARK: - Settings (read fresh so Settings changes take effect immediately)

    public static var isEnabled: Bool {
        // Default on when the key has never been set.
        if UserDefaults.standard.object(forKey: "cleanupEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "cleanupEnabled")
    }

    public static var model: String {
        UserDefaults.standard.string(forKey: "cleanupModel") ?? "gemma3:4b"
    }

    /// Whether `clean` would actually call the model for this input. Callers use
    /// this to decide whether to show a "Cleaning…" status.
    public static func willRun(for raw: String) -> Bool {
        isEnabled && raw.count >= minLength
    }

    /// System prompt is fixed and intentionally strict: clean, do not rewrite.
    /// This is the base; `systemPrompt(context:)` layers optional rules on top.
    public static let systemPrompt = "You are a dictation cleanup engine. The user message is a raw speech-to-text transcript. Return ONLY the cleaned transcript — no preamble, no quotes, no commentary. Rules: fix punctuation, capitalization, and spacing; remove filler words (um, uh, you know, like — only when used as filler); remove false starts and immediate self-corrections, keeping the speaker's final intent; format clearly dictated lists as lists; do NOT add, answer, summarize, translate, or rephrase content; do NOT change wording beyond removing fillers and false starts; preserve the transcript's language."

    /// Appended when voice commands are active so the model leaves the command
    /// placeholders untouched for the decoder to resolve. Deliberately forceful,
    /// with an example, because small models otherwise "clean" the tokens into
    /// punctuation.
    public static let placeholderRule = "CRITICAL — PROTECTED TOKENS: the transcript may contain the literal control tokens \u{27E6}NL\u{27E7}, \u{27E6}PP\u{27E7}, and \u{27E6}SCRATCH\u{27E7}. They are NOT words and NOT punctuation to fix — they are markers you must copy into your output byte-for-byte, unchanged, in the exact same position. Never delete them, never turn them into punctuation, colons, semicolons, or line breaks, never add or move them. Example: input \"buy milk \u{27E6}NL\u{27E7} buy eggs\" must become \"buy milk \u{27E6}NL\u{27E7} buy eggs\" (the token stays verbatim)."

    /// Builds the effective system prompt for a dictation: the base prompt plus,
    /// in order, the placeholder rule (when voice commands are on), a known-vocabulary
    /// line, and any per-app tone addendum. An all-default context returns the base.
    public static func systemPrompt(context: CleanupContext) -> String {
        var prompt = systemPrompt
        if context.includePlaceholderRule {
            prompt += "\n" + placeholderRule
        }
        if !context.vocabularyTerms.isEmpty {
            prompt += "\nKnown vocabulary (preserve exact spelling): " + context.vocabularyTerms.joined(separator: ", ") + "."
        }
        if let tone = context.toneAddendum, !tone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n" + tone
        }
        return prompt
    }

    // MARK: - Cleanup

    /// Returns cleaned text plus an optional note. The note is non-nil whenever we
    /// fell back to the raw transcript, so the caller can tell the user why.
    ///
    /// Whether cleanup runs at all is the CALLER's decision (the effective enabled
    /// flag, which per-app rules can override) — this only enforces the minimum
    /// length gate. `context` layers per-dictation rules onto the system prompt.
    public func clean(
        _ raw: String,
        budgetSeconds: Double = TranscriptCleaner.defaultTimeBudgetSeconds,
        context: CleanupContext = CleanupContext()
    ) async -> (text: String, note: String?) {
        guard raw.count >= TranscriptCleaner.minLength else {
            return (raw, nil)
        }

        let client = self.client
        let model = TranscriptCleaner.model
        let system = TranscriptCleaner.systemPrompt(context: context)

        let cleaned: String
        do {
            cleaned = try await TranscriptCleaner.withTimeout(seconds: budgetSeconds) {
                try await client.chat(model: model, system: system, user: raw)
            }
        } catch {
            return (raw, "Cleanup unavailable — inserted raw transcript")
        }

        return TranscriptCleaner.applyGuards(cleaned: cleaned, raw: raw)
    }

    // MARK: - Post-guards (pure, unit-testable without a network)

    /// Validates the model output against the raw transcript. Trims, strips a
    /// fully-wrapping quote/code-fence, and rejects output that is empty or whose
    /// length diverges too far from the raw text (a sign the model rewrote or
    /// answered instead of cleaning).
    public static func applyGuards(cleaned: String, raw: String) -> (text: String, note: String?) {
        let output = stripWrapping(cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
        if output.isEmpty { return (raw, nil) }

        let ratio = Double(output.count) / Double(max(raw.count, 1))
        if ratio < 0.5 || ratio > 1.6 {
            return (raw, "Cleanup diverged — inserted raw transcript")
        }
        return (output, nil)
    }

    /// Strips a single layer of wrapping only if the WHOLE output is wrapped —
    /// a leading/trailing code fence, or matching quote marks around everything.
    static func stripWrapping(_ text: String) -> String {
        var s = text

        // Code fence: ```lang\n … \n```
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                var body = String(s[s.index(after: firstNewline)...])
                if let closing = body.range(of: "```", options: .backwards) {
                    body = String(body[..<closing.lowerBound])
                }
                s = body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Matching wrapping quotes around the entire string.
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("`", "`"),
            ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}")
        ]
        for (open, close) in pairs where s.count >= 2 && s.first == open && s.last == close {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return s
    }

    // MARK: - Timeout

    private struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimeoutError() }
            return result
        }
    }
}
