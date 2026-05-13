import AVFoundation
import Combine
import Foundation

/// Orchestrates the dictation pipeline on iOS: tap → audio capture →
/// Deepgram socket → live transcript. No keystroke injection (iOS blocks
/// that path); finals accumulate into a session buffer the UI can copy,
/// share, edit, or persist.
///
/// All published state mutations land on the main thread.
final class DictationController: ObservableObject {
    enum Status: Equatable {
        case idle
        case denied
        case connecting
        case recording
        case finishing
        case error(String)

        var isBusy: Bool {
            switch self {
            case .connecting, .recording, .finishing: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var interimText: String = ""
    @Published private(set) var finalizedText: String = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0

    /// The full session text (already-finalized chunks plus the live partial),
    /// joined with a single space when both sides are non-empty.
    var displayText: String {
        let final = finalizedText
        let interim = interimText
        switch (final.isEmpty, interim.isEmpty) {
        case (true, true): return ""
        case (false, true): return final
        case (true, false): return interim
        case (false, false): return final + " " + interim
        }
    }

    var isActive: Bool {
        if case .recording = status { return true }
        if case .connecting = status { return true }
        if case .finishing = status { return true }
        return false
    }

    private let audio = AudioEngine()
    private var socket: DeepgramSocket?
    private var settings: SettingsStore?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var pendingCompletion: ((String, TimeInterval) -> Void)?

    init() {
        audio.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        elapsedTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func bind(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: - Public control

    /// Tap-to-toggle. Starts if idle, stops if recording.
    /// `onFinish` fires once the final transcript is settled (only if a
    /// session actually produced text).
    func toggle(onFinish: ((String, TimeInterval) -> Void)? = nil) {
        switch status {
        case .recording, .connecting:
            stop()
        case .idle, .error, .denied:
            if let onFinish { pendingCompletion = onFinish }
            start()
        case .finishing:
            break
        }
    }

    func clearSession() {
        guard !isActive else { return }
        finalizedText = ""
        interimText = ""
        elapsed = 0
    }

    func dismissError() {
        if case .error = status { status = .idle }
    }

    // MARK: - Lifecycle

    private func start() {
        guard let settings else { return }
        guard !settings.apiKey.isEmpty else {
            status = .error("Add your Deepgram API key in Settings.")
            return
        }

        Task { @MainActor in
            let granted = await Permissions.requestMicrophone()
            guard granted else {
                self.status = .denied
                return
            }
            self.beginSession(settings: settings)
        }
    }

    private func beginSession(settings: SettingsStore) {
        do {
            try AudioSession.activate()
        } catch {
            status = .error("Audio session: \(error.localizedDescription)")
            return
        }

        finalizedText = ""
        interimText = ""
        audioLevel = 0
        startedAt = Date()
        elapsed = 0
        status = .connecting

        let language = settings.languageMode.resolved()
        let socket = DeepgramSocket(
            apiKey: settings.apiKey,
            model: language.deepgramModel,
            language: language.deepgramLanguage,
            punctuate: settings.autoPunctuation,
            smartFormat: settings.autoCapitalization,
            keyterms: settings.keyterms
        )
        socket.delegate = self
        socket.connect()
        self.socket = socket

        do {
            try audio.start()
            status = .recording
            startElapsedTimer()
        } catch {
            status = .error(error.localizedDescription)
            socket.close()
            self.socket = nil
            AudioSession.deactivate()
        }
    }

    private func stop() {
        guard isActive else { return }
        audio.stop()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        status = .finishing
        // Let the server flush a final via CloseStream; cleanup runs in
        // didCloseWith below.
        socket?.close()
    }

    private func finalize(error: Error?) {
        AudioSession.deactivate()
        audioLevel = 0
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        if let error {
            status = .error(error.localizedDescription)
        } else {
            status = .idle
        }

        let text = (finalizedText + (interimText.isEmpty ? "" : " " + interimText))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        interimText = ""

        let duration = elapsed
        if let cb = pendingCompletion {
            pendingCompletion = nil
            if !text.isEmpty {
                cb(text, duration)
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func appendFinal(_ text: String) {
        let chunk = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }
        if finalizedText.isEmpty {
            finalizedText = chunk
        } else {
            finalizedText += " " + chunk
        }
    }

    // MARK: - Audio level (RMS → 0..1)

    private func rms(of pcm: Data) -> Float {
        let count = pcm.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        return pcm.withUnsafeBytes { raw -> Float in
            let ptr = raw.bindMemory(to: Int16.self)
            var sum: Float = 0
            for i in 0..<count {
                let v = Float(ptr[i]) / 32768.0
                sum += v * v
            }
            let value = sqrt(sum / Float(count))
            return min(1, value * 4)
        }
    }

    // MARK: - Interruptions

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        if type == .began, isActive {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        else { return }
        if reason == .oldDeviceUnavailable, isActive {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
            }
        }
    }
}

// MARK: - Audio delegate

extension DictationController: AudioEngineDelegate {
    func audioEngine(_ engine: AudioEngine, didCapture pcm: Data) {
        socket?.send(pcm)
        let level = rms(of: pcm)
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = level
        }
    }

    func audioEngine(_ engine: AudioEngine, didFailWith error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.status = .error(error.localizedDescription)
            self?.stop()
        }
    }
}

// MARK: - Deepgram delegate

extension DictationController: DeepgramSocketDelegate {
    func deepgramDidOpen(_ socket: DeepgramSocket) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if case .connecting = self.status {
                self.status = .recording
            }
        }
    }

    func deepgram(_ socket: DeepgramSocket, didReceiveInterim text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.interimText = text
        }
    }

    func deepgram(_ socket: DeepgramSocket, didReceiveFinal text: String, speechFinal: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appendFinal(text)
            self.interimText = ""
        }
    }

    func deepgram(_ socket: DeepgramSocket, didCloseWith error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.socket = nil
            self.finalize(error: error)
        }
    }
}
