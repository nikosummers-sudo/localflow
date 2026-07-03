import Foundation

/// A pure, dependency-free voice-activity gate over 16 kHz mono Float32 samples.
///
/// Its whole job is to answer "did the microphone actually capture a voice?"
/// before the transcriber ever runs. A denied Microphone permission (or a muted /
/// wrong input device) makes macOS feed LocalFlow (near-)silence rather than an
/// error, and Whisper's response to true silence is its classic hallucination
/// class — inserting "you" or "Thank you." out of nothing. Refusing to transcribe
/// silence kills that class at the source.
///
/// This is deliberately a principled RMS/energy gate, NOT a transcript-text
/// blocklist: "you" is a perfectly legitimate dictation, so filtering on the
/// output text would risk swallowing real speech. The input-energy gate targets
/// only the true-silence case and leaves every audible dictation untouched.
///
/// Kept in LocalFlowKit (no WhisperKit) so it stays pure and the DictCheck CLI can
/// exercise it against generated buffers with no microphone, model, or network.
public enum AudioGate {
    /// Linear-RMS threshold, per 100 ms frame, above which audio counts as voiced.
    /// Set just above IncrementalTranscriber's 0.005 silence *cut* threshold so a
    /// frame that merely isn't a chunk-seam candidate doesn't automatically read as
    /// speech. In dBFS this is ≈ -44 dB — comfortably above a typical room-noise
    /// floor (< 0.003 RMS, ≈ -50 dB) yet far below even quiet speech (0.03+ RMS).
    public static let speechThreshold: Float = 0.006

    /// Minimum count of voiced frames required to call a recording "speech".
    /// Three 100 ms frames ≈ 0.3 s of voiced audio — matching AppState's 0.3 s
    /// minimum-duration guard, and enough that a lone click or pop can't trip it.
    public static let minVoicedFrames = 3

    /// Analysis frame length in seconds. 100 ms is short enough to localise a brief
    /// burst yet long enough for a stable RMS estimate.
    public static let frameSeconds: Double = 0.1

    /// Whether the buffer contains at least `minVoicedFrames` non-overlapping
    /// 100 ms frames whose RMS exceeds `speechThreshold`. Scans in whole frames and
    /// returns early as soon as the bar is cleared.
    public static func containsSpeech(_ samples: [Float], sampleRate: Double = 16000) -> Bool {
        let frameSamples = max(1, Int(frameSeconds * sampleRate))
        var voiced = 0
        var i = 0
        while i + frameSamples <= samples.count {
            if frameRMS(samples, from: i, count: frameSamples) > speechThreshold {
                voiced += 1
                if voiced >= minVoicedFrames { return true }
            }
            i += frameSamples
        }
        return false
    }

    /// The loudest 100 ms frame's RMS. Diagnostics only (e.g. DictCheck / a future
    /// "your mic peaked at X" hint); the transcription decision uses
    /// `containsSpeech`. A buffer shorter than one frame is measured whole so a very
    /// short but loud blip still reports a sane peak instead of 0.
    public static func maxFrameRMS(_ samples: [Float], sampleRate: Double) -> Float {
        guard !samples.isEmpty else { return 0 }
        let frameSamples = max(1, Int(frameSeconds * sampleRate))
        if samples.count < frameSamples {
            return frameRMS(samples, from: 0, count: samples.count)
        }
        var peak: Float = 0
        var i = 0
        while i + frameSamples <= samples.count {
            let r = frameRMS(samples, from: i, count: frameSamples)
            if r > peak { peak = r }
            i += frameSamples
        }
        return peak
    }

    private static func frameRMS(_ samples: [Float], from offset: Int, count: Int) -> Float {
        guard count > 0 else { return 0 }
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
}
