import AVFoundation
import Foundation

/// OpenAI's `gpt-live-transcribe` over the Realtime API's transcription
/// session — `wss://api.openai.com/v1/realtime?intent=transcription`.
///
/// This is the streaming counterpart to `GPTTranscribeEngine`: instead of
/// uploading the whole utterance on release, audio is appended to a server-side
/// buffer while you speak and the model returns `...transcription.delta` events
/// token by token, so text appears live the way it does with Deepgram.
///
/// Turn detection is left off and the buffer is committed explicitly in
/// `stop()`. Push-to-talk already defines the turn boundary — the hotkey — so
/// server-side VAD would only add a second, competing opinion about where the
/// utterance ends. That makes the authoritative transcript the `completed`
/// event that lands after commit, hence `finalizesAfterStop`; the deltas shown
/// while recording are a live preview the controller discards in its favor.
///
/// At $0.017/minute this is roughly 3.8× the cost of batch `gpt-transcribe`.
final class GPTLiveTranscribeEngine: NSObject, TranscriptionEngine {
    weak var delegate: TranscriptionEngineDelegate?

    /// The transcript of record arrives after `stop()` commits the buffer.
    let finalizesAfterStop = true

    static let model = "gpt-live-transcribe"

    /// The Realtime API's minimum accepted input rate. Cheboo's tap produces
    /// 16 kHz (what Deepgram, Whisper, and the dataset corpus all use), so this
    /// engine resamples on the way out rather than forcing a capture-wide
    /// change. Upsampling can't restore band the 16 kHz capture never had, but
    /// speech energy sits well below that ceiling — a 16 kHz dataset recording
    /// resampled to 24 kHz transcribes identically to the Deepgram reference.
    private static let wireSampleRate: Double = 24_000
    private static let captureSampleRate: Double = 16_000

    private let apiKey: String
    private let languages: [String]
    private let keywords: [String]

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var isClosed = false
    /// `URLSession(delegate:)` retains its delegate (us); mirror
    /// `DeepgramSocket` and break the cycle exactly once.
    private var sessionInvalidated = false
    /// Running concatenation of the deltas for the utterance in flight, so each
    /// token can be surfaced as a cumulative interim rather than a fragment.
    private var interim = ""
    private var converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    /// Bytes actually appended to the server buffer, used to decide whether a
    /// commit is worth attempting at all (see `minimumCommitBytes`).
    private var appendedBytes = 0

    /// The API refuses to commit a buffer holding under 100 ms of audio. A
    /// stray hotkey tap produces exactly that, so we check locally and close
    /// quietly instead of surfacing "buffer too small… 0.00ms of audio" as a
    /// user-facing error. 150 ms of 24 kHz mono Int16 leaves margin over the
    /// server's threshold without swallowing anything a person could dictate.
    private static let minimumCommitBytes = Int(wireSampleRate * 0.150) * 2

