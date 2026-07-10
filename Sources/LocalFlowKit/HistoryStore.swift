import Foundation

/// One saved dictation: the final inserted text plus the context it landed in.
/// Persisted newest-first in history.json so the main window can list, re-copy,
/// and correct past dictations. All fields but `text` are optional so older or
/// hand-edited files still decode.
public struct DictationRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var appName: String?
    public var bundleID: String?
    public var durationSeconds: Double?
    /// The pre-cleanup transcript, kept ONLY when AI cleanup changed the text —
    /// so a bad cleanup is never the sole surviving copy of what was said.
    public var raw: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        durationSeconds: Double? = nil,
        raw: String? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.appName = appName
        self.bundleID = bundleID
        self.durationSeconds = durationSeconds
        self.raw = raw
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, text, appName, bundleID, durationSeconds, raw
    }

    // Tolerant decode: a missing/garbled field never fails the whole history load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        appName = try? c.decodeIfPresent(String.self, forKey: .appName)
        bundleID = try? c.decodeIfPresent(String.self, forKey: .bundleID)
        durationSeconds = try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        raw = try? c.decodeIfPresent(String.self, forKey: .raw)
    }
}

/// The on-disk log of past dictations, backed by history.json under
/// ~/Library/Application Support/LocalFlow. Cached in memory and guarded by a
/// lock so the pipeline can append from the main actor while the main window
/// reads concurrently. Writes are atomic and create the directory on demand.
/// Foundation-only, so the DictCheck CLI can exercise it headlessly.
public final class HistoryStore: @unchecked Sendable {
    public static let shared = HistoryStore()

    /// The newest `cap` records are kept; older ones are dropped on append.
    public static let cap = 200

    private let lock = NSLock()
    private var _records: [DictationRecord]
    private let historyURL: URL
    /// Serializes disk writes in mutation order, so an older snapshot can never
    /// land on disk after a newer one (the writes themselves stay atomic). Writes
    /// are dispatched with `.sync` so the snapshot is flushed to disk BEFORE the
    /// mutation returns: an async write left the most-recent dictation unsaved if
    /// the app quit or crashed right after it (field-reported 2026-07-10 — history
    /// "didn't hold anything"). A per-dictation JSON write is cheap; correctness
    /// beats shaving a millisecond off an already-infrequent path.
    private let saveQueue = DispatchQueue(label: "localflow.history.save", qos: .utility)

    /// `directory` is injectable so tests/CLIs can point at a scratch location.
    public init(directory: URL? = nil) {
        let dir = directory ?? LocalFlowConfig.defaultDirectory()
        historyURL = dir.appendingPathComponent("history.json")
        _records = HistoryStore.load([DictationRecord].self, from: historyURL) ?? []
    }

    /// Adds a record as the newest entry and trims to the cap, dropping the
    /// oldest beyond it. Persists immediately.
    public func append(_ record: DictationRecord) {
        lock.lock()
        _records.insert(record, at: 0)
        if _records.count > HistoryStore.cap {
            _records.removeLast(_records.count - HistoryStore.cap)
        }
        let snapshot = _records
        let url = historyURL
        lock.unlock()
        saveQueue.sync { HistoryStore.save(snapshot, to: url) }
    }

    /// All records, newest first.
    public func all() -> [DictationRecord] {
        lock.lock(); defer { lock.unlock() }
        return _records
    }

    /// Rewrites the text of a single record (used by the in-place corrections).
    public func updateText(id: UUID, newText: String) {
        lock.lock()
        guard let index = _records.firstIndex(where: { $0.id == id }) else {
            lock.unlock(); return
        }
        _records[index].text = newText
        let snapshot = _records
        let url = historyURL
        lock.unlock()
        saveQueue.sync { HistoryStore.save(snapshot, to: url) }
    }

    public func delete(id: UUID) {
        lock.lock()
        _records.removeAll { $0.id == id }
        let snapshot = _records
        let url = historyURL
        lock.unlock()
        saveQueue.sync { HistoryStore.save(snapshot, to: url) }
    }

    public func clear() {
        lock.lock()
        _records = []
        let url = historyURL
        lock.unlock()
        saveQueue.sync { HistoryStore.save([DictationRecord](), to: url) }
    }

    // MARK: - Disk (mirrors LocalFlowConfig's atomic best-effort persistence)

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // The file exists but won't decode (real corruption, or a partial write
            // from an older non-atomic version). Returning nil makes the caller fall
            // back to an EMPTY value — and the next mutation would then overwrite this
            // file, silently destroying recoverable data. Quarantine it alongside as
            // ".corrupt" first so nothing is lost and it can be recovered.
            let quarantine = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return nil
        }
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            // Persistence is best-effort; an unwritable dir must never crash a
            // dictation. The in-memory cache remains authoritative.
        }
    }
}

/// One word from a dictation, punctuation kept attached, plus its range in the
/// source string. Chips in the correction UI are these tokens.
public struct HistoryToken: Equatable, Sendable {
    public let text: String
    public let range: Range<String.Index>

    public init(text: String, range: Range<String.Index>) {
        self.text = text
        self.range = range
    }
}

/// Pure helpers for the in-place correction flow. Kept out of the UI so the
/// tokenizer, punctuation stripping, and rule building are all selftestable.
public enum DictationHistory {
    /// Splits on whitespace runs, keeping punctuation attached to its word, and
    /// records each token's range so a selection can be mapped back to the text.
    public static func tokenize(_ text: String) -> [HistoryToken] {
        var tokens: [HistoryToken] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            let start = i
            while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
            tokens.append(HistoryToken(text: String(text[start..<i]), range: start..<i))
        }
        return tokens
    }

    /// The exact substring spanned by a contiguous token selection, verbatim
    /// (internal spacing and punctuation preserved). Empty if out of range.
    public static func phrase(in text: String, selection: ClosedRange<Int>) -> String {
        let tokens = tokenize(text)
        guard selection.lowerBound >= 0, selection.upperBound < tokens.count else { return "" }
        let lower = tokens[selection.lowerBound].range.lowerBound
        let upper = tokens[selection.upperBound].range.upperBound
        return String(text[lower..<upper])
    }

    /// Replaces the selected token span with `corrected`, faithful to the range
    /// (so "llama." → "Ollama" leaves the surrounding text untouched). Returns
    /// the text unchanged if the selection is out of range.
    public static func applyingCorrection(to text: String, selection: ClosedRange<Int>, corrected: String) -> String {
        let tokens = tokenize(text)
        guard selection.lowerBound >= 0, selection.upperBound < tokens.count else { return text }
        let lower = tokens[selection.lowerBound].range.lowerBound
        let upper = tokens[selection.upperBound].range.upperBound
        var copy = text
        copy.replaceSubrange(lower..<upper, with: corrected)
        return copy
    }

    /// Trims surrounding whitespace and leading/trailing punctuation/symbols,
    /// keeping internal spacing. Selecting "llama." yields "llama"; "Oh llama"
    /// stays "Oh llama".
    public static func strippedPhrase(_ phrase: String) -> String {
        let strippable = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return phrase.trimmingCharacters(in: strippable)
    }

    /// Builds the hard replacement a correction teaches the personal dictionary:
    /// case-insensitive, whole-word, with the `find` stripped of surrounding
    /// punctuation so it matches future dictations of the same word/phrase.
    public static func makeCorrectionRule(original: String, corrected: String) -> Replacement {
        Replacement(
            find: strippedPhrase(original),
            replace: corrected.trimmingCharacters(in: .whitespacesAndNewlines),
            caseSensitive: false,
            wholeWord: true
        )
    }
}
