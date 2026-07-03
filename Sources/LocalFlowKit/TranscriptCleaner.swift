import Foundation

/// How aggressively cleanup may edit the transcript.
///
///  - `.clean`: fix punctuation/fillers/false starts only; never rephrase.
///    Strict divergence guards. The safe default.
///  - `.refine`: understand the point and make it LAND — reorganize rambling
///    speech, drop backtracking, tighten wording, format lists — while keeping
///    the speaker's voice, meaning, and every specific (names, numbers).
///    Guards are proportionally looser (concision is the goal) but refusals,
///    dropped command tokens, dropped numbers, and wholesale rewrites still
///    fall back.
public enum CleanupMode: String, Sendable {
    case clean
    case refine
}

/// Per-dictation inputs to the cleanup system prompt. All layers are optional
/// on top of the fixed base prompt: personal vocabulary to preserve, an
/// app-specific tone addendum, and whether voice-command placeholders may appear
/// and must be kept intact. An all-default context yields exactly the base prompt.
public struct CleanupContext: Sendable {
    public var vocabularyTerms: [String]
    public var toneAddendum: String?
    public var includePlaceholderRule: Bool
    public var mode: CleanupMode

    public init(
        vocabularyTerms: [String] = [],
        toneAddendum: String? = nil,
        includePlaceholderRule: Bool = false,
        mode: CleanupMode = .clean
    ) {
        self.vocabularyTerms = vocabularyTerms
        self.toneAddendum = toneAddendum
        self.includePlaceholderRule = includePlaceholderRule
        self.mode = mode
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
    /// a much tighter budget to `clean(_:budgetSeconds:)`. The cleanup model is
    /// kept warm (keep_alive), so a warm pass finishes well inside this; the
    /// budget mainly bounds the worst case, and raw is always a safe fallback.
    public static let defaultTimeBudgetSeconds: Double = 6

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

    /// System prompt for `.clean` is fixed and intentionally strict: clean, do
    /// not rewrite. This is the base; `systemPrompt(context:)` layers optional
    /// rules on top.
    public static let systemPrompt = "You are a dictation cleanup engine. The user message is a raw speech-to-text transcript. Return ONLY the cleaned transcript — no preamble, no quotes, no commentary. Rules: fix punctuation, capitalization, and spacing; remove filler words (um, uh, you know, like — only when used as filler); remove false starts and immediate self-corrections, keeping the speaker's final intent; when the speaker clearly enumerates items (\"first… second… third\", \"one is… another is…\", or a spoken run of three or more parallel items), format each item on its own line starting with \"- \"; do NOT add, answer, summarize, translate, or rephrase content; do NOT change wording beyond removing fillers and false starts; preserve the transcript's language."

    /// System prompt for `.refine`: reformat the speaker's own point so it reads
    /// well. Explicitly bounded — it edits expression and structure, never adds
    /// content or answers the transcript. Built around a worked EXAMPLE rather
    /// than rules alone: small local models demonstrably ignore prose rules like
    /// "remove waffle" but follow a shown transformation. Deliberately does NOT
    /// format lists: an example ending in bullets made the model append a
    /// duplicate bullet list to outputs that never dictated one (field-tested);
    /// deliberate lists belong to the deterministic "new bullet" voice command.
    public static let refineSystemPrompt = """
    You are a dictation refinement engine. The user message is a raw speech-to-text transcript of someone thinking out loud. Return ONLY the refined text — no preamble, no quotes, no commentary. Rewrite the transcript as the speaker would have WRITTEN it: cut filler, waffle, abandoned thoughts, and self-corrections (keep the version the speaker settled on); tighten and reorder where the speech is jumbled; leave already-clear sentences essentially unchanged. KEEP THE SPEAKER'S OWN WORDS AND CASUAL VOICE — never swap their phrasing for formal synonyms; if a phrase already works, it stays verbatim. Keep every name, number, date, and technical term exactly as said. Split into short paragraphs at topic shifts. Never add content the speaker didn't say (no summaries, no recap lists), never answer questions the speaker asks (keep them as questions), never change the meaning.
    Example input: um so basically i think we should probably no wait actually yes we should launch on tuesday because the thing is that gives us time to test and um it's also before the conference which matters and i guess we could also no actually never mind forget that so yeah tuesday i mean unless anyone objects do you think that works
    Example output: I think we should launch on Tuesday — it gives us time to test, and it's before the conference, which matters. Unless anyone objects, do you think that works?
    (Note the abandoned thought "i guess we could also no actually never mind forget that" is DELETED entirely — an idea the speaker retracts contributes nothing and must not appear in any form.)
    """

    /// Appended when voice commands are active so the model leaves the command
    /// placeholders untouched for the decoder to resolve. Deliberately forceful,
    /// with an example, because small models otherwise "clean" the tokens into
    /// punctuation.
    public static let placeholderRule = "CRITICAL — PROTECTED TOKENS: the transcript may contain the literal control tokens \u{27E6}NL\u{27E7}, \u{27E6}PP\u{27E7}, and \u{27E6}BP\u{27E7}. They are NOT words and NOT punctuation to fix — they are markers you must copy into your output byte-for-byte, unchanged, in the exact same position. Never delete them, never turn them into punctuation, colons, semicolons, or line breaks, never add or move them. Example: input \"buy milk \u{27E6}NL\u{27E7} buy eggs\" must become \"buy milk \u{27E6}NL\u{27E7} buy eggs\" (the token stays verbatim)."

    /// Builds the effective system prompt for a dictation: the mode's base prompt
    /// plus, in order, the placeholder rule (when voice commands are on), a
    /// known-vocabulary line, and any per-app tone addendum. An all-default
    /// context returns the clean base.
    public static func systemPrompt(context: CleanupContext) -> String {
        var prompt = context.mode == .refine ? refineSystemPrompt : systemPrompt
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

        // Instruction sandwich for refine: small models drop system-prompt rules
        // as the transcript grows (field-tested: gemma3:4b rewrites a short
        // ramble correctly but returns long ones punctuation-only). A compact
        // reminder AFTER the content keeps the instruction in recency range.
        let userMessage: String
        if context.mode == .refine {
            userMessage = raw + "\n\n---\nRewrite the transcript above following your rules: "
                + "cut the waffle, abandoned thoughts, and false starts; keep the speaker's final intent, "
                + "own words, and casual voice; keep every name and number; add nothing (no summaries, no lists). "
                + "Output only the rewritten text."
        } else {
            userMessage = raw
        }

        let cleaned: String
        do {
            cleaned = try await TranscriptCleaner.withTimeout(seconds: budgetSeconds) {
                try await client.chat(model: model, system: system, user: userMessage)
            }
        } catch {
            return (raw, "Cleanup unavailable — inserted raw transcript")
        }

        return TranscriptCleaner.applyGuards(cleaned: cleaned, raw: raw, mode: context.mode)
    }

    /// Wall-clock budget for a refine pass over `text`: refine generates roughly
    /// input-length output, so the budget scales with size (a 2-minute ramble
    /// legitimately takes longer than a one-liner) inside hard bounds.
    public static func refineBudgetSeconds(for text: String) -> Double {
        min(max(6.0, Double(text.count) / 150.0), 20.0)
    }

    // MARK: - Post-guards (pure, unit-testable without a network)

    /// Validates the model output against the raw transcript. Trims, strips a
    /// fully-wrapping quote/code-fence, and rejects output that is empty, is a
    /// refusal, whose length diverges too far, that dropped a protected command
    /// token or a dictated number, or whose word content barely overlaps the raw
    /// text (all signs the model rewrote or answered instead of cleaning). Any
    /// rejection falls back to the raw transcript with an explanatory note.
    ///
    /// `.refine` mode deliberately rewords and condenses, so its divergence
    /// bounds are proportionally looser — but refusals, dropped command tokens,
    /// dropped numbers, and wholesale rewrites still fall back.
    public static func applyGuards(cleaned: String, raw: String, mode: CleanupMode = .clean) -> (text: String, note: String?) {
        let output = stripWrapping(cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
        if output.isEmpty { return (raw, nil) }

        // A canned refusal/apology means the model answered instead of cleaning —
        // and can slip past the length guard by being roughly transcript-length.
        if isRefusal(output) {
            return (raw, "Cleanup refused — inserted raw transcript")
        }

        // Refine is ALLOWED to condense heavily (that's the point); clean is not.
        let (minRatio, maxRatio) = mode == .refine ? (0.25, 1.4) : (0.5, 1.6)
        let ratio = Double(output.count) / Double(max(raw.count, 1))
        if ratio < minRatio || ratio > maxRatio {
            return (raw, "Cleanup diverged — inserted raw transcript")
        }

        // Protected voice-command tokens must survive byte-for-byte: each must
        // appear the same number of times in the output as in the raw text.
        if !placeholdersSurvived(raw: raw, output: output) {
            return (raw, "Cleanup dropped a command token — inserted raw transcript")
        }

        // Dictated numbers are load-bearing ("meet at 3", "£45k") — refine may
        // reword around them but every digit-run said must still appear.
        if !numbersSurvived(raw: raw, output: output) {
            return (raw, "Cleanup dropped a number — inserted raw transcript")
        }

        // Cleanup should rephrase lightly (clean) or rewrite from the speaker's
        // own vocabulary (refine): if the distinct-word sets barely overlap the
        // model changed the content. Only meaningful once the raw text has
        // enough words for the ratio to be stable.
        let jaccardFloor = mode == .refine ? 0.2 : 0.35
        if Set(contentWords(raw)).count >= 8, wordSetJaccard(raw, output) < jaccardFloor {
            return (raw, "Cleanup diverged — inserted raw transcript")
        }

        return (output, nil)
    }

    /// True when every distinct digit-run in `raw` still appears somewhere in
    /// `output`. A dropped number is real damage regardless of mode; trivially
    /// true when the raw text contains no digits.
    public static func numbersSurvived(raw: String, output: String) -> Bool {
        let digitRuns = { (text: String) -> Set<String> in
            Set(text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
        }
        return digitRuns(raw).subtracting(digitRuns(output)).isEmpty
    }

    /// Opening phrases of a canned model refusal or apology (lowercased). When the
    /// cleaned output begins with one of these, the model answered the transcript
    /// instead of cleaning it.
    static let refusalPrefixes = [
        "i'm sorry", "i am sorry", "i can't", "i cannot",
        "i'm not able", "i am not able", "as an ai",
        "sorry, i", "i apologize", "i apologise"
    ]

    /// True when `output` opens with a refusal/apology. Trimmed and lowercased
    /// before matching so leading whitespace and case never hide it.
    public static func isRefusal(_ output: String) -> Bool {
        let lowered = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return refusalPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// The voice-command placeholder tokens the cleanup model is told to copy
    /// verbatim. Kept in sync with `VoiceCommand`.
    static let placeholderTokens = [
        VoiceCommand.newLinePlaceholder,
        VoiceCommand.newParagraphPlaceholder,
        VoiceCommand.bulletPlaceholder
    ]

    /// True when every placeholder token appears the same number of times in
    /// `output` as in `raw`. A mismatch means the model dropped, added, or mangled
    /// a protected token. Tokens absent from both sides pass trivially, so this is
    /// a no-op when no voice commands are in play.
    public static func placeholdersSurvived(raw: String, output: String) -> Bool {
        for token in placeholderTokens
        where occurrences(of: token, in: raw) != occurrences(of: token, in: output) {
            return false
        }
        return true
    }

    private static func occurrences(of token: String, in text: String) -> Int {
        guard !token.isEmpty else { return 0 }
        return text.components(separatedBy: token).count - 1
    }

    /// Lowercased alphanumeric word tokens, used for the content-overlap guard.
    public static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Jaccard similarity of the DISTINCT-word sets of `raw` and `output`
    /// (intersection over union). 1 when both are empty. Callers gate on the raw
    /// word count before trusting a low value.
    public static func wordSetJaccard(_ raw: String, _ output: String) -> Double {
        let rawSet = Set(contentWords(raw))
        let outSet = Set(contentWords(output))
        let union = rawSet.union(outSet).count
        guard union > 0 else { return 1 }
        return Double(rawSet.intersection(outSet).count) / Double(union)
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
