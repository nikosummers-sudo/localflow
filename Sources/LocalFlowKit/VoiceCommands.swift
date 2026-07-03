import Foundation

/// Placeholder tokens used to carry spoken commands through the cleanup model
/// intact. Spoken phrases are replaced with these on the RAW transcript (before
/// cleanup), the cleanup prompt is told to preserve them verbatim, and they are
/// decoded into their real effect on the final assembled text. Using unusual
/// bracket characters (U+27E6 / U+27E7) keeps them from colliding with dictation.
public enum VoiceCommand {
    public static let newLinePlaceholder = "\u{27E6}NL\u{27E7}"        // ⟦NL⟧
    public static let newParagraphPlaceholder = "\u{27E6}PP\u{27E7}"   // ⟦PP⟧
    public static let bulletPlaceholder = "\u{27E6}BP\u{27E7}"         // ⟦BP⟧
}

// NOTE: there is deliberately NO retraction command ("scratch that"). It was
// built, field-tested, and REMOVED: its blast radius depends on sentence
// boundaries the STT model chose (invisible to the speaker), so it sometimes
// deleted more or less than intended — a destructive command with
// unpredictable scope is worse than no command. The surviving commands are
// insert-only: their worst failure is a visible stray line break.

/// Replaces spoken command phrases in RAW transcript text with placeholder
/// tokens. Matching is whole-word and case-insensitive, and tolerates a single
/// trailing comma or period the speaker's pause may have produced ("new line.").
/// Pure and offline. If the terms list changes, keep phrases here in sync.
public func encodeCommands(_ text: String) -> String {
    var s = text
    // "new paragraph" is matched before "new line" for deterministic order; the
    // phrases do not overlap, so the result is the same either way.
    s = replacePhrase(s, phrase: "new paragraph", with: VoiceCommand.newParagraphPlaceholder)
    s = replacePhrase(s, phrase: "new line", with: VoiceCommand.newLinePlaceholder)
    // Deterministic list formatting: "new bullet" starts a "- " line, exactly,
    // every time — no model judgment involved. Deliberately NOT "bullet point":
    // that phrase appears constantly in normal speech ("make a bullet point
    // list") and fired as a command mid-sentence (field-reported). "New bullet"
    // matches the "new line"/"new paragraph" family and never occurs as content.
    s = replacePhrase(s, phrase: "new bullet", with: VoiceCommand.bulletPlaceholder)
    return s
}

private func replacePhrase(_ text: String, phrase: String, with placeholder: String) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: phrase)
    let pattern = "\\b\(escaped)\\b[.,]?"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let template = NSRegularExpression.escapedTemplate(for: placeholder)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
}

/// Turns placeholder tokens back into their real effect on the FINAL text.
/// All surviving commands are insert-only. Pure and offline.
public func decodeCommands(_ text: String) -> String {
    var result = text.replacingOccurrences(of: VoiceCommand.newParagraphPlaceholder, with: "\n\n")
    result = result.replacingOccurrences(of: VoiceCommand.newLinePlaceholder, with: "\n")
    result = result.replacingOccurrences(of: VoiceCommand.bulletPlaceholder, with: "\n- ")
    return result
}

/// Collapses runs of spaces/tabs to a single space while PRESERVING newlines, and
/// trims spaces hugging line breaks. Used where the text may already contain
/// intentional newlines (voice commands), so plain whitespace-collapsing would
/// destroy them.
public func normalizeInlineWhitespace(_ text: String) -> String {
    let collapsed = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    let tidied = collapsed.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
    return tidied.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Final tidy applied AFTER commands are decoded into real newlines: collapses
/// inline space runs, strips spaces around newlines, and caps consecutive
/// newlines at two (so a stray "new paragraph" run never explodes into blank
/// space). Pure and offline.
public func normalizeAfterCommands(_ text: String) -> String {
    var s = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
