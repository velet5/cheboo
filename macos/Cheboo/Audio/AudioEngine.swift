import AVFoundation
import CoreAudio
import Foundation

protocol AudioEngineDelegate: AnyObject {
    func audioEngine(_ engine: AudioEngine, didCapture pcm: Data)
    func audioEngine(_ engine: AudioEngine, didFailWith error: Error)
    /// Fired when the live device list changed and the engine *would* now
    /// resolve to a different input device than the one it's currently
    /// recording from. Caller decides whether to seamlessly restart the
    /// session so the new device (typically: the user's chosen mic that just
    /// came back online) takes effect.
    func audioEngineWantsRestartForDeviceChange(_ engine: AudioEngine)
}

extension AudioEngineDelegate {
    func audioEngineWantsRestartForDeviceChange(_ engine: AudioEngine) {}
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
///
/// On top of that, when a config change fires *while we're recording* we try a
/// seamless in-place rebuild before giving up. This catches the common AirPods
/// case where speaking flips the headset between A2DP and HFP profiles and the
/// notification arrives a few ms into the session — a session-killing error
/// would be jarring when the device is in fact still there.
final class AudioEngine {
    weak var delegate: AudioEngineDelegate?

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let callbackQueue = DispatchQueue(label: "com.github.velet5.cheboo.audio")
    private var isRunning = false
    private var configChangeObserver: NSObjectProtocol?

