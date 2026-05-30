import Combine
import Foundation

/// Captures the same 16 kHz mono Int16 PCM Cheboo sends to the recognizer plus
/// the recognizer's finalized transcript (with Deepgram word timestamps when
/// the engine supplies them) and persists each session as a `<id>.wav` +
/// `<id>.json` pair. Designed so the resulting directory can be used as a
/// personal training corpus for later speech-model fine-tuning.
///
/// Threading model: all session-state mutations (`beginSession`, `appendPCM`,
/// `appendFinal`, `finalizeSession`) funnel through `queue`, which is also the
/// queue WAV/JSON writes run on. FIFO ordering on the serial queue means any
/// in-flight `appendPCM` enqueued before `finalizeSession` lands in the same
/// session it was captured for. Stats are published back to the main thread
/// so SwiftUI bindings see a live count.
final class DatasetRecorder: ObservableObject {
    struct Stats: Codable, Equatable {
        var sessionCount: Int = 0
        var totalAudioSeconds: Double = 0
        var totalWords: Int = 0
    }

    @Published private(set) var stats: Stats = .init()

    let baseDirectory: URL
    var sessionsDirectory: URL { baseDirectory.appendingPathComponent("sessions", isDirectory: true) }
    private var statsURL: URL { baseDirectory.appendingPathComponent("stats.json") }

    private let queue = DispatchQueue(label: "com.github.velet5.cheboo.dataset", qos: .utility)

    // Per-session state — only valid between beginSession() and finalizeSession()
    // on `queue`.
    private var sessionID: String?
    private var sessionStartedAt: Date?
    private var sessionPCM = Data()
    private var sessionSegments: [PersistedSegment] = []
    private var sessionEngine = ""
    private var sessionLanguage = ""
    private var sessionModel = ""

    /// 16 kHz mono Int16 → 2 bytes per sample × 16000 samples = 32 kB / s.
    private let bytesPerSecond: Double = 16_000 * 2

    init(directory: URL? = nil) {
        self.baseDirectory = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        loadStats()
    }

