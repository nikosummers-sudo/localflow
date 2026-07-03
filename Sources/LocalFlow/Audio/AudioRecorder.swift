import AVFoundation
import CoreAudio
import Foundation
import LocalFlowKit

/// Records microphone audio and delivers it as 16 kHz mono Float32 samples,
/// the format WhisperKit expects. The input tap uses the hardware's native
/// format (forcing 16 kHz on the tap is rejected by most inputs) and an
/// AVAudioConverter downsamples inside the tap callback.
///
/// Two capture modes:
///  - **Continuous (instant capture):** the engine + tap run from app launch.
///    While NOT dictating, converted samples flow into a small pre-roll ring
///    buffer (capped at `ringSeconds`, continuously trimmed and never processed,
///    stored, or transmitted). `beginRecording()` seeds the recording buffer with
///    the most recent `preRollSeconds` from the ring — so words spoken as/just
///    before the key was pressed are captured and the first words are never
///    clipped, with zero engine-startup latency.
///  - **Legacy:** the engine starts on `beginRecording()` and stops on
///    `endRecording()`, exactly as before (accepting the startup gap). Used when
///    instant capture is off or the microphone permission isn't granted.
final class AudioRecorder {
    static let targetSampleRate: Double = 16000

    private let engine = AVAudioEngine()

    /// Guards the sample/ring buffers. Taken briefly on the audio thread.
    private let lock = NSLock()
    /// Guards engine + tap lifecycle (start/stop/install/remove/reconfigure) so the
    /// main thread and the configuration-change handler never race. Never taken on
    /// the audio thread.
    private let engineLock = NSLock()

    /// The recording buffer, appended to while dictating.
    private var samples: [Float] = []
    /// Pre-roll ring buffer, appended to while NOT dictating and trimmed to the
    /// most recent `ringSeconds`. Its contents only ever seed a dictation's start.
    private var ring: [Float] = []

    /// Continuous capture is active (engine + tap always running).
    private var captureMode = false
    /// A dictation is in progress (route audio to `samples`, emit level).
    private var dictating = false
    private var tapInstalled = false

    private var configObserver: NSObjectProtocol?

    /// Pre-roll ring capacity and how much of it seeds a new recording.
    private let ringSeconds: Double = 2.0
    private let preRollSeconds: Double = 0.75

    /// Delivers a normalized 0–1 microphone level for the HUD's voice-reactive
    /// animation. Invoked from the audio tap thread, throttled to ~15 Hz. Emitted
    /// ONLY while dictating so the pill doesn't dance outside dictations.
    var onLevel: ((Float) -> Void)?

    private var lastLevelEmit: CFAbsoluteTime = 0
    private let levelEmitInterval: CFAbsoluteTime = 1.0 / 15.0

    init() {
        // Reinstall the tap + converter and resume capture when the audio route
        // changes (device switch, AirPods connect/disconnect, sample-rate change).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Whether continuous instant-capture mode is currently running.
    var isCapturing: Bool {
        engineLock.lock(); defer { engineLock.unlock() }
        return captureMode
    }

    /// Duration in seconds of audio captured into the recording buffer so far.
    var recordedDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / AudioRecorder.targetSampleRate
    }

    /// Count of recording-buffer samples captured so far (cheap; no copy).
    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// Lock-guarded snapshot of the whole recording buffer.
    func currentSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Lock-guarded copy of the recording buffer in `range` (clamped defensively).
    func samples(in range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let lower = max(0, min(range.lowerBound, samples.count))
        let upper = max(lower, min(range.upperBound, samples.count))
        return Array(samples[lower..<upper])
    }

    /// A cheap, content-free description of the current input for diagnostics: the
    /// hardware input sample rate (always available) and, best-effort, the default
    /// input device's name. Used only for the event log — never touches audio data.
    func inputDescription() -> (deviceName: String?, sampleRate: Double) {
        engineLock.lock()
        let rate = engine.inputNode.inputFormat(forBus: 0).sampleRate
        engineLock.unlock()
        return (Self.defaultInputDeviceName(), rate)
    }