    init(apiKey: String, languages: [String], keywords: [String]) {
        self.apiKey = apiKey
        self.languages = languages
        self.keywords = keywords
        // Interleaved mono Int16 on both sides — the tap's wire format, just
        // at a different rate, so the converter only has to resample.
        self.inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.captureSampleRate,
            channels: 1,
            interleaved: true
        )!
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.wireSampleRate,
            channels: 1,
            interleaved: true
        )!
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        self.converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        if converter == nil {
            Log.socket.error("failed to build 16k→24k converter for gpt-live-transcribe")
        }
    }

    func start() {
        guard !apiKey.isEmpty else {
            failToOpen(message: "Set an OpenAI API key in Settings → Engine.")
            return
        }
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // No `OpenAI-Beta: realtime=v1`: the beta shape is retired and sending
        // it now fails the session outright with `beta_api_shape_disabled`.

        Log.socket.info(
            "connecting gpt-live-transcribe — languages=\(self.languages.joined(separator: ","), privacy: .public) keywords=\(self.keywords.count)"
        )
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
    }

    /// Raw 16 kHz mono linear16 from the tap, resampled to 24 kHz and appended
    /// to the server-side buffer as base64.
    func send(_ pcm: Data) {
        guard let task, !isClosed, !pcm.isEmpty else { return }
        guard let resampled = resampleTo24k(pcm) else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": resampled.base64EncodedString(),
        ]
        appendedBytes += resampled.count
        sendJSON(payload, on: task)
    }

    func stop() {
        guard !isClosed, let task else {
            closeNow()
            return
        }
        guard appendedBytes >= Self.minimumCommitBytes else {
            // Nothing worth transcribing — a tapped hotkey rather than speech.
            Log.socket.info("skipping commit — only \(self.appendedBytes) bytes buffered")
            isClosed = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didCloseWith: nil)
            }
            task.cancel(with: .normalClosure, reason: nil)
            invalidateSession()
            return
        }
        Log.socket.info("committing gpt-live-transcribe buffer")
        // Commit turns the buffered audio into an item; its transcription
        // arrives as the `completed` event we treat as the final.
        sendJSON(["type": "input_audio_buffer.commit"], on: task)
        // Don't let the socket hang if the completion never lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self, !self.isClosed else { return }
            Log.socket.error("timed out waiting for transcription.completed")
            self.isClosed = true
            self.delegate?.engine(self, didCloseWith: nil)
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.invalidateSession()
        }
    }

    // MARK: Audio

    /// 16 kHz → 24 kHz. Returns nil (dropping the frame) if the converter
    /// couldn't be built or the conversion errored — better to lose a frame
    /// than to push a malformed rate the session would reject.
    private func resampleTo24k(_ pcm: Data) -> Data? {
        guard let converter else { return nil }
        let inFrames = AVAudioFrameCount(pcm.count / 2)
        guard inFrames > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inFrames)
        else { return nil }
        inBuffer.frameLength = inFrames
        pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress, let dst = inBuffer.int16ChannelData?[0] else { return }
            memcpy(dst, src, pcm.count)
        }

        let ratio = Self.wireSampleRate / Self.captureSampleRate
        let capacity = AVAudioFrameCount(Double(inFrames) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            // One-shot: hand over this frame, then report end-of-stream so the
            // converter flushes instead of stalling waiting for more input.
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        if let error {
            Log.socket.error("resample failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard outBuffer.frameLength > 0, let channel = outBuffer.int16ChannelData?[0] else { return nil }
        return Data(bytes: channel, count: Int(outBuffer.frameLength) * 2)
    }

    // MARK: Socket plumbing

    private func sendJSON(_ object: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            Log.socket.error("socket send error: \(error.localizedDescription, privacy: .public)")
            guard !self.isClosed else { return }
            self.isClosed = true
            self.delegate?.engine(self, didCloseWith: error)
            self.invalidateSession()
        }
    }

    /// Session config. `turn_detection: null` keeps the server from guessing at
    /// utterance boundaries — the hotkey already defines them.
    private func sendSessionUpdate(on task: URLSessionWebSocketTask) {
        var transcription: [String: Any] = ["model": Self.model]
        // Same reasoning as GPTTranscribeEngine: keywords are hints the model
        // drops when it doesn't hear them, so the list goes over unfiltered.
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        // Omitted when empty so the model detects the language itself.
        if !languages.isEmpty { transcription["languages"] = languages }

        sendJSON([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Int(Self.wireSampleRate)],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ]
                ],
            ],
        ], on: task)
    }

    private func failToOpen(message: String) {
        Log.socket.error("gpt-live-transcribe failed: \(message, privacy: .public)")
        let err = NSError(
            domain: "GPTLiveTranscribe",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        isClosed = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didCloseWith: err)
        }
    }

    private func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel(with: .normalClosure, reason: nil)
        invalidateSession()
    }

    private func invalidateSession() {
        guard !sessionInvalidated else { return }
        sessionInvalidated = true
        session?.finishTasksAndInvalidate()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure(let error):
                guard !self.isClosed else { return }
                self.isClosed = true
                Log.socket.error("receive failure: \(error.localizedDescription, privacy: .public)")
                self.delegate?.engine(self, didCloseWith: error)
                self.invalidateSession()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        guard let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data) else { return }

        switch event.type {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = event.delta, !delta.isEmpty else { return }
            interim += delta
            let snapshot = interim
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didReceiveInterim: snapshot)
            }

        case "conversation.item.input_audio_transcription.completed":
            let transcript = (event.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            Log.socket.info("live transcript chars=\(transcript.count, privacy: .public)")
            interim = ""
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !transcript.isEmpty {
                    // The Realtime API surfaces no word timings, so the dataset
                    // recorder gets segment-level text only.
                    self.delegate?.engine(self, didReceiveFinal: transcript, speechFinal: true, words: [])
                }
                guard !self.isClosed else { return }
                self.isClosed = true
                self.delegate?.engine(self, didCloseWith: nil)
                self.task?.cancel(with: .normalClosure, reason: nil)
                self.invalidateSession()
            }

        case "error":
            let message = event.error?.message ?? "Realtime session error"
            Log.socket.error("realtime error: \(message, privacy: .public)")
            guard !isClosed else { return }
            isClosed = true
            let err = NSError(
                domain: "GPTLiveTranscribe",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: Self.errorMessage(message)]
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didCloseWith: err)
            }
            invalidateSession()

        default:
            break
        }
    }

    /// Rewrite the one server-side failure a user can act on; pass the rest
    /// through as the API worded them.
    private static func errorMessage(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("api key")
            || message.localizedCaseInsensitiveContains("authenticat") {
            return "OpenAI rejected the API key. Check it in Settings → Engine."
        }
        return message
    }

    private struct RealtimeEvent: Decodable {
        struct ErrorBody: Decodable { let message: String? }
        let type: String
        let delta: String?
        let transcript: String?
        let error: ErrorBody?
    }
}

extension GPTLiveTranscribeEngine: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Log.socket.info("gpt-live-transcribe socket opened")
        sendSessionUpdate(on: webSocketTask)
        delegate?.engineDidOpen(self)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Log.socket.info("gpt-live-transcribe socket closed code=\(closeCode.rawValue, privacy: .public)")
        if !isClosed {
            isClosed = true
            delegate?.engine(self, didCloseWith: nil)
        }
        invalidateSession()
    }
}
