import Foundation

/// Receives results from any `TranscriptionEngine` — cloud, local, or
/// otherwise. Modeled after Deepgram's streaming shape (interim + final +
/// `speech_final`) because that's the richer of the two; engines that don't
/// produce interim results just skip the `didReceiveInterim` callback.
protocol TranscriptionEngineDelegate: AnyObject {
    func engineDidOpen(_ engine: TranscriptionEngine)
    func engine(_ engine: TranscriptionEngine, didReceiveInterim text: String)
    func engine(_ engine: TranscriptionEngine, didReceiveFinal text: String, speechFinal: Bool)
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
    func start()
    /// Raw 16 kHz mono linear16 (Int16, little-endian) PCM frame.
    func send(_ pcm: Data)
    func stop()
}
