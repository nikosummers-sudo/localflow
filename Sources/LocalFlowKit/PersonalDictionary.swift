import Foundation

/// A deterministic find/replace applied to the FINAL transcript. Unlike the STT
/// vocabulary bias (a soft hint), a replacement is a hard rewrite — used to force
/// a spelling the model reliably gets wrong ("triptease" -> "Triptease").
public struct Replacement: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var find: String
    public var replace: String
    /// When false (default), matching ignores case.
    public var caseSensitive: Bool
    /// When true (default), only whole-word matches are replaced, so "period"
    /// never corrupts "periodic".
    public var wholeWord: Bool

    public init(
        id: UUID = UUID(),
        find: String,
        replace: String,
        caseSensitive: Bool = false,
        wholeWord: Bool = true
    ) {
        self.id = id
        self.find = find
        self.replace = replace
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }

    private enum CodingKeys: String, CodingKey {
        case id, find, replace, caseSensitive, wholeWord
    }

    // Tolerant decode: hand-edited or older files may omit id/flags. Missing
    // fields fall back to sensible defaults rather than failing the whole load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        find = (try? c.decode(String.self, forKey: .find)) ?? ""
        replace = (try? c.decode(String.self, forKey: .replace)) ?? ""
        caseSensitive = (try? c.decode(Bool.self, forKey: .caseSensitive)) ?? false
        wholeWord = (try? c.decode(Bool.self, forKey: .wholeWord)) ?? true
    }
}

/// The user's personal vocabulary. `terms` bias the speech-to-text model (a soft
/// prompt hint) and are listed for the cleanup model to preserve; `replacements`
/// are hard rewrites applied to the final text.
public struct PersonalDictionary: Codable, Sendable, Equatable {
    public var terms: [String]
    public var replacements: [Replacement]

    public init(terms: [String] = [], replacements: [Replacement] = []) {
        self.terms = terms
        self.replacements = replacements
    }

    private enum CodingKeys: String, CodingKey { case terms, replacements }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terms = (try? c.decode([String].self, forKey: .terms)) ?? []
        replacements = (try? c.decode([Replacement].self, forKey: .replacements)) ?? []
    }
}

/// Per-app overrides, keyed by bundle id. A nil override means "inherit the
/// global setting"; a non-nil value wins for dictations that start in that app.
public struct AppRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    /// nil = inherit global cleanup toggle; true/false = force on/off for this app.
    public var cleanupEnabled: Bool?
    /// nil/empty = no override; otherwise appended to the cleanup system prompt so
    /// the model matches this app's register (e.g. a casual Slack tone).
    public var toneAddendum: String?
    /// nil or "auto" = detect whether the focused element accepts text before
    /// pasting; "paste" = always paste in this app. The escape hatch for apps
    /// (some Electron ones) that hide their inputs from macOS accessibility.
    public var insertionMode: String?

    /// True when this rule forces pasting without focus detection.
    public var alwaysPaste: Bool { insertionMode == "paste" }

    public init(
        id: UUID = UUID(),
        bundleID: String,
        appName: String,
        cleanupEnabled: Bool? = nil,
        toneAddendum: String? = nil,
        insertionMode: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.cleanupEnabled = cleanupEnabled
        self.toneAddendum = toneAddendum
        self.insertionMode = insertionMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleID, appName, cleanupEnabled, toneAddendum, insertionMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        bundleID = (try? c.decode(String.self, forKey: .bundleID)) ?? ""
        appName = (try? c.decode(String.self, forKey: .appName)) ?? ""
        cleanupEnabled = try? c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled)
        toneAddendum = try? c.decodeIfPresent(String.self, forKey: .toneAddendum)
        insertionMode = try? c.decodeIfPresent(String.self, forKey: .insertionMode)
    }
}

/// Applies the user's hard replacements to `text`, in order. Pure and offline so
/// it can be unit-tested without a model. Each replacement is a regex built from
/// the (regex-escaped) `find`, wrapped in `\b…\b` for whole-word matches and made
/// case-insensitive unless flagged otherwise. The `replace` string is inserted
/// literally (its `$`/`\` are escaped), so it can never be read as a template.
public func applyReplacements(_ text: String, _ replacements: [Replacement]) -> String {
    var result = text
    for replacement in replacements {
        let find = replacement.find
        guard !find.isEmpty else { continue }

        var options: NSRegularExpression.Options = []
        if !replacement.caseSensitive { options.insert(.caseInsensitive) }

        let escaped = NSRegularExpression.escapedPattern(for: find)
        let pattern = replacement.wholeWord ? "\\b\(escaped)\\b" : escaped
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }

        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        let template = NSRegularExpression.escapedTemplate(for: replacement.replace)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
    }
    return result
}