    /// The default input device's name via Core Audio. Returns nil on any failure
    /// (no device, query error) — diagnostics must never disrupt capture.
    private static func defaultInputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &deviceAddr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    enum RecorderError: Error, LocalizedError {
        case converterUnavailable
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "Could not create an audio converter for the microphone format."
            case .engineStartFailed(let message):
                return "Could not start the audio engine: \(message)"
            }
        }
    }

    // MARK: - Continuous capture lifecycle

    /// Starts the always-on tap + engine for instant capture. Safe to call more
    /// than once. Call only when the microphone permission is granted.
    func startContinuousCapture() throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !captureMode else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        ring.removeAll(keepingCapacity: true)
        lock.unlock()
        try installTapLocked()
        try startEngineLocked()
        captureMode = true
    }

    /// Fully tears down and rebuilds the continuous-capture engine + tap against
    /// the current input. Needed when the Microphone permission is granted while
    /// the app is already running: macOS keeps feeding an already-running tap
    /// pre-grant silence until the engine is stopped and the input node is
    /// reconfigured. No-op (leaves capture as-is) when not in continuous mode —
    /// the caller starts a fresh capture in that case. Never rebuilds out from
    /// under a live dictation. Best-effort: on failure capture is left stopped and
    /// the next `beginRecording()` retries a start.
    func restartContinuousCapture() throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard captureMode, !dictating else { return }

        removeTapLocked()
        engine.stop()
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        ring.removeAll(keepingCapacity: true)
        lock.unlock()
        do {
            try installTapLocked()
            try startEngineLocked()
        } catch {
            captureMode = false
            onLevel?(0)
            EventLog.log("engine.restart", ["reason": "mic-grant", "result": "failed"])
            throw error
        }
        onLevel?(0)
        EventLog.log("engine.restart", ["reason": "mic-grant", "result": "ok"])
    }

    /// Stops continuous capture entirely (engine + tap). Any in-progress dictation
    /// routing is abandoned.
    func stopContinuousCapture() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard captureMode else { return }
        captureMode = false
        dictating = false
        removeTapLocked()
        engine.stop()
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        ring.removeAll(keepingCapacity: true)
        lock.unlock()
        onLevel?(0)
    }

    // MARK: - Dictation lifecycle

    /// Begins a dictation. In continuous mode this seeds the recording buffer with
    /// the pre-roll ring (no engine start → zero startup loss). In legacy mode it
    /// starts the engine + tap.
    func beginRecording() throws {
        engineLock.lock()
        defer { engineLock.unlock() }

        if captureMode {
            lock.lock()
            let preRoll = Int(preRollSeconds * AudioRecorder.targetSampleRate)
            samples = ring.count > preRoll ? Array(ring.suffix(preRoll)) : ring
            ring.removeAll(keepingCapacity: true)
            dictating = true
            lock.unlock()
        } else {
            lock.lock()
            samples.removeAll(keepingCapacity: true)
            ring.removeAll(keepingCapacity: true)
            lock.unlock()
            try installTapLocked()
            try startEngineLocked()
            dictating = true
        }
    }

    /// Ends a dictation and returns the captured 16 kHz mono samples. In
    /// continuous mode the engine KEEPS running (capture resumes into the ring);
    /// in legacy mode the engine stops.
    @discardableResult
    func endRecording() -> [Float] {
        engineLock.lock()
        defer { engineLock.unlock() }

        guard dictating else {
            lock.lock(); defer { lock.unlock() }
            return samples
        }

        if captureMode {
            lock.lock()
            let result = samples
            samples.removeAll(keepingCapacity: true)
            dictating = false
            lock.unlock()
            onLevel?(0)
            return result
        } else {
            removeTapLocked()
            engine.stop()
            dictating = false
            onLevel?(0)
            lock.lock(); defer { lock.unlock() }
            return samples
        }
    }

    // MARK: - Engine / tap plumbing (call with engineLock held)

    private func installTapLocked() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.appendConverted(buffer, using: converter, targetFormat: targetFormat)
        }
        tapInstalled = true
    }

    private func removeTapLocked() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func startEngineLocked() throws {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTapLocked()
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Rebuilds the tap + converter against the (possibly new) input format after
    /// an audio-route change, and restarts the engine if it stopped. Best-effort:
    /// capture continues if it can, and is silently skipped if it can't.
    private func handleConfigurationChange() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard captureMode || dictating else { return }
        removeTapLocked()
        do {
            try installTapLocked()
            if !engine.isRunning { try startEngineLocked() }
            EventLog.log("engine.configchange", [
                "result": "ok",
                "inputHz": String(format: "%.0f", engine.inputNode.inputFormat(forBus: 0).sampleRate),
            ])
        } catch {
            // Leave capture stopped; the next beginRecording() will retry a start.
            EventLog.log("engine.configchange", ["result": "failed"])
        }
    }

    // MARK: - Audio thread

    private func appendConverted(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard capacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              outBuffer.frameLength > 0,
              let channelData = outBuffer.floatChannelData else {
            return
        }

        let frameCount = Int(outBuffer.frameLength)
        let pointer = channelData[0]

        lock.lock()
        let recordingNow = dictating
        if recordingNow {
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: frameCount))
        } else {
            ring.append(contentsOf: UnsafeBufferPointer(start: pointer, count: frameCount))
            // Trim the ring from the front to the most recent `ringSeconds`.
            let cap = Int(ringSeconds * AudioRecorder.targetSampleRate)
            if ring.count > cap {
                ring.removeFirst(ring.count - cap)
            }
        }
        lock.unlock()

        // Only animate the pill while actually dictating.
        if recordingNow {
            emitLevel(from: pointer, frameCount: frameCount)
        }
    }

    /// Computes RMS over the converted mono buffer, maps it into a 0–1 level via
    /// a ~-50…0 dB window, and forwards it — no more than ~15×/second so the HUD
    /// isn't flooded from the audio thread.
    private func emitLevel(from pointer: UnsafePointer<Float>, frameCount: Int) {
        guard let onLevel, frameCount > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelEmit >= levelEmitInterval else { return }
        lastLevelEmit = now

        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let s = pointer[i]
            sumSquares += s * s
        }
        let rms = sqrtf(sumSquares / Float(frameCount))
        onLevel(AudioRecorder.normalizedLevel(rms: rms))
    }

    /// Clamps an RMS amplitude (0…1) to a -50…0 dB window and rescales to 0…1.
    private static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let minDb: Float = -50
        let db = 20 * log10f(rms)
        let clamped = max(minDb, min(0, db))
        return (clamped - minDb) / -minDb
    }
}
