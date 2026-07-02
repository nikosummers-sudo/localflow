import Foundation

/// The on-disk home for user configuration that lives outside UserDefaults: the
/// personal dictionary and the per-app rules. Backed by two JSON files under
/// ~/Library/Application Support/LocalFlow. Cached in memory and guarded by a
/// lock so it is safe to read from the transcription actors and write from the
/// Settings UI concurrently. Writes are atomic and create the directory on demand.
///
/// Foundation-only so both the app and the light CLIs can share it.
public final class LocalFlowConfig: @unchecked Sendable {
    public static let shared = LocalFlowConfig()

    private let lock = NSLock()
    private var _dictionary: PersonalDictionary
    private var _appRules: [AppRule]

    private let dictionaryURL: URL
    private let appRulesURL: URL

    /// `directory` is injectable so tests/CLIs can point at a scratch location.
    public init(directory: URL? = nil) {
        let dir = directory ?? LocalFlowConfig.defaultDirectory()
        dictionaryURL = dir.appendingPathComponent("dictionary.json")
        appRulesURL = dir.appendingPathComponent("apps.json")
        _dictionary = LocalFlowConfig.load(PersonalDictionary.self, from: dictionaryURL) ?? PersonalDictionary()
        _appRules = LocalFlowConfig.load([AppRule].self, from: appRulesURL) ?? []
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LocalFlow", isDirectory: true)
    }

    // MARK: - Personal dictionary

    /// Reads/writes the whole dictionary. Setting persists to disk immediately.
    public var dictionary: PersonalDictionary {
        get { lock.lock(); defer { lock.unlock() }; return _dictionary }
        set {
            lock.lock()
            _dictionary = newValue
            let url = dictionaryURL
            lock.unlock()
            LocalFlowConfig.save(newValue, to: url)
        }
    }

    /// The vocabulary terms alone, for the STT bias prompt on a hot path.
    public func currentTerms() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return _dictionary.terms
    }

    // MARK: - Per-app rules

    public var appRules: [AppRule] {
        get { lock.lock(); defer { lock.unlock() }; return _appRules }
        set {
            lock.lock()
            _appRules = newValue
            let url = appRulesURL
            lock.unlock()
            LocalFlowConfig.save(newValue, to: url)
        }
    }

    public func rule(forBundleID bundleID: String) -> AppRule? {
        lock.lock(); defer { lock.unlock() }
        return _appRules.first { $0.bundleID == bundleID }
    }

    // MARK: - Reload from disk

    /// Re-reads both files into the cache. Used when another process/editor may
    /// have changed them out from under us.
    public func reload() {
        let dict = LocalFlowConfig.load(PersonalDictionary.self, from: dictionaryURL) ?? PersonalDictionary()
        let rules = LocalFlowConfig.load([AppRule].self, from: appRulesURL) ?? []
        lock.lock()
        _dictionary = dict
        _appRules = rules
        lock.unlock()
    }

    // MARK: - Disk

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
            // Persistence is best-effort; an unwritable Application Support dir must
            // never crash a dictation. The in-memory cache remains authoritative.
        }
    }
}
