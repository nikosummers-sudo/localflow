import Foundation
import LocalFlowKit

/// Per-chunk timing, collected for the StreamCheck CLI's evidence table.
public struct ChunkTiming: Sendable {
    public let audioSeconds: Double
    public let sttMs: Double
    public var cleanupMs: Double?
}

/// The finished streamed transcription plus timing telemetry.
public struct StreamResult: Sendable {
    public let text: String
    /// Non-nil when the post-release tail cleanup fell back to raw (surfaced to
    /// the user exactly like the existing single-pass path does).
    public let note: String?
    public let chunkTimings: [ChunkTiming]
    public let tailAudioSeconds: Double
    public let tailSttMs: Double
    public let tailCleanupMs: Double
}

/// Transcribes and cleans a dictation IN CHUNKS while the user is still talking,
/// so key-release only has to process the short tail. The same instance drives
/// both the app (live mic) and the StreamCheck CLI (file playback) via the
/// `StreamAudioSource` protocol.
///
/// Lifecycle:
///  1. `runSupervisor(source:)` — loops while recording, committing whole chunks.
///     App: run inside a cancellable `Task` and cancel on key release.
///     CLI: `await` it directly; it returns once the file is fully revealed.
///  2. `transcribeTail(source:)` — transcribes committed..<end (the short tail).
///  3. `assembleFinalText()` — awaits outstanding chunk cleanups, cleans the tail,
///     and joins everything into the final inserted text.
///
/// All main-engine calls go through the injected `SerialTranscriptionEngine`, so
/// a chunk, the tail, and any straggler never transcribe concurrently.
public actor IncrementalTranscriber {
    public struct Config: Sendable {
        /// Commit a chunk once this many seconds of audio are uncommitted.
        public var chunkTriggerSeconds: Double = 12
        /// Hard cap: if no silence is found by here, cut at the current end anyway.
        public var maxChunkSeconds: Double = 15
        /// Window at the end of the uncommitted span scanned for a silent cut point.
        /// Wide enough to usually contain a real sentence pause (not just an
        /// inter-word micro-gap), so chunks break at natural boundaries.
        public var silenceScanSeconds: Double = 3.0
        /// Length of each RMS frame examined within the scan window.
        public var silenceFrameSeconds: Double = 0.1
        /// Linear-RMS threshold below which a frame counts as silence.
        public var silenceThreshold: Float = 0.005
        /// Wall-clock budget for cleaning the post-release tail. The tail is on
        /// the critical path between key release and insertion; if the model
        /// can't beat this budget the raw tail is used silently — the committed
        /// chunks already carry the cleanup value.
        public var tailCleanupBudgetSeconds: Double = 2.5
        public var sampleRate: Double = 16000

        public init() {}
    }

    private let engine: SerialTranscriptionEngine
    private let cleaner: TranscriptCleaner
    private let cleanupEnabled: Bool
    private let voiceCommandsEnabled: Bool
    private let cleanupContext: CleanupContext
    private let config: Config

    /// Absolute sample index up to which audio has been committed into a chunk.
    private var committed = 0
    private var rawChunks: [String] = []
    private var cleanedChunks: [String?] = []
    private var chunkTimings: [ChunkTiming] = []
    private var cleanupTasks: [Task<Void, Never>] = []

    private var tailRaw = ""
    private var tailAudioSeconds = 0
    private var tailSttMs = 0.0

    public init(
        engine: SerialTranscriptionEngine,
        cleanupEnabled: Bool,
        voiceCommandsEnabled: Bool = false,
        cleanupContext: CleanupContext = CleanupContext(),
        config: Config = Config()
    ) {
        self.engine = engine
        self.cleaner = TranscriptCleaner()
        self.cleanupEnabled = cleanupEnabled
        self.voiceCommandsEnabled = voiceCommandsEnabled
        self.cleanupContext = cleanupContext
        self.config = config
    }

    /// Number of chunks committed so far. The app checks this on release: zero
    /// means the dictation was short enough that no chunk ever committed, so it
    /// runs the existing single-pass path instead.
    public var committedChunkCount: Int { rawChunks.count }

    // MARK: - Supervisor

    /// Commits whole chunks while more audio streams in. Returns when the task is
    /// cancelled (app, on key release) or the source is finished and no full chunk
    /// remains (CLI).
    public func runSupervisor(source: StreamAudioSource) async {
        let triggerSamples = Int(config.chunkTriggerSeconds * config.sampleRate)
        while !Task.isCancelled {
            let available = source.availableSampleCount()
            let uncommitted = available - committed
            if uncommitted >= triggerSamples {
                if let cut = chooseCut(available: available, source: source) {
                    await commitChunk(cut: cut, source: source)
                    continue
                }
                // No cut point yet and under the hard cap — wait for more audio.
                if source.isFinished() { break }
                await source.waitForMore()
            } else if source.isFinished() {
                break
            } else {
                await source.waitForMore()
            }
        }
    }

    /// Chooses where to end the current chunk. Scans the last `silenceScanSeconds`
    /// of the uncommitted span in short frames, finds the LONGEST contiguous run of
    /// sub-threshold (silent) frames, and cuts at its center. A sentence pause is a
    /// longer silent run than the micro-gaps between words, so this lands the seam
    /// squarely in a natural pause — usually a sentence boundary — with clear space
    /// on both sides. That keeps a sentence (and its leading discourse markers, e.g.
    /// "Second,", "Third,") whole within one chunk, so per-chunk cleanup can't drop
    /// them as a dangling fragment or mis-split a sentence across two chunks. If no
    /// silent frame qualifies, cuts at the end once the uncommitted span reaches
    /// `maxChunkSeconds`; otherwise returns nil to wait for more audio.
    private func chooseCut(available: Int, source: StreamAudioSource) -> Int? {
        let uncommitted = available - committed
        let scanSamples = Int(config.silenceScanSeconds * config.sampleRate)
        let frameSamples = max(1, Int(config.silenceFrameSeconds * config.sampleRate))
        let scanStart = max(committed, available - scanSamples)

        let window = source.samples(in: scanStart..<available)

        // Longest run of consecutive silent frames within the scan window. Ties go
        // to the LATER run (a larger committed chunk, fewer chunks overall).
        var bestRun: (length: Int, startFrame: Int)?
        var runStartFrame: Int?
        var frame = 0
        var i = 0
        while i + frameSamples <= window.count {
            let silent = Self.rms(window, from: i, count: frameSamples) < config.silenceThreshold
            if silent {
                if runStartFrame == nil { runStartFrame = frame }
            } else if let start = runStartFrame {
                let length = frame - start
                if bestRun == nil || length >= bestRun!.length { bestRun = (length, start) }
                runStartFrame = nil
            }
            i += frameSamples
            frame += 1
        }
        if let start = runStartFrame {  // a run reaching the end of the window
            let length = frame - start
            if bestRun == nil || length >= bestRun!.length { bestRun = (length, start) }
        }

        if let bestRun {
            let centerFrame = bestRun.startFrame + bestRun.length / 2
            return scanStart + centerFrame * frameSamples
        }
        if uncommitted >= Int(config.maxChunkSeconds * config.sampleRate) { return available }
        return nil
    }

    private func commitChunk(cut: Int, source: StreamAudioSource) async {
        let chunk = source.samples(in: committed..<cut)
        let audioSeconds = Double(chunk.count) / config.sampleRate

        let started = DispatchTime.now()
        let sttText = (try? await engine.transcribe(samples: chunk)) ?? ""
        let sttMs = Self.elapsedMs(since: started)

        // Encode command phrases on the RAW chunk, before cleanup can mangle the
        // literal words. The placeholders survive cleanup (the prompt preserves
        // them) and into the raw-fallback path, then decode at the final choke point.
        let raw = voiceCommandsEnabled ? encodeCommands(sttText) : sttText

        let index = rawChunks.count
        rawChunks.append(raw)
        cleanedChunks.append(nil)
        chunkTimings.append(ChunkTiming(audioSeconds: audioSeconds, sttMs: sttMs, cleanupMs: nil))
        committed = cut

        // Kick cleanup immediately so it overlaps with the next chunk's capture.
        // Recording time dwarfs cleanup time, so these should all be done well
        // before release.
        if cleanupEnabled {
            let task = Task { await self.cleanupChunk(index: index, raw: raw) }
            cleanupTasks.append(task)
        }
    }

    private func cleanupChunk(index: Int, raw: String) async {
        let started = DispatchTime.now()
        let result = await cleaner.clean(raw, context: cleanupContext)
        cleanedChunks[index] = result.text
        chunkTimings[index].cleanupMs = Self.elapsedMs(since: started)
    }

    // MARK: - Release (tail)

    /// Transcribes the tail — everything captured since the last committed chunk.
    /// By construction this is < `maxChunkSeconds` of audio, so it is fast.
    public func transcribeTail(source: StreamAudioSource) async {
        let available = source.availableSampleCount()
        let tail = source.samples(in: committed..<available)
        committed = available
        tailAudioSeconds = tail.count
        guard !tail.isEmpty else { return }

        let started = DispatchTime.now()
        let sttText = (try? await engine.transcribe(samples: tail)) ?? ""
        tailRaw = voiceCommandsEnabled ? encodeCommands(sttText) : sttText
        tailSttMs = Self.elapsedMs(since: started)
    }

    /// Awaits any outstanding chunk cleanups, cleans the tail, and joins all
    /// cleaned (or raw-fallback) chunks plus the tail into the final text.
    public func assembleFinalText() async -> StreamResult {
        for task in cleanupTasks { await task.value }

        var tailClean = tailRaw
        var tailCleanupMs = 0.0
        var note: String?
        if cleanupEnabled, !tailRaw.isEmpty {
            let started = DispatchTime.now()
            if rawChunks.isEmpty {
                // No committed chunks (CLI edge case): the tail IS the dictation —
                // full budget, and surface fallback notes as usual.
                let result = await cleaner.clean(tailRaw, context: cleanupContext)
                tailClean = result.text
                note = result.note
            } else {
                // Streamed: the tail is a fragment on the critical path. Tight
                // budget; a raw fallback here is by design, not an error.
                let result = await cleaner.clean(
                    tailRaw,
                    budgetSeconds: config.tailCleanupBudgetSeconds,
                    context: cleanupContext
                )
                tailClean = result.text
            }
            tailCleanupMs = Self.elapsedMs(since: started)
        }

        var parts: [String] = []
        for i in rawChunks.indices {
            let text = cleanupEnabled ? (cleanedChunks[i] ?? rawChunks[i]) : rawChunks[i]
            if !text.isEmpty { parts.append(text) }
        }
        if !tailClean.isEmpty { parts.append(tailClean) }

        // Preserve any newlines command placeholders will decode into; only
        // collapse space/tab runs. Real newline decoding happens at the app's
        // final choke point.
        let joined = normalizeInlineWhitespace(parts.joined(separator: " "))
        return StreamResult(
            text: joined,
            note: note,
            chunkTimings: chunkTimings,
            tailAudioSeconds: Double(tailAudioSeconds) / config.sampleRate,
            tailSttMs: tailSttMs,
            tailCleanupMs: tailCleanupMs
        )
    }

    // MARK: - Helpers

    private static func rms(_ samples: [Float], from offset: Int, count: Int) -> Float {
        var sumSquares: Float = 0
        var i = offset
        let end = offset + count
        while i < end {
            let s = samples[i]
            sumSquares += s * s
            i += 1
        }
        return (sumSquares / Float(count)).squareRoot()
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}
