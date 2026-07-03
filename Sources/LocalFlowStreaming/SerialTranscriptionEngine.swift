import Foundation
import LocalFlowKit

/// Thread-safe claim-once flag for continuation races.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Serializes every call to a single underlying transcription engine so the main
/// WhisperKit model never runs two transcriptions concurrently — a streaming
/// chunk, the post-release tail, and any other caller are all forced through one
/// FIFO queue. (A plain `actor` is not enough on its own: actors are reentrant
/// across `await`, so two callers could both be suspended inside the engine at
/// once. The explicit task chain below closes that gap.)
///
/// The optional live-preview transcriber keeps its OWN separate engine and does
/// NOT go through here, so it never blocks or is blocked by the main engine.
public actor SerialTranscriptionEngine {
    private let engine: WhisperKitEngine

    /// Tail of the serial chain: each enqueued operation awaits the previous one
    /// before it starts, guaranteeing one-at-a-time execution.
    private var tail: Task<Void, Never>?

    public init(engine: WhisperKitEngine) {
        self.engine = engine
    }

    public var isReady: Bool { engine.isReady }
    public var statusNote: String? { engine.statusNote }

    public func preload() async throws {
        try await run { try await self.engine.preload() }
    }

    public func transcribe(samples: [Float]) async throws -> String {
        try await run { try await self.engine.transcribe(samples: samples) }
    }

    /// Watchdog: races the serialized transcription against a wall-clock limit.
    /// A CoreML/ANE-level stall (observed in the wild; thread sample showed the
    /// call parked in ANEServices forever) otherwise wedges the FIFO chain and
    /// silently eats every later dictation. nil = timed out or threw — treat
    /// THIS ENGINE as poisoned and discard it for a fresh one.
    public nonisolated func transcribeOrTimeout(samples: [Float], seconds: Double) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = OnceFlag()
            Task {
                let text = try? await self.transcribe(samples: samples)
                if once.claim() { cont.resume(returning: text) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    EventLog.log("stt.watchdog", ["timeoutS": String(Int(seconds))])
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Runs `operation` only after every previously-enqueued operation has fully
    /// completed. Failures are isolated: one operation throwing does not poison
    /// the queue for the next.
    private func run<T: Sendable>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () -> Result<T, Error> in
            await previous?.value
            do { return .success(try await operation()) }
            catch { return .failure(error) }
        }
        // Advance the chain; the next caller waits on THIS operation finishing.
        tail = Task { _ = await task.value }
        switch await task.value {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
