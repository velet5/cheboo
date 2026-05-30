import Foundation

/// OpenAI-compatible Whisper transcription over HTTP. Same wire format as
/// `POST /v1/audio/transcriptions` against `api.openai.com`, but pointed by
/// default at `127.0.0.1:8080` — the port whisper.cpp's `server` example
/// listens on. Anything that speaks that protocol works without code changes:
/// `whisper.cpp` server, `faster-whisper-server`, `mlx-whisper-server`, or
/// OpenAI's own cloud endpoint (with a Bearer key).
///
/// Whisper is batch — we buffer Int16 PCM the audio engine delivers between
/// `start()` and `stop()`, then on stop wrap the PCM in a minimal 16 kHz mono
/// WAV header, POST a `multipart/form-data` request, and emit a single
/// `didReceiveFinal(speechFinal: true)` followed by `didCloseWith(nil)`.
///
/// Interim transcripts aren't surfaced — running the same model repeatedly
/// on growing prefixes blows compute budget for negligible UX gain.
final class WhisperServerEngine: TranscriptionEngine {
    weak var delegate: TranscriptionEngineDelegate?

    /// Batch: the only transcript arrives after `stop()`.
    let finalizesAfterStop = true

    private let baseURL: String
    private let apiKey: String
    private let language: String
    private let model: String
    private let urlSession: URLSession
    private let workerQueue = DispatchQueue(label: "com.github.velet5.cheboo.whisper-server")
    private var pcmBuffer = Data()
    private var stopped = false

    init(
        baseURL: String,
        apiKey: String,
        language: String,
        model: String = "whisper-1"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.language = language
        self.model = model
        let config = URLSessionConfiguration.default
        // Whisper on cold-start with a large model can chew through 30-60s
        // before responding; keep the request alive long enough for that.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    func start() {
        Log.whisper.info("whisper-server start — baseURL=\(self.baseURL, privacy: .public) lang=\(self.language, privacy: .public)")
        stopped = false
        // Reset the buffer on the same queue every other access uses, so the
        // first `send()` after start() can't race with the wipe.
        workerQueue.async { [weak self] in
            self?.pcmBuffer.removeAll(keepingCapacity: true)
        }

        guard let _ = resolvedEndpoint() else {
            failOnStart(message: "Invalid Whisper server URL: \(baseURL)")
            return
        }

        // No real "open" step for a request-response API; signal readiness
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
        Log.whisper.info("whisper-server stop — flushing buffered audio")
        stopped = true
        workerQueue.async { [weak self] in
            self?.flushAndTranscribe()
        }
    }

    private func failOnStart(message: String) {
        Log.whisper.error("whisper-server start failed: \(message, privacy: .public)")
        let err = NSError(
            domain: "WhisperServer",
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
        guard let endpoint = resolvedEndpoint() else {
            failOnStart(message: "Invalid Whisper server URL: \(baseURL)")
            return
        }

        let wav = Self.wrapPCMAsWAV(pcm: pcm, sampleRate: 16_000, channels: 1)
        Log.whisper.info("posting \(wav.count, privacy: .public) bytes WAV to \(endpoint.absoluteString, privacy: .public)")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            wav: wav,
            model: model,
            language: language,
            responseFormat: "json"
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
                domain: "WhisperServer",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Whisper server returned HTTP \(http.statusCode): \(body.prefix(200))"]
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didCloseWith: err)
            }
            return
        }

        let transcript = Self.parseTranscript(data ?? Data())
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.whisper.info("transcript chars=\(trimmed.count, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !trimmed.isEmpty {
                self.delegate?.engine(self, didReceiveFinal: trimmed, speechFinal: true, words: [])
            }
            self.delegate?.engine(self, didCloseWith: nil)
        }
    }

    /// Build the request URL from the user's base URL. Accepts either a bare
    /// origin (`http://127.0.0.1:8080`) or a full path; if the path is missing
    /// or only `/`, we append the standard OpenAI route.
    private func resolvedEndpoint() -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed) else { return nil }
        if url.path.isEmpty || url.path == "/" {
            return url.appendingPathComponent("v1/audio/transcriptions")
        }
        return url
    }

    // MARK: Response parsing

    /// Decode `{"text": "..."}` (default `response_format=json`). Falls back
    /// to treating the body as plain text for `response_format=text` servers
    /// that don't follow the JSON contract.
    private static func parseTranscript(_ data: Data) -> String {
        struct Body: Decodable { let text: String? }
        // A well-formed JSON body wins even when `text` is null/absent — return
        // the (possibly empty) string rather than falling through and typing the
        // raw `{"text":null}` JSON as if it were a transcript.
        if let body = try? JSONDecoder().decode(Body.self, from: data) {
            return body.text ?? ""
        }
        // Plain-text servers (response_format=text) don't return JSON at all.
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: WAV encoding

    /// Wrap raw little-endian Int16 PCM in a minimal 44-byte WAV header so
    /// the multipart upload's filename `audio.wav` matches the bytes. Both
    /// whisper.cpp's server and OpenAI's API accept WAV directly without a
    /// re-encode pass.
    static func wrapPCMAsWAV(pcm: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: chunkSize.littleEndianBytes)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(contentsOf: UInt32(16).littleEndianBytes)         // PCM subchunk size
        header.append(contentsOf: UInt16(1).littleEndianBytes)          // audio format = PCM
        header.append(contentsOf: channels.littleEndianBytes)
        header.append(contentsOf: sampleRate.littleEndianBytes)
        header.append(contentsOf: byteRate.littleEndianBytes)
        header.append(contentsOf: blockAlign.littleEndianBytes)
        header.append(contentsOf: bitsPerSample.littleEndianBytes)
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: dataSize.littleEndianBytes)

        var out = Data(capacity: header.count + pcm.count)
        out.append(header)
        out.append(pcm)
        return out
    }

    // MARK: Multipart body

    private static func multipartBody(
        boundary: String,
        wav: Data,
        model: String,
        language: String,
        responseFormat: String
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)
        appendField(name: "response_format", value: responseFormat)
        // Skip the language field entirely on "auto" — both servers do
        // automatic detection if the param is missing, but some reject the
        // literal string "auto".
        if !language.isEmpty, language != "auto" {
            appendField(name: "language", value: language)
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

private extension FixedWidthInteger {
    /// Little-endian byte representation, regardless of host endianness.
    var littleEndianBytes: [UInt8] {
        let value = self.littleEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}