    /// User's preferred input device, by Core Audio UID. `nil` means "follow
    /// the system default input." When the preferred UID isn't currently
    /// attached we transparently fall back to the default; the device-list
    /// listener picks up reconnects and prompts the delegate to restart.
    private var preferredInputUID: String?
    /// `AudioDeviceID` we last set on the input AU, so the device-list
    /// listener can decide whether a change in available devices actually
    /// warrants a restart.
    private var activeInputDeviceID: AudioDeviceID = 0
    /// Timestamps of recent in-flight seamless rebuilds, used to cap how
    /// many we'll absorb before falling back to surfacing the error. Some
    /// hardware (notably AirPods) can fire several config changes in a row
    /// while switching profiles; we want to ride out the first few, but a
    /// runaway loop usually means a real device-loss situation.
    private var recentSeamlessRestarts: [Date] = []
    private let seamlessRestartWindow: TimeInterval = 10
    private let seamlessRestartLimit = 3
    /// The input format the engine settled on the last time we successfully
    /// started or rebuilt. Used to filter out spurious
    /// `AVAudioEngineConfigurationChange` notifications where nothing
    /// material actually changed — both AVAudioEngine internals and our own
    /// device rebinding will fire that notification, and rebuilding in
    /// response to a no-op change creates an infinite loop.
    private var lastStableInputFormat: AVAudioFormat?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        observeConfigChanges()
        observeDeviceList()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        if let block = deviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &deviceListenerAddress,
                DispatchQueue.main,
                block
            )
        }
    }

    /// Update the preferred input device. Safe to call any time. If we're
    /// recording and the new preference resolves to a different device, we
    /// signal the delegate to restart so the choice takes effect.
    func setPreferredInputUID(_ uid: String?) {
        let same = (uid ?? "") == (preferredInputUID ?? "")
        preferredInputUID = uid
        guard !same, isRunning else { return }
        let target = resolveTargetDeviceID()
        if target != activeInputDeviceID {
            callbackQueue.async { [weak self] in
                guard let self else { return }
                self.delegate?.audioEngineWantsRestartForDeviceChange(self)
            }
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
        // Pick the input device before we read formats — the input node's
        // `outputFormat(forBus:)` reports the *current* device's format, and
        // we'd otherwise install a tap against the wrong device.
        applyPreferredDevice()

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
        lastStableInputFormat = inputFormat
        Log.audio.info("audio engine started")
    }

    // MARK: - Input device selection

    /// Resolve `preferredInputUID` against the live device list. Falls back
    /// to the system default input. Returns 0 if neither is available.
    private func resolveTargetDeviceID() -> AudioDeviceID {
        if let uid = preferredInputUID, !uid.isEmpty,
           let id = InputDevices.deviceID(forUID: uid) {
            return id
        }
        return InputDevices.defaultInputDeviceID() ?? 0
    }

    /// Set the chosen device on the input node's underlying AUHAL audio
    /// unit. `kAudioOutputUnitProperty_CurrentDevice` is the documented
    /// channel for binding the macOS input node to a specific HAL device;
    /// AVAudioEngine respects the value as long as it's set before
    /// `prepare()` / `start()`. Leaves `activeInputDeviceID` set to whatever
    /// the unit actually ended up on so the listener can detect drift.
    private func applyPreferredDevice() {
        let target = resolveTargetDeviceID()
        guard target != 0, let inputUnit = engine.inputNode.audioUnit else {
            // Couldn't pick anything — leave the engine on its default and
            // record what that is so we don't false-fire on the next change.
            activeInputDeviceID = InputDevices.defaultInputDeviceID() ?? 0
            return
        }
        let before = readBoundDeviceID(of: inputUnit)
        var deviceID = target
        let propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            propSize
        )
        if status != noErr {
            Log.audio.error("failed to bind input device \(target, privacy: .public) (status=\(status, privacy: .public))")
            activeInputDeviceID = InputDevices.defaultInputDeviceID() ?? 0
        } else {
            activeInputDeviceID = target
            let after = readBoundDeviceID(of: inputUnit)
            Log.audio.info(
                "bound input device target=\(target, privacy: .public) before=\(before, privacy: .public) after=\(after, privacy: .public) uid=\(self.preferredInputUID ?? "(default)", privacy: .public)"
            )
        }
    }

    /// Read the device currently bound to the input AU. Used in diagnostics
    /// to verify our `kAudioOutputUnitProperty_CurrentDevice` writes actually
    /// stuck and to detect cases where macOS later swaps the AU off our
    /// chosen device behind our back.
    private func readBoundDeviceID(of unit: AudioUnit) -> AudioDeviceID {
        var value: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &value,
            &size
        )
        return status == noErr ? value : 0
    }

    private func observeDeviceList() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChange()
        }
        deviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceListenerAddress,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            Log.audio.error("AudioEngine: failed to add device-list listener (\(status, privacy: .public))")
        }
    }

    private func handleDeviceListChange() {
        // The user's preferred mic may have just been (un)plugged. If we're
        // idle, the next start() will pick the right device on its own.
        guard isRunning else { return }
        let target = resolveTargetDeviceID()
        guard target != activeInputDeviceID else { return }
        Log.audio.notice("device list changed — preferred device now resolves to a different id; requesting restart")
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioEngineWantsRestartForDeviceChange(self)
        }
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
    /// output device, when another app takes the device exclusively, or when
    /// a connected Bluetooth headset (AirPods!) flips between A2DP and HFP
    /// profiles in response to the input session starting. If we're idle, drop
    /// cached state so the next `start()` re-queries fresh. If we're
    /// recording, attempt one in-place rebuild before giving up — that's
    /// almost always what the user wants for a benign route change. If the
    /// rebuild fails, or we've already absorbed too many in a row, fall back
    /// to surfacing an error.
    private func handleConfigurationChange() {
        Log.audio.notice("AVAudioEngineConfigurationChange fired (isRunning=\(self.isRunning, privacy: .public))")

        if !isRunning {
            // Tear down any leftover tap/converter so a future start() begins
            // from a clean slate. The engine instance itself may still be
            // poisoned by the device disappearing; recreate it preemptively.
            resetEngineInstance()
            return
        }

        // The notification fires on every internal reconfiguration —
        // including the one our own startEngine() causes when it binds
        // `kAudioOutputUnitProperty_CurrentDevice` on a fresh engine. If the
        // input format and the resolved preferred device are both unchanged
        // from the state we last stabilized at, there is nothing to rebuild
        // for and reacting would loop forever. Detect that and bail.
        let currentFormat = engine.inputNode.outputFormat(forBus: 0)
        let preferredTarget = resolveTargetDeviceID()
        if let last = lastStableInputFormat,
           currentFormat.sampleRate == last.sampleRate,
           currentFormat.channelCount == last.channelCount,
           currentFormat.sampleRate > 0,
           currentFormat.channelCount > 0,
           preferredTarget != 0,
           preferredTarget == activeInputDeviceID
        {
            Log.audio.info(
                "config change is benign (device id=\(self.activeInputDeviceID, privacy: .public), format unchanged) — ignoring"
            )
            return
        }

        if shouldAttemptSeamlessRestart() {
            Log.audio.notice("attempting seamless audio engine rebuild")
            resetEngineInstance()
            do {
                try startEngine()
                Log.audio.info("seamless rebuild succeeded")
                return
            } catch {
                // Genuine device loss — fall through to the failure path.
                Log.audio.error("seamless rebuild failed: \(error.localizedDescription, privacy: .public)")
                isRunning = false
                callbackQueue.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.audioEngine(self, didFailWith: error)
                }
                return
            }
        }

        Log.audio.notice("seamless-restart budget exhausted — surfacing error")
        let err = NSError(
            domain: "AudioEngine",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Audio device changed — recording stopped. Press the hotkey to resume."]
        )
        isRunning = false
        resetEngineInstance()

        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioEngine(self, didFailWith: err)
        }
    }

    /// Tear down the current `AVAudioEngine` instance and replace it with a
    /// fresh one, re-registering the config-change observer against the new
    /// engine. The prior instance may still be holding poisoned state from
    /// the route change that triggered us, so we don't try to reuse it.
    private func resetEngineInstance() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        engine = AVAudioEngine()
        observeConfigChanges()
    }

    private func shouldAttemptSeamlessRestart() -> Bool {
        let now = Date()
        recentSeamlessRestarts.removeAll { now.timeIntervalSince($0) > seamlessRestartWindow }
        guard recentSeamlessRestarts.count < seamlessRestartLimit else { return false }
        recentSeamlessRestarts.append(now)
        return true
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
