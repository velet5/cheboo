import Foundation

/// OpenAI's `gpt-transcribe` speech-to-text model, over
/// `POST https://api.openai.com/v1/audio/transcriptions`.
///
/// Batch, like `WhisperServerEngine`: buffer the Int16 PCM the audio engine
/// delivers between `start()` and `stop()`, then wrap it in a 16 kHz mono WAV
/// header, upload it, and emit a single `didReceiveFinal(speechFinal: true)`
/// followed by `didCloseWith(nil)`.
///
/// It gets its own type rather than a `model:` argument on `WhisperServerEngine`
/// because the request shape genuinely differs. Whisper takes a singular
/// `language` plus a free-text decoder `prompt`; gpt-transcribe takes repeated
/// `keywords[]` and `languages[]` fields, rejects `verbose_json`, and has no
/// notion of "auto" for a language (you omit the field instead).
///
/// The `keywords[]` field is why this engine is worth having: Cheboo's per-app
/// keyterm lists map straight onto it as a first-class biasing input, instead
/// of the prompt-stuffing workaround Whisper needs. Cross-script terms are safe
/// to pass here — where a mismatched Whisper decoder prompt can zero out the
/// transcript entirely (see `DictationLanguage.promptTerms`), gpt-transcribe
/// just ignores keywords the audio doesn't contain.
///
/// Interim transcripts aren't surfaced. The API does offer an SSE mode
/// (`stream=true`, `transcript.text.delta` events), but measured against a
/// 60 s utterance the first delta lands at essentially the same moment the
/// non-streaming response does — the model isn't emitting incrementally as it
/// decodes — so it buys nothing but a second parser.
final class GPTTranscribeEngine: TranscriptionEngine {
    weak var delegate: TranscriptionEngineDelegate?

    /// Batch: the only transcript arrives after `stop()`.
    let finalizesAfterStop = true

    /// The model this engine exists to drive. Not user-selectable — the sibling
    /// `gpt-4o-transcribe` models don't accept `keywords[]`/`languages[]`, so
    /// swapping the id would silently drop the keyterm biasing.
    static let model = "gpt-transcribe"

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    private let apiKey: String
    /// BCP-47 codes for the languages we expect in the audio. Empty means "let
    /// the model detect it" — the API rejects a literal "auto", so omission is
    /// how auto-detection is requested.
    private let languages: [String]
    /// Vocabulary hints sent as repeated `keywords[]` fields. Hints only: the
    /// model includes one only when it actually hears it.
    private let keywords: [String]
    private let urlSession: URLSession
    private let workerQueue = DispatchQueue(label: "com.github.velet5.cheboo.gpt-transcribe")
    private var pcmBuffer = Data()
    private var stopped = false

    init(apiKey: String, languages: [String], keywords: [String]) {
        self.apiKey = apiKey
        self.languages = languages
        self.keywords = keywords
        let config = URLSessionConfiguration.default
        // A minute of speech turns around in ~2s, but the upload is the whole
        // utterance and long dictations get chunked server-side; leave enough
        // headroom that a slow link doesn't cancel a transcript we already
        // paid for.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    func start() {
        Log.whisper.info(
            "gpt-transcribe start — languages=\(self.languages.joined(separator: ","), privacy: .public) keywords=\(self.keywords.count)"
        )
        stopped = false
        // Reset the buffer on the same queue every other access uses, so the
        // first `send()` after start() can't race with the wipe.
        workerQueue.async { [weak self] in
            self?.pcmBuffer.removeAll(keepingCapacity: true)
        }

        guard !apiKey.isEmpty else {
            fail(message: "Set an OpenAI API key in Settings → Engine.")
            return
        }

        // No "open" step for a request-response API; signal readiness
        // immediately so the controller can flip into the recording state.
        delegate?.engineDidOpen(self)
    }

    func send(_ pcm: Data) {
        guard !stopped else { return }
        workerQueue.async { [weak self] in
            self?.pcmBuffer.append(pcm)
        }
    }

