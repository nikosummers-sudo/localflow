import Foundation
import LocalFlowStreaming

/// Adapts the live microphone `AudioRecorder` to the streaming supervisor's
/// `StreamAudioSource` protocol. While recording it reads the recorder's growing
/// buffer directly; on key release the app calls `finalize(with:)` with the final
/// samples returned by `endRecording()`, freezing the buffer so the tail read is
/// stable even though the recorder has moved back to pre-roll capture.
final class LiveSampleSource: StreamAudioSource, @unchecked Sendable {
    private let recorder: AudioRecorder
    private let pollNanos: UInt64

    private let lock = NSLock()
    private var frozen: [Float]?
    private var finished = false

    init(recorder: AudioRecorder, pollSeconds: Double = 1.0) {
        self.recorder = recorder
        self.pollNanos = UInt64(pollSeconds * 1_000_000_000)
    }

    /// Freezes the source at the final recording so `transcribeTail` reads a
    /// stable buffer. Must be called before assembling the tail.
    func finalize(with samples: [Float]) {
        lock.lock()
        frozen = samples
        finished = true
        lock.unlock()
    }

    func availableSampleCount() -> Int {
        lock.lock(); let f = frozen; lock.unlock()
        if let f { return f.count }
        return recorder.sampleCount
    }

    func samples(in range: Range<Int>) -> [Float] {
        lock.lock(); let f = frozen; lock.unlock()
        if let f {
            let lower = max(0, min(range.lowerBound, f.count))
            let upper = max(lower, min(range.upperBound, f.count))
            return Array(f[lower..<upper])
        }
        return recorder.samples(in: range)
    }

    func isFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func waitForMore() async {
        try? await Task.sleep(nanoseconds: pollNanos)
    }
}
