import Foundation

/// A growing stream of 16 kHz mono Float32 samples that the incremental
/// transcriber's supervisor reads while a dictation is in progress. The app
/// backs this with the live microphone buffer; the StreamCheck CLI backs it with
/// a pre-loaded file it reveals progressively — so both drive the EXACT same
/// chunk-decision and commit logic in `IncrementalTranscriber`.
public protocol StreamAudioSource: AnyObject, Sendable {
    /// Number of samples available to read right now. Grows over time until the
    /// source is finished, after which it is stable.
    func availableSampleCount() -> Int

    /// A copy of the samples in `range`. `range` must lie within the count most
    /// recently returned by `availableSampleCount()`; the source clamps defensively.
    func samples(in range: Range<Int>) -> [Float]

    /// True once no more samples will ever arrive (recording stopped / file fully
    /// revealed). Once true it stays true.
    func isFinished() -> Bool

    /// Called by the supervisor between polls to pace itself. The live source
    /// sleeps ~1s; the CLI reveals the next slice of the file (no real wait), so
    /// the simulation runs faster than realtime while making identical cut choices.
    func waitForMore() async
}

/// Feeds a pre-loaded sample array into the supervisor progressively, revealing a
/// fixed slice on each `waitForMore()`. Used by the StreamCheck CLI to simulate a
/// live dictation faster than realtime without changing the chunk logic.
public final class PlaybackSampleSource: StreamAudioSource, @unchecked Sendable {
    private let allSamples: [Float]
    private let revealStep: Int
    private let lock = NSLock()
    private var revealed = 0

    /// - Parameters:
    ///   - samples: full 16 kHz mono recording.
    ///   - revealSeconds: how much audio each `waitForMore()` makes newly visible
    ///     (mirrors the app's ~1s supervisor poll cadence).
    ///   - sampleRate: samples per second (16 kHz).
    public init(samples: [Float], revealSeconds: Double = 1.0, sampleRate: Double = 16000) {
        self.allSamples = samples
        self.revealStep = max(1, Int(revealSeconds * sampleRate))
    }

    public func availableSampleCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return revealed
    }

    public func samples(in range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let lower = max(0, min(range.lowerBound, allSamples.count))
        let upper = max(lower, min(range.upperBound, allSamples.count))
        return Array(allSamples[lower..<upper])
    }

    public func isFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revealed >= allSamples.count
    }

    public func waitForMore() async {
        reveal()
        // Yield so the supervisor's async chain progresses, but never sleep — the
        // simulation should run as fast as the engine allows.
        await Task.yield()
    }

    /// Reveals the next slice. Synchronous so the lock is never held across a
    /// suspension point.
    private func reveal() {
        lock.lock()
        revealed = min(revealed + revealStep, allSamples.count)
        lock.unlock()
    }
}
