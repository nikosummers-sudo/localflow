import Foundation
import LocalFlowKit
import LocalFlowStreaming
import WhisperKit

// Headless validation + timing evidence for the streaming pipeline. Loads a wav,
// simulates a live dictation faster than realtime through the SAME
// IncrementalTranscriber the app uses (chunk decisions, per-chunk STT + cleanup,
// tail), then runs the existing single-pass path (one STT + one cleanup) over the
// same audio and prints a comparison.
//
// Usage: StreamCheck <audio.wav> [model]        (model defaults to large-v3_turbo)
//
// Exits non-zero if the model can't load, or if Ollama / the cleanup model is
// unavailable (cleanup is part of the pipeline being validated).

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    stderr("ERROR: \(message)")
    exit(1)
}

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
}

let args = Array(CommandLine.arguments.dropFirst())
guard let audioPath = args.first else {
    fail("usage: StreamCheck <audio.wav> [model]")
}
let model = args.count >= 2 ? args[1] : "large-v3_turbo"

guard FileManager.default.fileExists(atPath: audioPath) else {
    fail("audio file not found: \(audioPath)")
}

// MARK: - Load audio (16 kHz mono Float32)

let samples: [Float]
do {
    stderr("Loading audio \(audioPath)…")
    samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
} catch {
    fail("could not load audio: \(error)")
}
let sampleRate = 16000.0
let totalSeconds = Double(samples.count) / sampleRate
stderr(String(format: "Loaded %.1fs of audio (%d samples).", totalSeconds, samples.count))

// MARK: - Preflight: Ollama / cleanup model

let cleanupEnabled = TranscriptCleaner.isEnabled
let ollamaURL = UserDefaults.standard.string(forKey: "ollamaURL") ?? OllamaClient.defaultBaseURL
if cleanupEnabled {
    stderr("Checking Ollama cleanup model \"\(TranscriptCleaner.model)\" at \(ollamaURL)…")
    let cleaner = TranscriptCleaner()
    let probe = "This is a preflight probe sentence, long enough to exceed the fifty character cleanup gate."
    let probeResult = await cleaner.clean(probe)
    if probeResult.note == "Cleanup unavailable — inserted raw transcript" {
        fail("Ollama or the cleanup model \"\(TranscriptCleaner.model)\" is unavailable at \(ollamaURL). "
            + "Start Ollama and run: ollama pull \(TranscriptCleaner.model)")
    }
    stderr("Ollama reachable; cleanup model warm.")
} else {
    stderr("Cleanup disabled (cleanupEnabled=false) — validating STT chunking only.")
}

// MARK: - Load the model

stderr("Loading WhisperKit model \"\(model)\" (downloads on first use)…")
let whisperEngine = WhisperKitEngine(model: model)
do {
    try await whisperEngine.preload()
} catch {
    fail("model \"\(model)\" is unavailable: \(error)")
}
if let note = whisperEngine.statusNote {
    stderr("WARNING: \(note)")
}
let engine = SerialTranscriptionEngine(engine: whisperEngine)
stderr("Model ready.\n")

// MARK: - Streamed path (chunked while "recording", faster than realtime)

let transcriber = IncrementalTranscriber(engine: engine, cleanupEnabled: cleanupEnabled)
let source = PlaybackSampleSource(samples: samples, revealSeconds: 1.0, sampleRate: sampleRate)

// Everything up to here mirrors what happens DURING recording (pre key-release).
await transcriber.runSupervisor(source: source)

// "Key release": only the tail is left. Measure the post-release wall cost.
let releaseStart = nowMs()
await transcriber.transcribeTail(source: source)
let streamed = await transcriber.assembleFinalText()
let streamedPostReleaseMs = nowMs() - releaseStart

// MARK: - Single-pass path (everything after release, as today)

let spSttStart = nowMs()
let spRaw = (try? await engine.transcribe(samples: samples)) ?? ""
let spSttMs = nowMs() - spSttStart

var spClean = spRaw
var spCleanMs = 0.0
if cleanupEnabled, !spRaw.isEmpty {
    let c0 = nowMs()
    spClean = await TranscriptCleaner().clean(spRaw).text
    spCleanMs = nowMs() - c0
}
let singlePassPostReleaseMs = spSttMs + spCleanMs

// MARK: - Report

print("=== StreamCheck: \(audioPath) (model: \(model)) ===")
print(String(format: "audio: %.1fs   chunks committed: %d   cleanup: %@",
             totalSeconds, streamed.chunkTimings.count, cleanupEnabled ? "on" : "off"))
print("")
print("chunk |  audio s |   STT ms | cleanup ms")
print("------+----------+----------+-----------")
for (i, t) in streamed.chunkTimings.enumerated() {
    let cleanup = t.cleanupMs.map { String(format: "%8.0f", $0) } ?? "       –"
    print(String(format: "%5d | %8.2f | %8.0f | %@", i + 1, t.audioSeconds, t.sttMs, cleanup))
}
let tailCleanupStr = cleanupEnabled ? String(format: "%8.0f", streamed.tailCleanupMs) : "       –"
print(String(format: " tail | %8.2f | %8.0f | %@", streamed.tailAudioSeconds, streamed.tailSttMs, tailCleanupStr))
print("")

print("STREAMED:   \(streamed.text)")
print("")
print("SINGLEPASS: \(spClean)")
print("")

let swords = wordCount(streamed.text)
let pwords = wordCount(spClean)
let denom = max(1, pwords)
let deltaPct = abs(Double(swords - pwords)) / Double(denom) * 100
print(String(format: "word counts: streamed %d vs single-pass %d (Δ %.1f%%) — %@",
             swords, pwords, deltaPct, deltaPct <= 15 ? "OK" : "OVER 15% — review chunk seams"))
print(String(format: "post-release cost: streamed ~%.0fms vs single-pass ~%.0fms",
             streamedPostReleaseMs, singlePassPostReleaseMs))
