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

// MARK: - Input device enumeration (proves the CoreAudio path finds real devices)

if CommandLine.arguments.contains("--devices") {
    let devices = InputDevices.all()
    print("INPUT DEVICES (\(devices.count)):")
    for d in devices {
        print("  \(d.name)  [uid=\(d.uid)]  id=\(d.id)")
    }
    print(devices.isEmpty ? "DEVICES: NONE FOUND" : "DEVICES: OK")
    exit(devices.isEmpty ? 1 : 0)
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
        AppRule(bundleID: "com.apple.mail", appName: "Mail"), // nil overrides = inherit
        AppRule(bundleID: "com.anthropic.claudefordesktop", appName: "Claude",
                insertionMode: "paste")
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
    check("insertionMode round-trips through disk",
          reloaded.rule(forBundleID: "com.anthropic.claudefordesktop")?.alwaysPaste == true)
    check("missing insertionMode decodes to nil (auto)",
          reloaded.rule(forBundleID: "com.apple.mail")?.insertionMode == nil
          && reloaded.rule(forBundleID: "com.apple.mail")?.alwaysPaste == false)

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

    // --- fn-bit consistency on function-type keys
    // AppKit sets the fn/function flag automatically on arrows, F-keys, Home/End,
    // etc. Internal keyboards carry it in CGEvents too; external keyboards often
    // don't. A combo on one of those keys must match with OR without the implicit
    // fn bit — else a shortcut recorded on the laptop dies on an external keyboard
    // (and vice versa), which reads as "changed the shortcut, nothing happens".
    let rightArrow: Int64 = 124
    let comboWithImplicitFn = HotkeyBinding.comboToggle(
        keyCode: rightArrow, requiredModifiers: HotkeyBinding.modCommand | HotkeyBinding.modFn)
    let comboClean = HotkeyBinding.comboToggle(
        keyCode: rightArrow, requiredModifiers: HotkeyBinding.modCommand)
    check("⌘→ recorded WITH implicit fn fires on an event WITHOUT fn",
          HotkeyBinding.matchesCombo(eventKeyCode: rightArrow, eventFlags: flags(.maskCommand), binding: comboWithImplicitFn))
    check("⌘→ recorded WITH implicit fn fires on an event WITH fn",
          HotkeyBinding.matchesCombo(eventKeyCode: rightArrow, eventFlags: flags(.maskCommand, .maskSecondaryFn), binding: comboWithImplicitFn))
    check("⌘→ recorded clean fires on an event WITH fn",
          HotkeyBinding.matchesCombo(eventKeyCode: rightArrow, eventFlags: flags(.maskCommand, .maskSecondaryFn), binding: comboClean))
    check("fn is still a REAL modifier on a normal key: fn+D does not fire on bare D",
          !HotkeyBinding.matchesCombo(eventKeyCode: 2, eventFlags: CGEventFlags(), binding: .comboToggle(keyCode: 2, requiredModifiers: HotkeyBinding.modFn)))
    check("fn+D fires on fn+D",
          HotkeyBinding.matchesCombo(eventKeyCode: 2, eventFlags: flags(.maskSecondaryFn), binding: .comboToggle(keyCode: 2, requiredModifiers: HotkeyBinding.modFn)))
    check("normalizedModifiers strips fn for a function-type key",
          HotkeyBinding.normalizedModifiers(forKeyCode: rightArrow, flags: flags(.maskCommand, .maskSecondaryFn))
              == HotkeyBinding.modCommand)
    check("normalizedModifiers keeps fn for a normal key",
          HotkeyBinding.normalizedModifiers(forKeyCode: 2, flags: flags(.maskSecondaryFn))
              == HotkeyBinding.modFn)

    // --- load() self-heals an invalid persisted binding
    // Persisted state survives reinstall + tccutil reset; a bad binding written by
    // any past build must never leave the hotkey permanently dead. Invalid → default.
    do {
        let suite = "localflow-hotkeycheck-invalid-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let bad = try? JSONEncoder().encode(HotkeyBinding.modifierHold(keyCodes: [])) {
            defaults.set(bad, forKey: HotkeyBinding.defaultsKey)
        }
        check("load() falls back to default on an invalid persisted binding (empty hold)",
              HotkeyBinding.load(from: defaults) == HotkeyBinding.default)

        if let badCombo = try? JSONEncoder().encode(HotkeyBinding.comboToggle(keyCode: 49, requiredModifiers: 0)) {
            defaults.set(badCombo, forKey: HotkeyBinding.defaultsKey)
        }
        check("load() falls back to default on an invalid persisted binding (bare Space combo)",
              HotkeyBinding.load(from: defaults) == HotkeyBinding.default)
        defaults.removePersistentDomain(forName: suite)
    }

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

