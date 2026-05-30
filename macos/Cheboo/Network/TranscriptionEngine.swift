import Foundation

/// Word-level timing for a single token inside a finalized segment. Times are
/// in seconds since the start of the recognition session. Engines that don't
/// surface word timings (e.g. Whisper batch) pass an empty array.
struct TranscriptWord {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
}

/// Receives results from any `TranscriptionEngine` — cloud, local, or
/// otherwise. Modeled after Deepgram's streaming shape (interim + final +
/// `speech_final`) because that's the richer of the two; engines that don't
/// produce interim results just skip the `didReceiveInterim` callback.
protocol TranscriptionEngineDelegate: AnyObject {
    func engineDidOpen(_ engine: TranscriptionEngine)
    func engine(_ engine: TranscriptionEngine, didReceiveInterim text: String)
    func engine(_ engine: TranscriptionEngine, didReceiveFinal text: String, speechFinal: Bool, words: [TranscriptWord])
    func engine(_ engine: TranscriptionEngine, didCloseWith error: Error?)
}

/// Abstraction over a speech-to-text backend. Concrete implementations are
/// the cloud Deepgram socket and a local whisper.cpp engine.
///
/// Lifecycle: `start()` → many `send(pcm:)` → `stop()`. The implementation is
/// expected to deliver one or more `didReceiveFinal` callbacks after stop,
/// then exactly one `didCloseWith` regardless of success/failure.
protocol TranscriptionEngine: AnyObject {
    var delegate: TranscriptionEngineDelegate? { get set }

    /// When `true`, the engine's authoritative transcript is a single
    /// `didReceiveFinal` delivered *after* `stop()`; any interim shown while
    /// recording is a lower-quality preview the controller should discard in
    /// favor of that final. Batch engines (Whisper) set this; streaming engines
    /// that finalize incrementally while recording (Deepgram) leave it `false`.
    var finalizesAfterStop: Bool { get }

    func start()
    /// Raw 16 kHz mono linear16 (Int16, little-endian) PCM frame.
    func send(_ pcm: Data)
    func stop()
}

extension TranscriptionEngine {
    /// Streaming engines finalize as they go, so there's no distinct post-stop
    /// final to wait for.
    var finalizesAfterStop: Bool { false }
}