    func stop() {
        Log.whisper.info("gpt-transcribe stop — flushing buffered audio")
        stopped = true
        workerQueue.async { [weak self] in
            self?.flushAndTranscribe()
        }
    }

    private func fail(message: String) {
        Log.whisper.error("gpt-transcribe failed: \(message, privacy: .public)")
        let err = NSError(
            domain: "GPTTranscribe",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didCloseWith: err)
        }
    }

    private func flushAndTranscribe() {
        let pcm = pcmBuffer
        pcmBuffer.removeAll(keepingCapacity: false)

        guard !pcm.isEmpty else {
            Log.whisper.info("no audio captured — closing with empty transcript")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didCloseWith: nil)
            }
            return
        }

        // Same 16 kHz mono Int16 layout the Whisper engine uploads, so it reuses
        // that engine's header writer rather than carrying a second copy.
        let wav = WhisperServerEngine.wrapPCMAsWAV(pcm: pcm, sampleRate: 16_000, channels: 1)
        Log.whisper.info("posting \(wav.count, privacy: .public) bytes WAV to gpt-transcribe")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            wav: wav,
            languages: languages,
            keywords: keywords
        )

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.handleResponse(data: data, response: response, error: error)
        }
        task.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            Log.whisper.error("HTTP error: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didCloseWith: error)
            }
            return
        }

        let http = response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Log.whisper.error("HTTP \(http.statusCode, privacy: .public): \(body, privacy: .public)")
            let err = NSError(
                domain: "GPTTranscribe",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: Self.errorMessage(status: http.statusCode, body: body)]
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didCloseWith: err)
            }
            return
        }

        let parsed = Self.parse(data ?? Data())
        let trimmed = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.whisper.info(
            "transcript chars=\(trimmed.count, privacy: .public) detected=\(parsed.languages.joined(separator: ","), privacy: .public)"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !trimmed.isEmpty {
                // gpt-transcribe returns no word timings — `verbose_json` isn't
                // a supported response format for this model — so the dataset
                // recorder gets segment-level text only.
                self.delegate?.engine(self, didReceiveFinal: trimmed, speechFinal: true, words: [])
            }
            self.delegate?.engine(self, didCloseWith: nil)
        }
    }

    // MARK: Response parsing

    /// Decode `{"text": "...", "languages": [{"code": "en"}], "usage": {...}}`.
    /// The detected languages are logged rather than surfaced — nothing in the
    /// pipeline switches on them — but they're the quickest way to tell a
    /// misrouted language hint from a genuine recognition miss.
    private static func parse(_ data: Data) -> (text: String, languages: [String]) {
        struct Body: Decodable {
            struct Language: Decodable { let code: String? }
            let text: String?
            let languages: [Language]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            return (String(data: data, encoding: .utf8) ?? "", [])
        }
        return (body.text ?? "", (body.languages ?? []).compactMap(\.code))
    }

    /// Turn the two failures a user can actually fix into plain language; fall
    /// back to the raw body for everything else.
    private static func errorMessage(status: Int, body: String) -> String {
        switch status {
        case 401:
            return "OpenAI rejected the API key. Check it in Settings → Engine."
        case 429:
            return "OpenAI rate limit or quota exceeded — check your billing."
        default:
            return "gpt-transcribe returned HTTP \(status): \(body.prefix(200))"
        }
    }

    // MARK: Multipart body

    private static func multipartBody(
        boundary: String,
        wav: Data,
        languages: [String],
        keywords: [String]
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)
        // `json` and `text` are the only formats gpt-transcribe accepts; asking
        // for `verbose_json` (and its word timings) is a hard 400.
        appendField(name: "response_format", value: "json")
        // Repeated array fields. Omitted entirely when empty — an empty
        // `languages[]` is rejected, and "auto" isn't a valid value, so
        // sending nothing is how auto-detection is requested.
        for language in languages {
            appendField(name: "languages[]", value: language)
        }
        for keyword in keywords {
            appendField(name: "keywords[]", value: keyword)
        }

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(wav)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}
