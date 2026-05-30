import Combine
import Foundation
@preconcurrency import WhisperKit

/// Loads and caches a single WhisperKit (Core ML) instance keyed by model name,
/// so the expensive model is loaded at most once per name and reused across
/// dictation sessions. `DictationController` builds a fresh `WhisperKitEngine`
/// every session, so without this the model would reload on every press.
///
/// Also publishes download/load state so Settings can pre-warm a model and show
/// progress before the first dictation. Main-actor isolated — its `@Published`
/// `state` drives SwiftUI directly.
@MainActor
final class WhisperKitModelManager: ObservableObject {
    static let shared = WhisperKitModelManager()

    enum State: Equatable, Sendable {
        case idle
        case downloading(Double)   // 0...1
        case loading
        case ready(model: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    /// Coalesces concurrent requests for the same model into one load.
    private var inFlight: Task<WhisperKit, Error>?

    private init() {}

    /// Core ML model cache, inside the app's Application Support container so it
    /// survives launches and keeps the sandbox happy.
    private static var downloadBase: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cheboo/Models", isDirectory: true)
    }

    /// Kick off (or reuse) a load so the model is hot before dictation. Safe to
    /// call repeatedly; no-ops when the model is already loaded.
    func prewarm(modelName: String) {
        Task { _ = try? await model(named: modelName) }
    }

    /// Return a ready WhisperKit for `modelName`, downloading on first use and
    /// loading as needed. Reuses the cached instance when the name matches;
    /// switching names drops the old instance and loads the new one.
    func model(named modelName: String) async throws -> WhisperKit {
        if let whisperKit, loadedModelName == modelName { return whisperKit }
        if let inFlight, loadedModelName == modelName { return try await inFlight.value }

        loadedModelName = modelName
        whisperKit = nil

        let base = Self.downloadBase
        let report: @Sendable (State) -> Void = { [weak self] newState in
            Task { @MainActor in self?.state = newState }
        }
        let task = Task { try await Self.loadModel(named: modelName, downloadBase: base, report: report) }
        inFlight = task

        do {
            let wk = try await task.value
            // Only adopt the result if this load is still the current target. If
            // the user switched models while this one was loading, a newer load
            // owns `loadedModelName`/`inFlight` now and we must not clobber it
            // (doing so would hand back the wrong model on the next request).
            if loadedModelName == modelName {
                whisperKit = wk
                inFlight = nil
            }
            return wk
        } catch {
            if loadedModelName == modelName {
                inFlight = nil
                loadedModelName = nil
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Download (with progress) then load. Runs off the main actor; all UI
    /// updates go through `report`, which hops back to the main actor itself.
    private static func loadModel(
        named modelName: String,
        downloadBase: URL,
        report: @escaping @Sendable (State) -> Void
    ) async throws -> WhisperKit {
        Log.whisper.info("whisperkit load — model=\(modelName, privacy: .public)")
        try? FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

        report(.downloading(0))
        let folder = try await WhisperKit.download(
            variant: modelName,
            downloadBase: downloadBase,
            progressCallback: { progress in
                report(.downloading(progress.fractionCompleted))
            }
        )

        report(.loading)
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBase,
            modelFolder: folder.path,
            load: true,
            download: false
        )
        let wk = try await WhisperKit(config)
        report(.ready(model: modelName))
        Log.whisper.info("whisperkit ready — model=\(modelName, privacy: .public)")
        return wk
    }
}
