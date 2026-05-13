import AVFoundation
import Foundation

protocol AudioEngineDelegate: AnyObject {
    func audioEngine(_ engine: AudioEngine, didCapture pcm: Data)
    func audioEngine(_ engine: AudioEngine, didFailWith error: Error)
}

/// Captures mic audio and converts to 16 kHz mono Int16 PCM frames suitable for
/// Deepgram's `encoding=linear16&sample_rate=16000&channels=1` stream.
///
/// macOS routes mic / speaker changes — and *especially* another app grabbing
/// the audio device for exclusive I/O (GarageBand, Logic, Audio Hijack…) —
/// through `AVAudioEngineConfigurationChange`. When that happens, the engine's
/// input format becomes stale, the underlying HAL device may be unavailable,
/// and calling `installTapOnBus:` raises an `NSException` that Swift cannot
/// catch — the process dies with SIGABRT before any error path runs.
///
/// We defend against that on three fronts:
/// 1. `ObjcExceptionGuard` wraps each `installTap` call so the throw becomes a
///    surfaceable `NSError` instead of process death.
/// 2. Strict format validation rejects 0-channel / 0-rate input formats before
///    we hand them to AVAudioEngine.
/// 3. The `AVAudioEngine` instance is recreated whenever a config change fires
///    or an install-tap exception comes back — the prior instance may carry
///    poisoned state from the moment the device disappeared.
final class AudioEngine {
    weak var delegate: AudioEngineDelegate?

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let callbackQueue = DispatchQueue(label: "com.github.velet5.cheboo.audio")
    private var isRunning = false
    private var configChangeObserver: NSObjectProtocol?

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        observeConfigChanges()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    func start() throws {
        try startEngine()
    }

    func stop() {
        Log.audio.info("stopping audio engine")
        isRunning = false
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        converter = nil
    }

    // MARK: - Engine bring-up

    private func startEngine(retrying: Bool = false) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        Log.audio.info(
            "starting audio engine — input sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)"
        )

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Log.audio.error(
                "invalid input format (sampleRate=\(inputFormat.sampleRate, privacy: .public), channels=\(inputFormat.channelCount, privacy: .public))"
            )
            throw NSError(
                domain: "AudioEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input available. Another app may be using the audio device exclusively."]
            )
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if converter == nil {
            Log.audio.error("failed to build AVAudioConverter from input to target format")
        }

        input.removeTap(onBus: 0)

        do {
            try ObjcExceptionGuard.catchException {
                input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                    self?.process(buffer)
                }
            }
        } catch {
            let reason = error.localizedDescription
            Log.audio.error("installTap threw NSException: \(reason, privacy: .public)")
            if retrying {
                throw NSError(
                    domain: "AudioEngine",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't start audio capture: \(reason). Another app may be holding the device — quit it and try again."]
                )
            }
            // The engine may have unsalvageable internal state — replace it
            // wholesale and have one more go.
            Log.audio.notice("recreating AVAudioEngine and retrying once")
            engine = AVAudioEngine()
            observeConfigChanges()
            return try startEngine(retrying: true)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.audio.error("engine.start() threw: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        Log.audio.info("audio engine started")
    }

    // MARK: - Configuration change

    private func observeConfigChanges() {
        // Drop the previous registration before adding a new one — every time
        // we swap the underlying `engine` we re-subscribe against the new
        // instance, and leaving the old token behind quietly accumulates dead
        // observers in NotificationCenter.
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Called on the main thread when CoreAudio swaps the active input or
    /// output device, or when another app takes the device exclusively. If
    /// we're idle, drop cached state so the next `start()` re-queries fresh.
    /// If we're recording, fail the session — restarting in-flight is rarely
    /// what the user wants when GarageBand-class apps grab the device.
    private func handleConfigurationChange() {
        Log.audio.notice("AVAudioEngineConfigurationChange fired (isRunning=\(self.isRunning, privacy: .public))")

        if !isRunning {
            // Tear down any leftover tap/converter so a future start() begins
            // from a clean slate. The engine instance itself may still be
            // poisoned by the device disappearing; recreate it preemptively.
            engine.inputNode.removeTap(onBus: 0)
            converter = nil
            engine.stop()
            engine = AVAudioEngine()
            observeConfigChanges()
            return
        }

        // We were actively recording. Stop cleanly, surface an error, and let
        // the user re-press the hotkey when the other app has released the
        // device. Trying to silently rebuild in-flight risks the very crash
        // we're guarding against.
        let err = NSError(
            domain: "AudioEngine",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Audio device changed — recording stopped. Press the hotkey to resume."]
        )
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        engine = AVAudioEngine()
        observeConfigChanges()

        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioEngine(self, didFailWith: err)
        }
    }

    // MARK: - Tap processing

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var supplied = false
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let convertError {
                Log.audio.error(
                    "AVAudioConverter.convert error: \(convertError.localizedDescription, privacy: .public)"
                )
                callbackQueue.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.audioEngine(self, didFailWith: convertError)
                }
            }
            return
        }

        let frameCount = Int(output.frameLength)
        guard frameCount > 0, let channelData = output.int16ChannelData?[0] else { return }
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let data = Data(bytes: channelData, count: byteCount)

        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioEngine(self, didCapture: data)
        }
    }
}
