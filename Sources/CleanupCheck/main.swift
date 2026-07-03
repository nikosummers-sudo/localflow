import Foundation
import LocalFlowKit

// Exercises the transcript cleanup path end-to-end against the local Ollama
// server. Prints "RAW: …" and "CLEANED: …". Exits non-zero if Ollama is
// unreachable (so it doubles as a health check).
//
// Usage:
//   CleanupCheck                 -> cleans a built-in messy sample
//   CleanupCheck "some text…"    -> cleans the given transcript
//   CleanupCheck --selftest      -> runs the pure post-guard checks (no network)

let defaultSample = "um so this is uh this is a test I I want to say hello world and and make sure it um you know works properly"

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let args = Array(CommandLine.arguments.dropFirst())

// MARK: - Self-test (deterministic, offline)

if args.contains("--selftest") {
    var failures = 0

    func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    let raw = "this is a short transcript that is definitely over fifty characters long ok"

    // Divergence: output far too long -> reject to raw with divergence note.
    let bloated = String(repeating: "word ", count: raw.count)
    let g1 = TranscriptCleaner.applyGuards(cleaned: bloated, raw: raw)
    check("over-long output rejected as divergence", g1.text == raw && g1.note == "Cleanup diverged — inserted raw transcript")

    // Divergence: output far too short -> reject to raw with divergence note.
    let g2 = TranscriptCleaner.applyGuards(cleaned: "tiny", raw: raw)
    check("too-short output rejected as divergence", g2.text == raw && g2.note == "Cleanup diverged — inserted raw transcript")

    // Empty output -> raw, no note.
    let g3 = TranscriptCleaner.applyGuards(cleaned: "   \n  ", raw: raw)
    check("empty output falls back to raw", g3.text == raw && g3.note == nil)

    // In-range output -> accepted, no note, wrapping quotes stripped.
    let quoted = "\"This is a short transcript that is definitely over fifty characters long. OK.\""
    let g4 = TranscriptCleaner.applyGuards(cleaned: quoted, raw: raw)
    check("in-range output accepted with wrapping quotes stripped", g4.note == nil && !g4.text.hasPrefix("\"") && !g4.text.hasSuffix("\""))

    // Code-fence wrapping stripped.
    let fenced = "```\nThis is a short transcript that is definitely over fifty characters long.\n```"
    let g5 = TranscriptCleaner.applyGuards(cleaned: fenced, raw: raw)
    check("code fence stripped", !g5.text.contains("```") && g5.note == nil)

    // Gate: short input returns unchanged and is not sent to the model.
    let short = "hi there"
    check("short input below gate not sent to model", !TranscriptCleaner.willRun(for: short))

    print(failures == 0 ? "SELFTEST: OK" : "SELFTEST: \(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Model-availability check (headless proof for the self-heal path)

// Verifies the hasModel/availableModels plumbing the app's self-heal relies on.
// Offline part exercises the pure matcher; the live part queries the real local
// Ollama /api/tags and prints what it found. Exits non-zero if the server is
// unreachable or if a model known to be absent is ever reported present.
//
//   CleanupCheck --model-check
if args.contains("--model-check") {
    let client = OllamaClient()

    // Offline: prove the matcher logic without any server.
    let sample = ["gemma3:4b", "llama3.2:latest", "nomic-embed-text:latest"]
    print("modelListContains exact 'gemma3:4b':   \(OllamaClient.modelListContains(sample, "gemma3:4b"))")
    print("modelListContains bare 'gemma3':        \(OllamaClient.modelListContains(sample, "gemma3"))")
    print("modelListContains missing '…-model:1b': \(OllamaClient.modelListContains(sample, "definitely-missing-model:1b"))")

    // Live: query the running Ollama server.
    guard let available = await client.availableModels() else {
        stderr("ERROR: Ollama unreachable at \(UserDefaults.standard.string(forKey: "ollamaURL") ?? OllamaClient.defaultBaseURL)")
        exit(1)
    }
    print("AVAILABLE MODELS (\(available.count)): \(available.joined(separator: ", "))")

    let present = await client.hasModel("gemma3:4b")
    let missing = await client.hasModel("definitely-missing-model:1b")
    print("hasModel(\"gemma3:4b\"): \(present)")
    print("hasModel(\"definitely-missing-model:1b\"): \(missing)")

    if missing {
        stderr("FAIL: a nonexistent model reported present — self-heal would never trigger")
        exit(1)
    }
    exit(0)
}

// MARK: - Placeholder-preservation check (live, hits Ollama)

// Verifies the cleanup model leaves voice-command placeholders untouched when the
// placeholder rule is in the system prompt. Prints the raw and cleaned text
// verbatim so the token can be eyeballed. Exits non-zero if the token is dropped.
if args.contains("--placeholder") {
    let sample = "so the plan is simple \u{27E6}NL\u{27E7} first we ship phase three \u{27E6}NL\u{27E7} then we test it thoroughly with real dictation"
    let cleaner = TranscriptCleaner(client: OllamaClient())
    let context = CleanupContext(includePlaceholderRule: true)

    print("RAW: \(sample)")
    let result = await cleaner.clean(sample, context: context)
    print("CLEANED: \(result.text)")
    if let note = result.note { stderr("NOTE: \(note)") }

    let kept = result.text.components(separatedBy: "\u{27E6}NL\u{27E7}").count - 1
    print("PLACEHOLDERS_KEPT: \(kept) of 2")
    if kept < 2 {
        stderr("WARN: cleanup dropped or altered a placeholder")
        exit(1)
    }
    exit(0)
}

// MARK: - Live cleanup
//
//   CleanupCheck [--refine] ["some text…"]
// --refine exercises the refine-mode prompt + guards (reformat rambling speech)
// instead of the default conservative clean.

var liveArgs = args
let useRefine = liveArgs.contains("--refine")
liveArgs.removeAll { $0 == "--refine" }

// --model <name>: run against a specific Ollama model (in-process override of
// the cleanupModel default) for side-by-side quality/speed comparisons.
if let flagIndex = liveArgs.firstIndex(of: "--model"), flagIndex + 1 < liveArgs.count {
    UserDefaults.standard.set(liveArgs[flagIndex + 1], forKey: "cleanupModel")
    liveArgs.removeSubrange(flagIndex...(flagIndex + 1))
}

let raw = liveArgs.isEmpty ? defaultSample : liveArgs.joined(separator: " ")

let cleaner = TranscriptCleaner(client: OllamaClient())
let liveContext = CleanupContext(mode: useRefine ? .refine : .clean)
let liveBudget = useRefine
    ? TranscriptCleaner.refineBudgetSeconds(for: raw)
    : TranscriptCleaner.defaultTimeBudgetSeconds

print("MODE: \(useRefine ? "refine" : "clean")")
print("RAW: \(raw)")
// On a guard fallback, also show the REJECTED model output and the guard's
// view of it — the diagnosis for "refine ran but nothing changed" reports.
// Mirror clean()'s refine instruction-sandwich so this debug view matches
// what the app actually sends.
let debugUser = useRefine
    ? raw + "\n\n---\nRewrite the transcript above following your rules: "
        + "cut the waffle, abandoned thoughts, and false starts; keep the speaker's final intent and voice; "
        + "break any list of three or more items into \"- \" lines; keep every name and number. "
        + "Output only the rewritten text."
    : raw
let preGuard = try? await OllamaClient().chat(
    model: TranscriptCleaner.model,
    system: TranscriptCleaner.systemPrompt(context: liveContext),
    user: debugUser
)
if let preGuard {
    let guarded = TranscriptCleaner.applyGuards(cleaned: preGuard, raw: raw, mode: liveContext.mode)
    print("MODEL_OUTPUT: \(preGuard)")
    print("RATIO: \(String(format: "%.2f", Double(preGuard.count) / Double(max(raw.count, 1))))")
    print("JACCARD: \(String(format: "%.2f", TranscriptCleaner.wordSetJaccard(raw, preGuard)))")
    print("GUARD: \(guarded.note ?? "accepted")")
}
let result = await cleaner.clean(raw, budgetSeconds: liveBudget, context: liveContext)
print("CLEANED: \(result.text)")

if let note = result.note {
    stderr("NOTE: \(note)")
}

// Unreachable server produces exactly this note; treat it as a health failure.
if TranscriptCleaner.willRun(for: raw), result.note == "Cleanup unavailable — inserted raw transcript" {
    stderr("ERROR: Ollama unreachable at \(UserDefaults.standard.string(forKey: "ollamaURL") ?? OllamaClient.defaultBaseURL)")
    exit(1)
}
