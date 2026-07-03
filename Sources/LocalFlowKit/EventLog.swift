import Foundation

/// Lightweight append-only diagnostic logger. Writes one timestamped line per
/// event to ~/Library/Logs/LocalFlow.log so a field issue can be diagnosed from
/// the log alone.
///
/// PRIVACY — this log NEVER contains dictated content. No transcript text, no
/// personal-vocabulary terms, no audio samples: only structured events, mode and
/// outcome labels, durations, counts, RMS levels, and error *descriptions* (from
/// Swift `Error` values, which carry engine/IO messages, not transcripts). Callers
/// must uphold this contract — pass counts and labels, never dictated words.
///
/// Thread-safe: line composition is cheap and done on the caller's thread; all file
/// IO is serialized on a private queue. The file self-trims to `trimTo` lines once
/// it exceeds `maxLines` (mirroring Scripts/auto-update.sh's rotation), so it can
/// never grow unbounded.
public enum EventLog {
    /// Trim trigger and target — matches the log rotation in auto-update.sh.
    public static let maxLines = 500
    public static let trimTo = 250

    private static let queue = DispatchQueue(label: "com.localflow.eventlog")

    // MARK: - Public API

    /// Records one event. Fire-and-forget: composes the line now, writes it off-thread,
    /// and never throws to the caller. `fields` render as space-separated key=value
    /// pairs (keys sorted for stable, greppable output).
    public static func log(_ event: String, _ fields: [String: String] = [:]) {
        let line = composeLine(event: event, fields: fields, date: Date())
        let url = defaultURL()
        queue.async { appendAndTrim(line: line, url: url) }
    }

    /// The log file location: ~/Library/Logs/LocalFlow.log.
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("LocalFlow.log")
    }

    // MARK: - Testable pieces (pure / synchronous)

    /// Composes a single-line record: "<iso8601> <event> key=value key=value…".
    /// Every field is flattened to one line so the log stays one-record-per-line.
    /// Exposed for tests; the app calls `log`.
    public static func composeLine(event: String, fields: [String: String], date: Date) -> String {
        // A fresh formatter per call sidesteps ISO8601DateFormatter's lack of thread
        // safety; at our event rate the cost is negligible.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var parts = ["\(formatter.string(from: date)) \(flatten(event))"]
        for key in fields.keys.sorted() {
            parts.append("\(flatten(key))=\(flatten(fields[key] ?? ""))")
        }
        return parts.joined(separator: " ")
    }

    /// Appends `line` to `url`, creating the directory if needed, then trims the file
    /// to `trimTo` lines when it exceeds `maxLines`. Synchronous; exposed for tests.
    /// Best-effort — any IO failure is swallowed (diagnostics must never break dictation).
    public static func appendAndTrim(line: String, url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let entry = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: entry)
        } else {
            try? entry.write(to: url)
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }  // drop the trailing-newline artifact
        guard lines.count > maxLines else { return }
        let trimmed = lines.suffix(trimTo).joined(separator: "\n") + "\n"
        try? Data(trimmed.utf8).write(to: url)
    }

    // MARK: - Private

    private static func flatten(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
         .replacingOccurrences(of: "\t", with: " ")
    }
}