    static func defaultDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Cheboo/Dataset", isDirectory: true)
    }

    // MARK: - Session lifecycle

    /// Open a recording session. Subsequent `appendPCM` / `appendFinal` calls
    /// are attributed to this session until `finalizeSession()` runs. No-op if
    /// a session is already open — the caller is responsible for finalizing
    /// the previous one first.
    func beginSession(engine: String, language: String, model: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.sessionID != nil { return }
            let id = Self.makeSessionID()
            self.sessionID = id
            self.sessionStartedAt = Date()
            self.sessionPCM = Data()
            self.sessionSegments = []
            self.sessionEngine = engine
            self.sessionLanguage = language
            self.sessionModel = model
            Log.dataset.info("session \(id, privacy: .public) begin engine=\(engine, privacy: .public) lang=\(language, privacy: .public)")
        }
    }

    func appendPCM(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self, self.sessionID != nil else { return }
            self.sessionPCM.append(pcm)
        }
    }

    func appendFinal(text: String, speechFinal: Bool, words: [TranscriptWord]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.sessionID != nil else { return }
            let persisted = words.map {
                PersistedWord(
                    text: $0.text,
                    start: $0.start,
                    end: $0.end,
                    confidence: $0.confidence
                )
            }
            let segment = PersistedSegment(
                text: trimmed,
                start: persisted.first?.start,
                end: persisted.last?.end,
                speechFinal: speechFinal,
                words: persisted
            )
            self.sessionSegments.append(segment)
        }
    }

    /// Snapshot, clear, and persist the current session. Empty sessions (no
    /// audio captured) are dropped without producing files so the dataset
    /// doesn't fill up with zero-byte recordings from accidental taps.
    func finalizeSession() {
        queue.async { [weak self] in
            guard let self, let id = self.sessionID else { return }
            let pcm = self.sessionPCM
            let segments = self.sessionSegments
            let startedAt = self.sessionStartedAt ?? Date()
            let engine = self.sessionEngine
            let language = self.sessionLanguage
            let model = self.sessionModel

            // Clear in-memory state up front so a new session can begin even
            // if the write below stalls.
            self.sessionID = nil
            self.sessionStartedAt = nil
            self.sessionPCM = Data()
            self.sessionSegments = []
            self.sessionEngine = ""
            self.sessionLanguage = ""
            self.sessionModel = ""

            guard !pcm.isEmpty else {
                Log.dataset.info("session \(id, privacy: .public) discarded (no audio)")
                return
            }

            let durationSeconds = Double(pcm.count) / self.bytesPerSecond
            let wordCount = Self.countWords(segments: segments)

            self.writeSession(
                id: id,
                pcm: pcm,
                segments: segments,
                startedAt: startedAt,
                durationSeconds: durationSeconds,
                engine: engine,
                language: language,
                model: model
            )

            var snapshot = Stats()
            DispatchQueue.main.sync {
                snapshot = self.stats
                snapshot.sessionCount += 1
                snapshot.totalAudioSeconds += durationSeconds
                snapshot.totalWords += wordCount
                self.stats = snapshot
            }
            self.persistStats(snapshot)
        }
    }

    /// Drop any in-progress session without writing it. Used when a session
    /// errors out before we'd want it in the corpus.
    func cancelSession() {
        queue.async { [weak self] in
            guard let self, let id = self.sessionID else { return }
            Log.dataset.info("session \(id, privacy: .public) cancelled")
            self.sessionID = nil
            self.sessionStartedAt = nil
            self.sessionPCM = Data()
            self.sessionSegments = []
            self.sessionEngine = ""
            self.sessionLanguage = ""
            self.sessionModel = ""
        }
    }

    // MARK: - IO (runs on `queue`)

    private func writeSession(
        id: String,
        pcm: Data,
        segments: [PersistedSegment],
        startedAt: Date,
        durationSeconds: Double,
        engine: String,
        language: String,
        model: String
    ) {
        do {
            try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

            let wavURL = sessionsDirectory.appendingPathComponent("\(id).wav")
            try Self.wrapWAV(pcm: pcm, sampleRate: 16_000, channels: 1).write(to: wavURL, options: .atomic)

            let transcript = segments
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let record = PersistedSession(
                sessionID: id,
                startedAt: Self.iso8601(startedAt),
                durationSeconds: durationSeconds,
                engine: engine,
                language: language,
                model: model,
                audio: PersistedAudio(
                    file: "\(id).wav",
                    sampleRate: 16_000,
                    channels: 1,
                    encoding: "linear16"
                ),
                transcript: transcript,
                segments: segments
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonURL = sessionsDirectory.appendingPathComponent("\(id).json")
            try encoder.encode(record).write(to: jsonURL, options: .atomic)

            Log.dataset.info(
                "session \(id, privacy: .public) persisted (\(pcm.count, privacy: .public) PCM bytes, \(segments.count, privacy: .public) segments)"
            )
        } catch {
            Log.dataset.error(
                "failed to persist session \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func loadStats() {
        let url = statsURL
        queue.async { [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Stats.self, from: data)
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.stats = decoded
            }
        }
    }

    private func persistStats(_ snapshot: Stats) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try data.write(to: statsURL, options: .atomic)
        } catch {
            Log.dataset.error("failed to persist stats: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func countWords(segments: [PersistedSegment]) -> Int {
        var total = 0
        for segment in segments {
            if !segment.words.isEmpty {
                total += segment.words.count
            } else {
                total += segment.text
                    .split(whereSeparator: { $0.isWhitespace })
                    .count
            }
        }
        return total
    }

    private static func makeSessionID() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        // `:` is illegal in HFS+ filenames and unfriendly across tooling; the
        // `T...Z` shape stays sortable and round-trips back to a date when the
        // user reads the file.
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f.string(from: Date())
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// 44-byte RIFF/WAVE header for linear PCM. Same layout the Whisper engine
    /// uses; duplicated here to avoid leaking the helper out of that file.
    static func wrapWAV(pcm: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: chunkSize.dataset_le)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(contentsOf: UInt32(16).dataset_le)
        header.append(contentsOf: UInt16(1).dataset_le)
        header.append(contentsOf: channels.dataset_le)
        header.append(contentsOf: sampleRate.dataset_le)
        header.append(contentsOf: byteRate.dataset_le)
        header.append(contentsOf: blockAlign.dataset_le)
        header.append(contentsOf: bitsPerSample.dataset_le)
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: dataSize.dataset_le)

        var out = Data(capacity: header.count + pcm.count)
        out.append(header)
        out.append(pcm)
        return out
    }

    // MARK: - On-disk JSON shapes

    private struct PersistedWord: Codable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Double?
    }

    private struct PersistedSegment: Codable {
        let text: String
        let start: TimeInterval?
        let end: TimeInterval?
        let speechFinal: Bool
        let words: [PersistedWord]
    }

    private struct PersistedAudio: Codable {
        let file: String
        let sampleRate: Int
        let channels: Int
        let encoding: String
    }

    private struct PersistedSession: Codable {
        let sessionID: String
        let startedAt: String
        let durationSeconds: Double
        let engine: String
        let language: String
        let model: String
        let audio: PersistedAudio
        let transcript: String
        let segments: [PersistedSegment]
    }
}

private extension FixedWidthInteger {
    /// Little-endian byte representation, regardless of host endianness.
    var dataset_le: [UInt8] {
        let value = self.littleEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}