// MARK: - AudioGate: pure silence/speech gate (no mic, model, or network)

if CommandLine.arguments.contains("--audio") {
    let sr = 16000.0

    // Deterministic tone generator. A steady sine is a fair stand-in for a voiced
    // frame's energy; its RMS is amplitude / √2.
    func sine(amplitude: Float, freq: Double, seconds: Double, sampleRate: Double = 16000) -> [Float] {
        let n = Int(seconds * sampleRate)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let w = 2 * Double.pi * freq / sampleRate
        for i in 0..<n { out[i] = amplitude * Float(sin(w * Double(i))) }
        return out
    }

    func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * sr)) }

    // Overlays `tone` onto a silent buffer starting at `atSeconds`.
    func burst(toneAmplitude: Float, toneSeconds: Double, atSeconds: Double, totalSeconds: Double) -> [Float] {
        var out = silence(totalSeconds)
        let tone = sine(amplitude: toneAmplitude, freq: 220, seconds: toneSeconds, sampleRate: sr)
        let start = Int(atSeconds * sr)
        for (j, s) in tone.enumerated() where start + j < out.count { out[start + j] = s }
        return out
    }

    // 1) Pure silence — the true denied/muted-mic case.
    let zeros = silence(3)
    check("all-zero (silent) audio has no speech", AudioGate.containsSpeech(zeros, sampleRate: sr) == false)
    check("all-zero maxFrameRMS is 0 [\(AudioGate.maxFrameRMS(zeros, sampleRate: sr))]",
          AudioGate.maxFrameRMS(zeros, sampleRate: sr) == 0)

    // 2) Low-level 0.001-amplitude tone (~0.0007 RMS) — below the gate.
    let low = sine(amplitude: 0.001, freq: 200, seconds: 3, sampleRate: sr)
    check("low-level 0.001-amplitude audio is below the speech gate",
          AudioGate.containsSpeech(low, sampleRate: sr) == false)
    check("low-level maxFrameRMS stays under threshold [\(AudioGate.maxFrameRMS(low, sampleRate: sr))]",
          AudioGate.maxFrameRMS(low, sampleRate: sr) < AudioGate.speechThreshold)

    // 3) A 0.5s 0.05-amplitude burst (~0.035 RMS) inside 3s of silence — speech.
    let oneBurst = burst(toneAmplitude: 0.05, toneSeconds: 0.5, atSeconds: 1.0, totalSeconds: 3.0)
    check("a 0.5s speech-level burst within silence counts as speech",
          AudioGate.containsSpeech(oneBurst, sampleRate: sr) == true)
    check("burst maxFrameRMS is above the speech threshold [\(AudioGate.maxFrameRMS(oneBurst, sampleRate: sr))]",
          AudioGate.maxFrameRMS(oneBurst, sampleRate: sr) > AudioGate.speechThreshold)

    // 4) Speech-like alternating voiced/silent bursts — speech.
    var speechLike: [Float] = []
    for _ in 0..<4 {
        speechLike += sine(amplitude: 0.05, freq: 180, seconds: 0.3, sampleRate: sr)
        speechLike += silence(0.2)
    }
    check("speech-like alternating bursts count as speech",
          AudioGate.containsSpeech(speechLike, sampleRate: sr) == true)

    // 5) A sub-0.3s blip is loud but too brief to clear the 3-frame minimum.
    let blip = burst(toneAmplitude: 0.05, toneSeconds: 0.1, atSeconds: 0.4, totalSeconds: 1.0)
    check("a loud but sub-0.3s blip does not trip the speech gate",
          AudioGate.containsSpeech(blip, sampleRate: sr) == false)
    check("blip maxFrameRMS still reports the loud frame [\(AudioGate.maxFrameRMS(blip, sampleRate: sr))]",
          AudioGate.maxFrameRMS(blip, sampleRate: sr) > AudioGate.speechThreshold)

    print(failures == 0 ? "AUDIO: OK" : "AUDIO: \(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - EventLog: single-line records, rotation, no dictated content

if CommandLine.arguments.contains("--log") {
    let epoch = Date(timeIntervalSince1970: 0)

    // Line format: ISO timestamp + event + sorted key=value fields, one line.
    let line = EventLog.composeLine(
        event: "dictation.stop",
        fields: ["duration": "1.20", "samples": "19200", "maxRMS": "0.031"],
        date: epoch)
    check("event line is single-line", !line.contains("\n"))
    check("event line starts with an ISO timestamp [\(line.prefix(20))]",
          line.hasPrefix("1970-01-01T00:00:00Z"))
    check("event line carries the event name and every field [\(line)]",
          line.contains("dictation.stop")
              && line.contains("duration=1.20")
              && line.contains("maxRMS=0.031")
              && line.contains("samples=19200"))

    // Newlines/tabs in any value are flattened so one event == one line.
    let flat = EventLog.composeLine(event: "x", fields: ["k": "a\nb\tc"], date: epoch)
    check("field values are flattened to one line [\(flat)]",
          !flat.contains("\n") && !flat.contains("\t") && flat.contains("k=a b c"))

    // Append + rotation: crossing maxLines trims to trimTo, keeping the newest.
    // Appending exactly maxLines+1 lands cleanly on a single trim.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("localflow-logcheck-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let logURL = dir.appendingPathComponent("LocalFlow.log")
    let total = EventLog.maxLines + 1
    for i in 0..<total { EventLog.appendAndTrim(line: "line\(i)", url: logURL) }
    func logLines() -> [String] {
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        var ls = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if ls.last == "" { ls.removeLast() }
        return ls
    }
    let lines = logLines()
    check("log rotates down to trimTo lines when it crosses the cap [\(lines.count)]",
          lines.count == EventLog.trimTo)
    check("log keeps the most recent line after rotation [\(lines.last ?? "nil")]",
          lines.last == "line\(total - 1)")
    check("log drops the oldest lines after rotation [\(lines.first ?? "nil")]",
          lines.first == "line\(total - EventLog.trimTo)")

    // Invariant: further appends never let the file exceed maxLines.
    for i in total..<(total + 400) { EventLog.appendAndTrim(line: "line\(i)", url: logURL) }
    check("log stays bounded at/under maxLines after more appends [\(logLines().count)]",
          logLines().count <= EventLog.maxLines)
    try? FileManager.default.removeItem(at: dir)

    print(failures == 0 ? "LOG: OK" : "LOG: \(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Transcript cleanup post-guards (pure, no Ollama)

// applyGuards decides whether the model's output replaces the raw transcript. The
// guards below reject same-length refusals, heavy rewrites, and dropped command
// tokens — cases the old length-ratio check let through. All pure, no network.
if CommandLine.arguments.contains("--cleaner") {
    typealias TC = TranscriptCleaner
    let NL = VoiceCommand.newLinePlaceholder

    // 1) A same-length refusal must fall back to raw. Length ratio here is ~0.9,
    //    so it's the refusal guard — not the length guard — that catches it.
    do {
        let raw = "please buy some milk and also grab a dozen eggs today."
        let refusal = "I'm sorry, but I can't assist with that request."
        check("refusal opener is detected", TC.isRefusal(refusal))
        check("same-length refusal falls back to raw",
              TC.applyGuards(cleaned: refusal, raw: raw).text == raw)
    }

    // 2) A light rephrase (high word-set overlap) is accepted as the cleaned text.
    do {
        let raw = "um so i think we should probably ship the thing on friday you know"
        let cleaned = "So I think we should probably ship the thing on Friday."
        check("light rephrase has high overlap [\(TC.wordSetJaccard(raw, cleaned))]",
              TC.wordSetJaccard(raw, cleaned) >= 0.35)
        check("light rephrase is accepted (returns cleaned)",
              TC.applyGuards(cleaned: cleaned, raw: raw).text == cleaned)
    }

    // 3) A heavy rewrite (≥8 distinct raw words, near-zero overlap) falls back to raw.
    do {
        let raw = "the quarterly sales figures exceeded our internal projections by a wide margin"
        let rewrite = "please remember to water the office plants every single morning without fail"
        check("heavy rewrite has low overlap [\(TC.wordSetJaccard(raw, rewrite))]",
              TC.wordSetJaccard(raw, rewrite) < 0.35)
        check("heavy rewrite falls back to raw",
              TC.applyGuards(cleaned: rewrite, raw: raw).text == raw)
    }

    // 4) A dropped command placeholder falls back to raw even when words overlap.
    do {
        let raw = "buy milk \(NL) buy eggs \(NL) buy bread and some butter too please"
        let cleaned = "Buy milk \(NL) buy eggs buy bread and some butter too please."
        check("placeholder count mismatch is detected",
              !TC.placeholdersSurvived(raw: raw, output: cleaned))
        check("dropped placeholder falls back to raw",
              TC.applyGuards(cleaned: cleaned, raw: raw).text == raw)
    }

    // 5) Equal placeholder counts + light cleanup pass through as the cleaned text.
    do {
        let raw = "buy milk \(NL) buy eggs and some bread and butter too please"
        let cleaned = "Buy milk \(NL) buy eggs and some bread and butter too please."
        check("placeholder counts equal survives the guard",
              TC.placeholdersSurvived(raw: raw, output: cleaned))
        check("equal placeholders + light cleanup returns cleaned",
              TC.applyGuards(cleaned: cleaned, raw: raw).text == cleaned)
    }

    // 6) Refine mode: heavy condensing is ALLOWED (that's the point) — the same
    //    output clean mode would reject on the length ratio passes in refine.
    do {
        let raw = "so um what i want to say is i think basically we should probably just go ahead "
            + "and ship the new feature on friday because you know i think it's ready and um "
            + "we've tested it quite a lot already so yeah let's ship the feature friday"
        let refined = "I think we should ship the new feature on Friday — it's ready and well tested."
        let ratio = Double(refined.count) / Double(raw.count)
        check("refine condensing ratio is below clean's floor [\(String(format: "%.2f", ratio))]",
              ratio < 0.5)
        check("clean mode rejects heavy condensing",
              TC.applyGuards(cleaned: refined, raw: raw, mode: .clean).text == raw)
        check("refine mode accepts heavy condensing",
              TC.applyGuards(cleaned: refined, raw: raw, mode: .refine).text == refined)
    }

    // 7) Refine still rejects a wholesale rewrite (near-zero overlap).
    do {
        let raw = "the quarterly sales figures exceeded our internal projections by a wide margin overall"
        let rewrite = "remember to water the office plants every single morning without fail thanks"
        check("refine mode still rejects wholesale rewrites",
              TC.applyGuards(cleaned: rewrite, raw: raw, mode: .refine).text == raw)
    }

    // 8) Dropped numbers fall back in BOTH modes — digits are load-bearing.
    do {
        let raw = "let's meet at 3 pm in room 204 to review the 45 thousand pound proposal together"
        let dropped = "Let's meet at 3 pm in room 204 to review the proposal together."
        let kept = "Let's meet at 3 pm in room 204 to review the 45k proposal together."
        check("numbersSurvived detects a dropped digit-run", !TC.numbersSurvived(raw: raw, output: dropped))
        check("dropped number falls back to raw (refine)",
              TC.applyGuards(cleaned: dropped, raw: raw, mode: .refine).text == raw)
        check("all digit-runs present passes", TC.numbersSurvived(raw: raw, output: kept))
        check("no digits anywhere passes trivially", TC.numbersSurvived(raw: "no numbers here", output: "none there either"))
    }

    // 9) Mode picks the right system prompt; both keep the placeholder rule.
    do {
        let refineCtx = CleanupContext(includePlaceholderRule: true, mode: .refine)
        let cleanCtx = CleanupContext(includePlaceholderRule: true, mode: .clean)
        check("refine context uses the refine prompt",
              TC.systemPrompt(context: refineCtx).hasPrefix("You are a dictation refinement engine"))
        check("clean context uses the clean prompt",
              TC.systemPrompt(context: cleanCtx).hasPrefix("You are a dictation cleanup engine"))
        check("refine prompt keeps the protected-token rule",
              TC.systemPrompt(context: refineCtx).contains("PROTECTED TOKENS"))
    }

    // 10) Refine budget scales with input size inside hard bounds.
    do {
        check("short text gets the floor budget",
              TC.refineBudgetSeconds(for: String(repeating: "a", count: 100)) == 6.0)
        check("long text gets a scaled budget",
              TC.refineBudgetSeconds(for: String(repeating: "a", count: 1_500)) == 10.0)
        check("budget is capped at 20s",
              TC.refineBudgetSeconds(for: String(repeating: "a", count: 100_000)) == 20.0)
    }

    print(failures == 0 ? "CLEANER: OK" : "CLEANER: \(failures) FAILURE(S)")
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

// NO retraction command: "scratch that" was removed after field testing (its
// deletion scope depended on STT-chosen sentence boundaries). The phrase must
// now pass through as ordinary content.
check("'scratch that' is ordinary content, not a command [\(show(pipeline("I like dogs. scratch that")))]",
      pipeline("I like dogs. scratch that").contains("scratch that"))

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
    let encoded = encodeCommands("a new line b new paragraph c new bullet d")
    check("encode emits the exact placeholder tokens",
          encoded.contains(VoiceCommand.newLinePlaceholder)
              && encoded.contains(VoiceCommand.newParagraphPlaceholder)
              && encoded.contains(VoiceCommand.bulletPlaceholder))
}

// "new bullet" produces a deterministic "- " line — no model judgment.
do {
    let out = normalizeAfterCommands(decodeCommands(encodeCommands(
        "things to do new bullet update the website new bullet email customers new bullet post in slack")))
    check("new bullet command renders '- ' lines [\(show(out))]",
          out == "things to do\n- update the website\n- email customers\n- post in slack")
}

// The phrase "bullet point" spoken as CONTENT must pass through untouched —
// field-reported: it fired as a command mid-sentence and broke the dictation.
do {
    let content = "maybe make a bullet point list to see what it looks like"
    check("spoken 'bullet point' as content is NOT a command [\(show(encodeCommands(content)))]",
          encodeCommands(content) == content)
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
