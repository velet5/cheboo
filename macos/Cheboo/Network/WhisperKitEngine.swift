import Foundation
@preconcurrency import WhisperKit

/// On-device Whisper transcription via WhisperKit (Core ML on Apple Silicon).
///
/// Nothing leaves the machine and no server is required. We reuse Cheboo's
/// existing audio pipeline: the controller pushes 16 kHz mono Int16 PCM through
/// `send(_:)`, which we normalize to `[Float]` and accumulate. Streaming
/// interims come from periodically re-transcribing the growing buffer —
/// WhisperKit's `AudioStreamTranscriber` is avoided on purpose because it would
/// capture the microphone itself and bypass both `AudioEngine` and the dataset
/// recorder. On `stop()` we run one final pass with word timestamps and emit
/// `didReceiveFinal(speechFinal: true)` followed by `didCloseWith`.
///
/// The Core ML model is owned by `WhisperKitModelManager`, so it loads once and
/// is shared across sessions; `start()` opens only after the model is ready,
/// mirroring `DeepgramSocket` opening after its socket connects.
///
/// Re-transcribing a growing buffer is ~O(n²) over the utterance; the stride
/// gate below plus a single in-flight pass keep that bounded for
/// dictation-length clips.
///
/// `@unchecked Sendable`: all mutable state is confined to `workerQueue` and
/// delegate callbacks are dispatched to the main queue, so the instance is safe
/// to capture in the `Task` closures used to drive WhisperKit.
final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    weak var delegate: TranscriptionEngineDelegate?

    /// Even in streaming mode the interims are previews; the word-timestamped
    /// pass on `stop()` is the authoritative transcript.
    let finalizesAfterStop = true

    private let modelName: String
    private let language: String?   // nil = let Whisper auto-detect
    /// When false, skip interim passes and only transcribe once on `stop()`.
    private let streaming: Bool
    private let workerQueue = DispatchQueue(label: "com.github.velet5.cheboo.whisperkit")

    // Everything below is touched only on `workerQueue`.
    private var whisperKit: WhisperKit?
    private var samples: [Float] = []
    private var modelReady = false
    private var stopped = false
    private var closed = false
    private var transcribing = false
    private var finalPending = false
    private var lastInterimSampleCount = 0

    /// 16 kHz mono — re-transcribe for an interim once this much *new* audio has
    /// piled up. Larger = less compute, choppier interims. (~1.0 s.)
    private static let interimSampleStride = 16_000

    init(modelName: String, language: String, streaming: Bool) {
        self.modelName = modelName
        self.language = (language.isEmpty || language == "auto") ? nil : language
        self.streaming = streaming
    }

    func start() {
        Log.whisper.info("whisperkit start — model=\(self.modelName, privacy: .public) lang=\(self.language ?? "auto", privacy: .public)")
        workerQueue.async { [weak self] in
            guard let self else { return }
            self.samples.removeAll(keepingCapacity: true)
            self.modelReady = false
            self.stopped = false
            self.closed = false
            self.transcribing = false
            self.finalPending = false
            self.lastInterimSampleCount = 0
        }
        // Load (or reuse) the model, then signal readiness. Audio arriving
        // before this completes is simply buffered.
        Task { [weak self] in
            guard let self else { return }
            do {
                let wk = try await WhisperKitModelManager.shared.model(named: self.modelName)
                self.workerQueue.async {
                    self.whisperKit = wk
                    self.modelReady = true
                    DispatchQueue.main.async { self.delegate?.engineDidOpen(self) }
                    self.maybeRunInterim()
                }
            } catch {
                Log.whisper.error("whisperkit model load failed: \(error.localizedDescription, privacy: .public)")
                self.workerQueue.async { self.finish(error: error) }
            }
        }
    }

    func send(_ pcm: Data) {
        let floats = Self.int16ToFloat(pcm)
        workerQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.samples.append(contentsOf: floats)
            self.maybeRunInterim()
        }
    }

    func stop() {
        Log.whisper.info("whisperkit stop — finalizing")
        workerQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            if self.transcribing {
                // Let the in-flight interim settle, then run the final pass.
                self.finalPending = true
            } else {
                self.performFinal()
            }
        }
    }

    // MARK: - Transcription (all entry points run on workerQueue)

    private func maybeRunInterim() {
        guard streaming else { return }   // one-pass mode: defer everything to stop()
        guard modelReady, !transcribing, !stopped, let wk = whisperKit else { return }
        guard samples.count - lastInterimSampleCount >= Self.interimSampleStride else { return }
        let snapshot = samples
        lastInterimSampleCount = samples.count
        transcribing = true
        let lang = language
        Task { [weak self] in
            guard let self else { return }
            let result = try? await Self.transcribe(wk, snapshot, language: lang, wordTimestamps: false)
            self.workerQueue.async {
                self.transcribing = false
                if let text = result?.text, !self.stopped {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        DispatchQueue.main.async { self.delegate?.engine(self, didReceiveInterim: trimmed) }
                    }
                }
                if self.stopped {
                    if self.finalPending {
                        self.finalPending = false
                        self.performFinal()
                    }
                } else {
                    self.maybeRunInterim()
                }
            }
        }
    }

    private func performFinal() {
        guard !closed else { return }
        let snapshot = samples
        guard !snapshot.isEmpty else { finish(error: nil); return }
        transcribing = true
        let lang = language
        let preloaded = whisperKit
        let name = modelName
        Task { [weak self] in
            guard let self else { return }
            do {
                let wk: WhisperKit
                if let preloaded {
                    wk = preloaded
                } else {
                    wk = try await WhisperKitModelManager.shared.model(named: name)
                }
                let result = try await Self.transcribe(wk, snapshot, language: lang, wordTimestamps: true)
                let text = (result?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let words: [TranscriptWord] = (result?.allWords ?? []).map {
                    TranscriptWord(
                        text: $0.word,
                        start: TimeInterval($0.start),
                        end: TimeInterval($0.end),
                        confidence: Double($0.probability)
                    )
                }
                self.workerQueue.async {
                    if !text.isEmpty {
                        DispatchQueue.main.async {
                            self.delegate?.engine(self, didReceiveFinal: text, speechFinal: true, words: words)
                        }
                    }
                    self.finish(error: nil)
                }
            } catch {
                Log.whisper.error("whisperkit final transcribe failed: \(error.localizedDescription, privacy: .public)")
                self.workerQueue.async { self.finish(error: error) }
            }
        }
    }

    /// Emit `didCloseWith` exactly once.
    private func finish(error: Error?) {
        guard !closed else { return }
        closed = true
        transcribing = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didCloseWith: error)
        }
    }

    // MARK: - Helpers

    private static func transcribe(
        _ wk: WhisperKit,
        _ audio: [Float],
        language: String?,
        wordTimestamps: Bool
    ) async throws -> TranscriptionResult? {
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            wordTimestamps: wordTimestamps
        )
        let results = try await wk.transcribe(audioArray: audio, decodeOptions: options)
        return results.first
    }

    /// Little-endian Int16 PCM → normalized Float in [-1, 1]. Apple platforms
    /// are little-endian, so a direct reinterpret is correct.
    private static func int16ToFloat(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw -> [Float] in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768.0 }
        }
    }
}
