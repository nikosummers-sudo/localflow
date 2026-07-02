import Foundation
import LocalFlowKit

// Offline, deterministic checks for the Phase 3 pure functions: dictionary
// replacements, voice-command encode/decode, and newline-preserving normalization.
// No WhisperKit, no Ollama, no microphone.
//
// Usage:
//   DictCheck --selftest    -> runs every case, prints PASS/FAIL per case
//   DictCheck               -> same as --selftest

var failures = 0

func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// MARK: - Store round-trip (writes to a scratch dir, prints the JSON schema)

if CommandLine.arguments.contains("--store") {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("localflow-dictcheck-\(UUID().uuidString)", isDirectory: true)
    let store = LocalFlowConfig(directory: dir)

    store.dictionary = PersonalDictionary(
        terms: ["Triptease", "Niko", "WhisperKit"],
        replacements: [Replacement(find: "triptease", replace: "Triptease")]
    )
    store.appRules = [
        AppRule(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                cleanupEnabled: true, toneAddendum: "Casual Slack message — keep contractions."),
        AppRule(bundleID: "com.apple.mail", appName: "Mail") // nil overrides = inherit
    ]

    let dictJSON = (try? String(contentsOf: dir.appendingPathComponent("dictionary.json"), encoding: .utf8)) ?? "(missing)"
    let appsJSON = (try? String(contentsOf: dir.appendingPathComponent("apps.json"), encoding: .utf8)) ?? "(missing)"
    print("--- dictionary.json ---")
    print(dictJSON)
    print("--- apps.json ---")
    print(appsJSON)

    // Reload from disk into a fresh store and confirm equality.
    let reloaded = LocalFlowConfig(directory: dir)
    check("dictionary round-trips through disk", reloaded.dictionary == store.dictionary)
    check("app rules round-trip through disk", reloaded.appRules == store.appRules)
    check("nil overrides stay nil after reload",
          reloaded.appRules.first(where: { $0.bundleID == "com.apple.mail" })?.cleanupEnabled == nil)
    check("rule lookup by bundle id works", reloaded.rule(forBundleID: "com.tinyspeck.slackmacgap")?.cleanupEnabled == true)

    try? FileManager.default.removeItem(at: dir)
    print(failures == 0 ? "STORE: OK" : "STORE: \(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// Renders newlines visibly so failures are readable in the terminal.
func show(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "\\n")
}

// MARK: - Dictionary replacements

do {
    let r = [Replacement(find: "triptease", replace: "Triptease")]
    let out = applyReplacements("triptease and TRIPTEASE", r)
    check("replacement is case-insensitive by default (both hits) [\(show(out))]",
          out == "Triptease and Triptease")
}

do {
    let r = [Replacement(find: "trip", replace: "TRIP")]
    let out = applyReplacements("tripwire and a trip", r)
    check("whole-word does not match inside a longer word [\(show(out))]",
          out == "tripwire and a TRIP")
}

do {
    // The classic trap: "period" must never corrupt "periodic".
    let r = [Replacement(find: "period", replace: "PERIOD")]
    let out = applyReplacements("periodic period", r)
    check("whole-word 'period' leaves 'periodic' intact [\(show(out))]",
          out == "periodic PERIOD")
}

do {
    let r = [Replacement(find: "ios", replace: "iOS", caseSensitive: true)]
    let out = applyReplacements("ios iOS IOS", r)
    check("case-sensitive replacement matches only exact case [\(show(out))]",
          out == "iOS iOS IOS")
}

do {
    let r = [Replacement(find: "cat", replace: "dog", caseSensitive: false, wholeWord: false)]
    let out = applyReplacements("category cat", r)
    check("wholeWord=false replaces substrings too [\(show(out))]",
          out == "dogegory dog")
}

do {
    // The replacement string must be inserted literally, never as a regex template.
    let r = [Replacement(find: "dollars", replace: "$5")]
    let out = applyReplacements("five dollars", r)
    check("replacement with regex-special chars is literal [\(show(out))]",
          out == "five $5")
}

do {
    let out = applyReplacements("nothing to do here", [])
    check("no replacements is identity", out == "nothing to do here")
}

// MARK: - Voice commands: encode + decode round-trips

// Full pipeline as the app runs it: encode on raw, (cleanup), decode, normalize.
func pipeline(_ raw: String, cleanup: (String) -> String = { $0 }) -> String {
    normalizeAfterCommands(decodeCommands(cleanup(encodeCommands(raw))))
}

check("'new line' becomes a newline mid-sentence [\(show(pipeline("please add a new line here")))]",
      pipeline("please add a new line here") == "please add a\nhere")

check("'new paragraph' becomes a blank-line break [\(show(pipeline("one new paragraph two")))]",
      pipeline("one new paragraph two") == "one\n\ntwo")

check("trailing period on a command is tolerated [\(show(pipeline("add new line. then continue")))]",
      pipeline("add new line. then continue") == "add\nthen continue")

check("'scratch that' retracts only the last sentence [\(show(pipeline("I like cats. I like dogs. scratch that")))]",
      pipeline("I like cats. I like dogs. scratch that") == "I like cats.")

check("'scratch that' mid-utterance retracts back to start [\(show(pipeline("Let's meet at 3pm scratch that let's meet at 4pm")))]",
      pipeline("Let's meet at 3pm scratch that let's meet at 4pm") == "let's meet at 4pm")

// A command phrase embedded in a longer word must NOT trigger.
check("'renew line' is not treated as a 'new line' command [\(show(pipeline("renew line")))]",
      pipeline("renew line") == "renew line")

check("text with no commands is unchanged by encode/decode",
      pipeline("nothing special to see here at all") == "nothing special to see here at all")

// Placeholders must survive a cleanup pass that rewrites the surrounding words.
// Here the mock cleanup capitalizes and adds a period but keeps the placeholder.
do {
    let mockClean: (String) -> String = { encoded in
        // Simulates gemma preserving the token verbatim while cleaning around it.
        encoded.replacingOccurrences(of: "first", with: "First") + "."
    }
    let out = pipeline("first line new line second line", cleanup: mockClean)
    check("placeholder survives a rewriting cleanup and still decodes [\(show(out))]",
          out == "First line\nsecond line.")
}

// The encoded placeholders themselves are the exact agreed tokens.
do {
    let encoded = encodeCommands("a new line b new paragraph c scratch that")
    check("encode emits the exact placeholder tokens",
          encoded.contains(VoiceCommand.newLinePlaceholder)
              && encoded.contains(VoiceCommand.newParagraphPlaceholder)
              && encoded.contains(VoiceCommand.scratchPlaceholder))
}

// MARK: - Newline-preserving normalization

check("inline normalize collapses spaces but preserves newlines [\(show(normalizeInlineWhitespace("a  b\nc   d")))]",
      normalizeInlineWhitespace("a  b\nc   d") == "a b\nc d")

check("inline normalize trims spaces hugging a newline [\(show(normalizeInlineWhitespace("line1  \n  line2")))]",
      normalizeInlineWhitespace("line1  \n  line2") == "line1\nline2")

check("inline normalize keeps a lone newline [\(show(normalizeInlineWhitespace("x\ny")))]",
      normalizeInlineWhitespace("x\ny") == "x\ny")

check("post-command normalize caps runs at two newlines [\(show(normalizeAfterCommands("a\n\n\n\nb")))]",
      normalizeAfterCommands("a\n\n\n\nb") == "a\n\nb")

// MARK: - Result

print(failures == 0 ? "SELFTEST: OK" : "SELFTEST: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
