import Foundation
import WhisperKit

// Minimal offline transcription check: load a WhisperKit model and transcribe an
// audio file. No microphone or TCC permission needed for file transcription.
// Usage: SttSmokeCheck <audio-path> [model] [--vocab "term1,term2,…"]
//   model defaults to "base". With --vocab, the terms are tokenized into a
//   decoding prompt (the same STT bias the app uses) so bias can be A/B tested.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())

// Extract the optional --vocab "a,b,c" flag.
var vocabTerms: [String] = []
if let flagIndex = args.firstIndex(of: "--vocab"), flagIndex + 1 < args.count {
    vocabTerms = args[flagIndex + 1]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    args.removeSubrange(flagIndex...(flagIndex + 1))
}

guard args.count >= 1 else {
    fail("usage: SttSmokeCheck <audio-path> [model] [--vocab \"a,b,c\"]")
}

let audioPath = args[0]
let model = args.count >= 2 ? args[1] : "base"

guard FileManager.default.fileExists(atPath: audioPath) else {
    fail("audio file not found: \(audioPath)")
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

do {
    log("Loading WhisperKit model \"\(model)\" (downloads on first use)…")
    let config = WhisperKitConfig(model: model, verbose: false, logLevel: .error, load: true, download: true)
    let whisperKit = try await WhisperKit(config)
    log("Model ready. Transcribing \(audioPath)…")

    var options = DecodingOptions(task: .transcribe, skipSpecialTokens: true, withoutTimestamps: true)
    if !vocabTerms.isEmpty, let tokenizer = whisperKit.tokenizer {
        let phrase = "Vocabulary: " + vocabTerms.joined(separator: ", ") + "."
        options.promptTokens = tokenizer.encode(text: phrase)
        log("Using vocabulary bias: \(vocabTerms.joined(separator: ", "))")
    }

    let results = try await whisperKit.transcribe(audioPath: audioPath, decodeOptions: options)
    let text = results.map(\.text).joined(separator: " ")
        .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // Final line, stdout, exact prefix.
    print("TRANSCRIPT: \(text)")
} catch {
    fail("transcription failed: \(error)")
}
