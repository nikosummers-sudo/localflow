import Foundation

/// Abstraction over a speech-to-text backend so the engine can be swapped later
/// (e.g. a different local model) without touching the recording or insertion code.
public protocol TranscriptionEngine: AnyObject {
    /// True once a model is loaded and ready to transcribe without blocking on a download/load.
    var isReady: Bool { get }

    /// Loads the model into memory, downloading it first if necessary.
    func preload() async throws

    /// Transcribes 16 kHz mono Float32 samples and returns cleaned text.
    func transcribe(samples: [Float]) async throws -> String
}
