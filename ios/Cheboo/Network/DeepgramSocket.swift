import Foundation

protocol DeepgramSocketDelegate: AnyObject {
    func deepgramDidOpen(_ socket: DeepgramSocket)
    func deepgram(_ socket: DeepgramSocket, didReceiveInterim text: String)
    func deepgram(_ socket: DeepgramSocket, didReceiveFinal text: String, speechFinal: Bool)
    func deepgram(_ socket: DeepgramSocket, didCloseWith error: Error?)
}

/// Thin wrapper over `URLSessionWebSocketTask` for Deepgram's
/// `wss://api.deepgram.com/v1/listen` realtime endpoint.
final class DeepgramSocket: NSObject {
    weak var delegate: DeepgramSocketDelegate?

    private let apiKey: String
    private let model: String
    private let language: String
    private let punctuate: Bool
    private let smartFormat: Bool
    private let keyterms: [String]
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var isClosed = false
    /// `URLSession(delegate:)` strongly retains its delegate (us), so we have
    /// to invalidate the session ourselves to break the cycle. Calling it
    /// more than once is harmless but pointless — this flag keeps the path
    /// idempotent across the three sites that can race to finish the socket.
    private var sessionInvalidated = false

    init(
        apiKey: String,
        model: String,
        language: String,
        punctuate: Bool,
        smartFormat: Bool,
        keyterms: [String]
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.punctuate = punctuate
        self.smartFormat = smartFormat
        self.keyterms = keyterms
        super.init()
        let config = URLSessionConfiguration.default
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func connect() {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "500"),
            URLQueryItem(name: "smart_format", value: smartFormat ? "true" : "false"),
            URLQueryItem(name: "punctuate", value: punctuate ? "true" : "false"),
        ]
        // Keyterms only sent when the user has some configured — Deepgram
        // bumps to a pricier per-minute tier whenever `keyterm` is on the
        // request, so an empty list stays on the cheaper plan.
        for term in keyterms.prefix(100) {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
    }

    /// Send a raw PCM frame (linear16, 16 kHz, mono).
    func send(_ pcm: Data) {
        guard let task, !isClosed else { return }
        task.send(.data(pcm)) { [weak self] error in
            guard let self, let error else { return }
            if !self.isClosed {
                self.isClosed = true
                self.delegate?.deepgram(self, didCloseWith: error)
            }
            self.invalidateSession()
        }
    }

    /// Send Deepgram's `CloseStream` and let the server flush any in-flight
    /// transcript before closing. Force-close after a safety window so a
    /// stuck socket doesn't linger forever.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        let message = "{\"type\":\"CloseStream\"}"
        task?.send(.string(message)) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.task?.cancel(with: .normalClosure, reason: nil)
            self?.invalidateSession()
        }
    }

    /// Break the URLSession's strong retain on us. Safe to call from any of
    /// the three close paths (explicit close, receive failure, server-side
    /// closure) — the second call is a no-op.
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
                if !self.isClosed {
                    self.isClosed = true
                    self.delegate?.deepgram(self, didCloseWith: error)
                }
                self.invalidateSession()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return
        }

        guard let response = try? JSONDecoder().decode(DeepgramResponse.self, from: data),
              let transcript = response.firstTranscript
        else { return }

        if response.isFinal == true {
            delegate?.deepgram(
                self,
                didReceiveFinal: transcript,
                speechFinal: response.speechFinal ?? false
            )
        } else {
            delegate?.deepgram(self, didReceiveInterim: transcript)
        }
    }
}

extension DeepgramSocket: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        delegate?.deepgramDidOpen(self)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        if !isClosed {
            isClosed = true
            delegate?.deepgram(self, didCloseWith: nil)
        }
        invalidateSession()
    }
}
