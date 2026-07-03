import CoreGraphics
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

// MARK: - Hotkey binding logic (pure, no key events)

if CommandLine.arguments.contains("--hotkey") {
    // Build CGEventFlags from the standard masks so tests need no live events.
    func flags(_ masks: CGEventFlags...) -> CGEventFlags {
        var out = CGEventFlags()
        for m in masks { out.insert(m) }
        return out
    }

    func roundTrip(_ binding: HotkeyBinding) -> HotkeyBinding? {
        guard let data = try? JSONEncoder().encode(binding),
              let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) else { return nil }
        return decoded
    }

    // --- JSON encode/decode round-trips
    check("modifierHold round-trips through JSON",
          roundTrip(.modifierHold(keyCodes: [61])) == .modifierHold(keyCodes: [61]))
    check("comboToggle round-trips through JSON",
          roundTrip(.comboToggle(keyCode: 2, requiredModifiers: HotkeyBinding.modCommand | HotkeyBinding.modShift))
              == .comboToggle(keyCode: 2, requiredModifiers: HotkeyBinding.modCommand | HotkeyBinding.modShift))
    check("multi-modifier hold round-trips through JSON",
          roundTrip(.modifierHold(keyCodes: [54, 61])) == .modifierHold(keyCodes: [54, 61]))

    // --- Legacy migration
    check("migrate(legacyKeyCode:) wraps the keycode in a hold",
          HotkeyBinding.migrate(legacyKeyCode: 61) == .modifierHold(keyCodes: [61]))
    check("migrate maps Right Control legacy keycode",
          HotkeyBinding.migrate(legacyKeyCode: 62) == .modifierHold(keyCodes: [62]))

    do {
        // Isolated defaults: legacy keycode present, no JSON binding → migrated on load.
        let suite = "localflow-hotkeycheck-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(54, forKey: HotkeyBinding.legacyKeyCodeDefaultsKey)
        check("load() migrates legacy keycode when no JSON binding exists",
              HotkeyBinding.load(from: defaults) == .modifierHold(keyCodes: [54]))

        // Now a JSON binding is present → it wins over the legacy keycode.
        let combo = HotkeyBinding.comboToggle(keyCode: 2, requiredModifiers: HotkeyBinding.modCommand | HotkeyBinding.modShift)
        combo.save(to: defaults)
        check("load() prefers the JSON binding over the legacy keycode",
              HotkeyBinding.load(from: defaults) == combo)

        defaults.removePersistentDomain(forName: suite)
    }

    do {
        // No binding, no legacy keycode → default.
        let defaults = UserDefaults(suiteName: "localflow-hotkeycheck-empty-\(UUID().uuidString)")!
        check("load() falls back to the default when nothing is stored",
              HotkeyBinding.load(from: defaults) == HotkeyBinding.default)
    }

    // --- matchesCombo exact-modifier semantics
    let cmdD = HotkeyBinding.comboToggle(keyCode: 2, requiredModifiers: HotkeyBinding.modCommand)
    let cmdShiftD = HotkeyBinding.comboToggle(keyCode: 2, requiredModifiers: HotkeyBinding.modCommand | HotkeyBinding.modShift)

    check("⌘D fires on ⌘D",
          HotkeyBinding.matchesCombo(eventKeyCode: 2, eventFlags: flags(.maskCommand), binding: cmdD))
    check("⌘D does NOT fire on ⌘⇧D (extra modifier)",
          !HotkeyBinding.matchesCombo(eventKeyCode: 2, eventFlags: flags(.maskCommand, .maskShift), binding: cmdD))
    check("⌘⇧D fires on ⌘⇧D",
          HotkeyBinding.matchesCombo(eventKeyCode: 2, eventFlags: flags(.maskCommand, .maskShift), binding: cmdShiftD))
    check("⌘⇧D does NOT fire on ⌘D (missing modifier)",
          !HotkeyBinding.matchesCombo(eventKeyCode: 2, eventFlags: flags(.maskCommand), binding: cmdShiftD))
    check("combo does NOT fire on a different keycode",
          !HotkeyBinding.matchesCombo(eventKeyCode: 3, eventFlags: flags(.maskCommand), binding: cmdD))
    check("a modifierHold binding never matches as a combo",
          !HotkeyBinding.matchesCombo(eventKeyCode: 2, eventFlags: flags(.maskCommand), binding: .modifierHold(keyCodes: [61])))

    // --- normalize flag math
    check("normalize drops non-generic bits (numeric pad)",
          HotkeyBinding.normalize(flags(.maskCommand, .maskShift, .maskNumericPad))
              == (HotkeyBinding.modCommand | HotkeyBinding.modShift))
    check("normalize of no flags is empty",
          HotkeyBinding.normalize(CGEventFlags()) == 0)
    check("normalize maps all five generic modifiers",
          HotkeyBinding.normalize(flags(.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn))
              == (HotkeyBinding.modCommand | HotkeyBinding.modControl | HotkeyBinding.modOption | HotkeyBinding.modShift | HotkeyBinding.modFn))

    // --- description rendering
    check("single-modifier hold description [\(HotkeyBinding.modifierHold(keyCodes: [61]).description)]",
          HotkeyBinding.modifierHold(keyCodes: [61]).description == "Hold Right Option")
    check("combo description renders ⌘⇧D [\(cmdShiftD.description)]",
          cmdShiftD.description == "⌘⇧D")
    check("multi-modifier hold description [\(HotkeyBinding.modifierHold(keyCodes: [54, 61]).description)]",
          HotkeyBinding.modifierHold(keyCodes: [54, 61]).description == "Hold Right ⌘ + Right ⌥")
    check("bare F-key combo description [\(HotkeyBinding.comboToggle(keyCode: 96, requiredModifiers: 0).description)]",
          HotkeyBinding.comboToggle(keyCode: 96, requiredModifiers: 0).description == "F5")

    // --- validation
    func isValid(_ binding: HotkeyBinding) -> Bool { HotkeyBinding.validate(binding) == .valid }
    check("bare printable key with no modifier is rejected",
          !isValid(.comboToggle(keyCode: 2, requiredModifiers: 0)))
    check("bare F-key is allowed",
          isValid(.comboToggle(keyCode: 96, requiredModifiers: 0)))
    check("⌘V is rejected (paste conflict)",
          !isValid(.comboToggle(keyCode: 9, requiredModifiers: HotkeyBinding.modCommand)))
    check("Space in a combo is rejected",
          !isValid(.comboToggle(keyCode: 49, requiredModifiers: HotkeyBinding.modCommand)))
    check("a normal modifier hold is valid",
          isValid(.modifierHold(keyCodes: [61])))
    check("an empty modifier hold is rejected",
          !isValid(.modifierHold(keyCodes: [])))

    print(failures == 0 ? "HOTKEY: OK" : "HOTKEY: \(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Dictation history + corrections (pure, scratch-dir store)

if CommandLine.arguments.contains("--history") {
    func scratchDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-historycheck-\(UUID().uuidString)", isDirectory: true)
    }

    // --- HistoryStore round-trip: ordering, cap eviction, update, delete, clear
    let dir = scratchDir()
    do {
        let store = HistoryStore(directory: dir)
        for i in 0..<205 { store.append(DictationRecord(text: "r\(i)")) }
        let all = store.all()
        check("append caps history at 200", all.count == HistoryStore.cap)
        check("history is newest-first [\(all.first?.text ?? "nil")]", all.first?.text == "r204")
        check("oldest beyond cap is evicted [\(all.last?.text ?? "nil")]", all.last?.text == "r5")

        // Reload from disk into a fresh store and confirm it persisted.
        let reloaded = HistoryStore(directory: dir)
        check("history round-trips through disk", reloaded.all().count == HistoryStore.cap)
        check("newest-first survives reload", reloaded.all().first?.text == "r204")

        // updateText
        let topID = reloaded.all().first!.id
        reloaded.updateText(id: topID, newText: "r204-edited")
        check("updateText rewrites the record",
              HistoryStore(directory: dir).all().first(where: { $0.id == topID })?.text == "r204-edited")

        // delete
        reloaded.delete(id: topID)
        check("delete removes the record", !reloaded.all().contains(where: { $0.id == topID }))
        check("delete reduces the count on disk", HistoryStore(directory: dir).all().count == HistoryStore.cap - 1)

        // clear
        reloaded.clear()
        check("clear empties in memory", reloaded.all().isEmpty)
        check("clear empties on disk", HistoryStore(directory: dir).all().isEmpty)
    }
    try? FileManager.default.removeItem(at: dir)

    // --- Tokenizer: split on whitespace, punctuation stays attached to the word
    do {
        let toks = DictationHistory.tokenize("please use oh llama.")
        check("tokenizer splits on whitespace, punctuation attached [\(toks.map { $0.text }.joined(separator: "|"))]",
              toks.map { $0.text } == ["please", "use", "oh", "llama."])
    }

    // --- Selected phrase is faithful to the range (verbatim, punctuation kept)
    check("phrase preserves the selected range verbatim [\(DictationHistory.phrase(in: "please use oh llama.", selection: 2...3))]",
          DictationHistory.phrase(in: "please use oh llama.", selection: 2...3) == "oh llama.")

    // --- Record-text range replacement leaves surrounding text intact
    check("applyingCorrection replaces only the selected range [\(DictationHistory.applyingCorrection(to: "please use oh llama for cleanup", selection: 2...3, corrected: "Ollama"))]",
          DictationHistory.applyingCorrection(to: "please use oh llama for cleanup", selection: 2...3, corrected: "Ollama")
              == "please use Ollama for cleanup")

    // --- makeCorrectionRule: punctuation-stripped find, whole-word, case-insensitive
    do {
        let rule = DictationHistory.makeCorrectionRule(original: "llama.", corrected: "Ollama")
        check("rule find strips trailing punctuation [\(rule.find)]", rule.find == "llama")
        check("rule replace is trimmed [\(rule.replace)]", rule.replace == "Ollama")
        check("rule is case-insensitive", rule.caseSensitive == false)
        check("rule is whole-word", rule.wholeWord == true)
    }

    // --- Multi-word phrase rule keeps internal spacing and applies as a phrase
    do {
        let rule = DictationHistory.makeCorrectionRule(original: "Oh llama", corrected: "Ollama")
        check("multi-word rule find keeps internal space [\(rule.find)]", rule.find == "Oh llama")
        let applied = applyReplacements("i said oh llama again", [rule])
        check("multi-word rule auto-corrects future text (case-insensitive) [\(applied)]",
              applied == "i said Ollama again")
    }

    // --- Full correction loop, headlessly: fix a record AND teach the dictionary,
    //     then prove a future dictation auto-corrects. Prints outputs verbatim.
    let loopDir = scratchDir()
    do {
        let store = HistoryStore(directory: loopDir)
        let config = LocalFlowConfig(directory: loopDir)

        store.append(DictationRecord(text: "please use oh llama for cleanup"))
        let record = store.all().first!

        // User selects the "oh llama" chips (token indices 2...3) and types "Ollama".
        let selection = 2...3
        let original = DictationHistory.phrase(in: record.text, selection: selection)
        let corrected = "Ollama"
        let newText = DictationHistory.applyingCorrection(to: record.text, selection: selection, corrected: corrected)

        // "Fix & auto-correct": update the record, add the rule, add the vocab term.
        store.updateText(id: record.id, newText: newText)
        var dictionary = config.dictionary
        dictionary.replacements.append(DictationHistory.makeCorrectionRule(original: original, corrected: corrected))
        dictionary.terms.append(corrected)
        config.dictionary = dictionary

        let updatedText = store.all().first!.text
        let learnedRule = config.dictionary.replacements.contains {
            $0.find.caseInsensitiveCompare("oh llama") == .orderedSame && $0.replace == "Ollama"
        }
        let learnedTerm = config.dictionary.terms.contains { $0.caseInsensitiveCompare("Ollama") == .orderedSame }
        let futureDictation = applyReplacements("i said oh llama again", config.dictionary.replacements)

        print("--- correction loop ---")
        print("selected phrase:        \(original)")
        print("record text after fix:  \(updatedText)")
        print("dictionary has rule:    \(learnedRule)")
        print("dictionary has term:    \(learnedTerm)")
        print("future dictation:       \(futureDictation)")

        check("record text is updated in place", updatedText == "please use Ollama for cleanup")
        check("dictionary learned the replacement rule", learnedRule)
        check("dictionary learned the vocabulary term", learnedTerm)
        check("a future dictation auto-corrects", futureDictation == "i said Ollama again")
    }
    try? FileManager.default.removeItem(at: loopDir)

    print(failures == 0 ? "HISTORY: OK" : "HISTORY: \(failures) FAILURE(S)")
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
