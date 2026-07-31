import AppKit
import Combine
import Foundation

/// Orchestrates the press-to-talk pipeline: hotkey → audio capture →
/// transcription engine → text injection + HUD.
///
/// Owned by the SwiftUI scene as a `@StateObject`. Delegate callbacks from
/// audio and engine queues hop to the main thread before mutating any
/// published state.
final class DictationController: ObservableObject {
    enum Status: Equatable {
        case idle
        case waitingForPermission(String)
        case connecting
        case recording
        case error(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .waitingForPermission(let what): return "Needs \(what) access"
            case .connecting: return "Connecting…"
            case .recording: return "Recording"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var interimText = ""
    @Published private(set) var isRecording = false

    /// Shown in the HUD while a batch engine (Whisper) runs its post-stop pass,
    /// so the screen isn't blank during a multi-second wait.
    private static let transcribingPlaceholder = "Transcribing…"

    private let audio = AudioEngine()
    private let injector = TextInjector()
    private let hud = HUDOverlay()
    private let subtitles = SubtitleOverlay()
    private let hotkey = HotkeyManager(id: 1)
    private let pasteHotkey = HotkeyManager(id: 2)
    private let clearSubtitlesHotkey = HotkeyManager(id: 3)
    private var engine: TranscriptionEngine?

    /// Personal speech corpus. Exposed so SwiftUI can observe `stats` directly
    /// for the Dataset settings tab.
    let dataset = DatasetRecorder()

    private var settings: SettingsStore?
    private var injectedSomething = false
    /// Snapshot of `settings.datasetCollectionEnabled` taken at session start
    /// — toggling the setting mid-session shouldn't half-record the utterance.
    private var datasetActiveForCurrentSession = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        audio.delegate = self
        hotkey.onPress = { [weak self] in self?.handleHotkeyPress() }
        hotkey.onRelease = { [weak self] in self?.handleHotkeyRelease() }
        pasteHotkey.onPress = { [weak self] in self?.flushBufferNow() }
        clearSubtitlesHotkey.onPress = { [weak self] in self?.subtitles.clear() }
    }

    /// Tear down the active dictation session and immediately open a new one
    /// so changed connection-time params (punctuation / capitalization) take
    /// effect. Whatever's currently on the HUD gets typed first so the user
    /// doesn't lose it.
    private func restartSession() {
        guard isRecording else { return }
        stop()
        start()
    }

    private func handleHotkeyPress() {
        switch settings?.hotkeyBehavior ?? .pushToTalk {
        case .pushToTalk:
            start()
        case .toggle:
            if isRecording { stop() } else { start() }
        }
    }

    private func handleHotkeyRelease() {
        switch settings?.hotkeyBehavior ?? .pushToTalk {
        case .pushToTalk:
            stop()
        case .toggle:
            break
        }
    }

    func bind(settings: SettingsStore) {
        self.settings = settings
        hud.bind(settings: settings)
        subtitles.bind(settings: settings)
        applyHotkey()

        cancellables.removeAll()
        // Push the user's mic choice to the audio engine at boot and any
        // time it changes — the engine handles fallback to system default
        // when the chosen UID isn't currently attached.
        settings.$preferredInputDeviceUID
            .receive(on: RunLoop.main)
            .sink { [weak self] uid in
                self?.audio.setPreferredInputUID(uid)
            }
            .store(in: &cancellables)
    }

    func applyHotkey() {
        guard let settings else { return }
        hotkey.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        pasteHotkey.register(
            keyCode: settings.pasteHotkeyKeyCode,
            modifiers: settings.pasteHotkeyModifiers
        )
        clearSubtitlesHotkey.register(
            keyCode: settings.clearSubtitlesHotkeyKeyCode,
            modifiers: settings.clearSubtitlesHotkeyModifiers
        )
    }

    /// Manual flush: type whatever the HUD is currently showing into the
    /// focused input, then clear it. Used when the user wants the buffer
    /// in the input without waiting for endpointing.
    private func flushBufferNow() {
        guard !interimText.isEmpty else { return }
        let buffer = interimText
        interimText = ""
        if settings?.showHUD == true {
            hud.update(text: "")
        }
        injector.type(formatChunk(buffer))
        injectedSomething = true
    }

    // MARK: Lifecycle

    private func start() {
        guard !isRecording, let settings else { return }
        Log.dictation.info("start requested — engine=\(settings.engineKind.rawValue, privacy: .public)")

        // If a previous session is still draining detach it now so its late
        // delegate callbacks can't inject into the new session.
        if let prior = engine {
            prior.delegate = nil
            prior.stop()
            engine = nil
            hud.hide()
        }

        if Permissions.microphoneStatus() != .authorized {
            status = .waitingForPermission("Microphone")
            Permissions.requestMicrophone { granted in
                if granted { /* user can press again */ }
            }
            return
        }
        guard Permissions.hasAccessibility() else {
            status = .waitingForPermission("Accessibility")
            Permissions.promptAccessibility()
            return
        }

        let language = settings.languageMode.resolved()

        // Resolve the per-app keyterm list once for every engine. Skip our own
        // bundle id — if Cheboo's Settings window happens to be frontmost when
        // the hotkey fires, fall through to the default list rather than
        // matching a rule the user accidentally added. Deepgram sends these as
        // `keyterm` params and gpt-transcribe as `keywords[]`; the Whisper
        // engines fold them into the decoder prompt (a comma-joined vocabulary
        // hint) since Whisper has no keyterm concept of its own.
        let ownBundleID = Bundle.main.bundleIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let focusedBundleID = (frontmost != ownBundleID) ? frontmost : nil
        let resolved = settings.keyterms(forBundleID: focusedBundleID)
        // Drop keyterms whose script doesn't match the transcription language
        // before building the Whisper decoder prompt — a cross-script prompt
        // makes Whisper return an empty transcript (see promptTerms). Deepgram
        // still gets the full list; its keyterm biasing simply ignores terms it
        // can't use rather than zeroing the output.
        let promptTerms = language.promptTerms(from: resolved.terms)
        Log.dictation.info(
            "keyterms resolved — app=\(focusedBundleID ?? "nil", privacy: .public) list=\(resolved.listName ?? "—", privacy: .public) count=\(resolved.terms.count) whisperPrompt=\(promptTerms.count)"
        )
        let whisperPrompt = promptTerms.joined(separator: ", ")

        let newEngine: TranscriptionEngine
        switch settings.engineKind {
        case .deepgram:
            guard !settings.apiKey.isEmpty else {
                status = .error("Set a Deepgram API key in Settings.")
                return
            }
            newEngine = DeepgramSocket(
                apiKey: settings.apiKey,
                model: language.deepgramModel,
                language: language.deepgramLanguage,
                punctuate: settings.autoPunctuation,
                smartFormat: settings.autoCapitalization,
                keyterms: resolved.terms
            )
        case .gptTranscribe:
            guard !settings.openAIAPIKey.isEmpty else {
                status = .error("Set an OpenAI API key in Settings → Engine.")
                return
            }
            newEngine = GPTTranscribeEngine(
                apiKey: settings.openAIAPIKey,
                languages: language.gptTranscribeLanguages,
                // Unfiltered, unlike the Whisper prompt: `keywords[]` are hints
                // the model drops when it doesn't hear them, so a Cyrillic term
                // sitting in an English list costs nothing. Filtering here would
                // throw away exactly the cross-script product names (brands,
                // library names) that keyterms exist to catch.
                keywords: resolved.terms
            )
        case .whisperServer:
            guard !settings.whisperServerURL.isEmpty else {
                status = .error("Set a Whisper server URL in Settings → Engine.")
                return
            }
            newEngine = WhisperServerEngine(
                baseURL: settings.whisperServerURL,
                apiKey: settings.whisperServerAPIKey,
                language: language.whisperLanguage,
                prompt: whisperPrompt
            )
        case .whisperLocal:
            newEngine = WhisperKitEngine(
                modelName: settings.whisperKitModel,
                language: language.whisperLanguage,
                streaming: settings.whisperKitStreaming,
                prompt: whisperPrompt
            )
        }

        injectedSomething = false
        interimText = ""
        status = .connecting

        newEngine.delegate = self
        newEngine.start()
        self.engine = newEngine

        datasetActiveForCurrentSession = settings.datasetCollectionEnabled
        if datasetActiveForCurrentSession {
            // Label the recorded session with the engine actually in use, so the
            // corpus metadata is accurate regardless of which backend ran.
            let datasetLanguage: String
            let datasetModel: String
            switch settings.engineKind {
            case .deepgram:
                datasetLanguage = language.deepgramLanguage
                datasetModel = language.deepgramModel
            case .gptTranscribe:
                // Empty hints mean the model auto-detects, which is the same
                // thing the Whisper engines label "auto".
                let hints = language.gptTranscribeLanguages
                datasetLanguage = hints.isEmpty ? "auto" : hints.joined(separator: ",")
                datasetModel = GPTTranscribeEngine.model
            case .whisperServer:
                datasetLanguage = language.whisperLanguage
                datasetModel = "whisper-1"
            case .whisperLocal:
                datasetLanguage = language.whisperLanguage
                datasetModel = settings.whisperKitModel
            }
            dataset.beginSession(
                engine: settings.engineKind.rawValue,
                language: datasetLanguage,
                model: datasetModel
            )
        }

        do {
            try audio.start()
            isRecording = true
            status = .recording
            hud.markSettingsApplied()
            if settings.showHUD {
                hud.setAnchor(settings.hudPosition == .below ? .below : .above)
                hud.show(text: "")
            }
            // Subtitle overlay reappears on its own when interim/final text
            // arrives — no need to show an empty band here.
        } catch {
            Log.dictation.error("audio start failed: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
            newEngine.stop()
            self.engine = nil
            cancelDatasetIfActive()
        }
    }

    private func stop() {
        guard isRecording else {
            // If we were mid-connect, tear it down anyway.
            engine?.stop()
            engine = nil
            cancelDatasetIfActive()
            return
        }
        Log.dictation.info("stop requested")
        audio.stop()
        isRecording = false
        let flushed = interimText
        interimText = ""
        status = .idle

        // Batch engines (Whisper server / on-device) deliver their authoritative
        // transcript as a single final *after* stop(); any interim shown while
        // recording is a lower-quality preview that's missing the last fraction
        // of a second of speech. We must wait for that final rather than
        // committing the interim. Streaming engines (Deepgram) finalize
        // incrementally, so by now the only un-typed text is the dangling
        // interim.
        let waitForFinal = engine?.finalizesAfterStop ?? false

        // Subtitle mode persists what was said until the user explicitly
        // clears it with the clear-subtitles hotkey, so we don't hide here.
        // For streaming engines, commit the dangling interim so the visible
        // text matches what was typed; for batch engines the post-stop final
        // supersedes the interim, so let didReceiveFinal commit it instead.
        if settings?.subtitleMode == true, !flushed.isEmpty, !waitForFinal {
            subtitles.commit(text: flushed)
        }

        if !flushed.isEmpty, !waitForFinal {
            // Streaming engine: we already see the transcript on screen — type
            // it and detach the engine so its post-stop final can't double-type.
            hud.hide()
            engine?.delegate = nil
            engine?.stop()
            engine = nil
            injector.type(formatChunk(flushed))
            injectedSomething = true
        } else {
            // Either nothing on screen yet, or a batch engine whose final is
            // still pending. Keep the delegate attached so the post-stop final
            // injects through didReceiveFinal. For batch engines show a
            // transcribing indicator so the wait isn't a blank screen.
            if waitForFinal, settings?.showHUD == true {
                hud.show(text: Self.transcribingPlaceholder)
            } else {
                hud.hide()
            }
            engine?.stop()
        }

        // Deepgram has already appended every final to the dataset during
        // recording, so finalize now. Batch engines deliver their final after
        // stop() — defer their dataset finalize to didReceiveFinal/didCloseWith
        // so the transcript isn't dropped (the session would otherwise close
        // before the transcript arrives).
        if !waitForFinal {
            finalizeDatasetIfActive()
        }
    }

    /// Persist the in-progress dataset session, if one is open. Idempotent —
    /// safe to call from whichever of stop()/didReceiveFinal/didCloseWith wins.
    private func finalizeDatasetIfActive() {
        guard datasetActiveForCurrentSession else { return }
        dataset.finalizeSession()
        datasetActiveForCurrentSession = false
    }

    /// Drop the in-progress dataset session without writing it.
    private func cancelDatasetIfActive() {
        guard datasetActiveForCurrentSession else { return }
        dataset.cancelSession()
        datasetActiveForCurrentSession = false
    }

    // MARK: Injection formatting

    /// Prepend a space if we've already typed something this utterance and the
    /// incoming chunk doesn't start with punctuation/whitespace. Also fix the
    /// frequent Deepgram quirk where the first letter after `", "` comes back
    /// capitalized mid-sentence — proper-noun detection is impractical, so we
    /// just lowercase and accept the occasional miscased name.
    private func formatChunk(_ chunk: String) -> String {
        let normalized = Self.lowercaseAfterComma(chunk)
        guard injectedSomething else { return normalized }
        if let first = normalized.first {
            if first.isWhitespace { return normalized }
            if ",.!?;:".contains(first) { return normalized }
        }
        return " " + normalized
    }

    /// Spoken-punctuation map. Each entry is a regex that swallows the word
    /// (plus any surrounding whitespace) and inserts the literal mark with
    /// one trailing space. Order matters — multi-word commands come before
    /// the single-word ones so e.g. "точка с запятой" wins over "запятая".
    /// We do this client-side instead of `dictation=true` on Deepgram because
    /// (a) Deepgram's dictation feature is English-only — "запятая" wouldn't
    /// be recognized — and (b) `dictation=true` requires `punctuate=true`,
    /// which would also re-enable prosody-based punctuation that the user
    /// explicitly opted out of.
    private static let commandPatterns: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            (#"\s*\bточка с запятой\b\s*"#, "; "),
            (#"\s*\bsemicolon\b\s*"#, "; "),
            (#"\s*\b(?:exclamation mark|exclamation point|восклицательный знак)\b\s*"#, "! "),
            (#"\s*\b(?:question mark|вопросительный знак)\b\s*"#, "? "),
            (#"\s*\b(?:new paragraph|новый абзац)\b\s*"#, "\n\n"),
            (#"\s*\b(?:new line|новая строка)\b\s*"#, "\n"),
            (#"\s*\b(?:comma|запятая)\b\s*"#, ", "),
            (#"\s*\b(?:period|точка)\b\s*"#, ". "),
            (#"\s*\b(?:colon|двоеточие)\b\s*"#, ": "),
            (#"\s*\b(?:dash|тире)\b\s*"#, " — "),
            (#"\s*\b(?:hyphen|дефис)\b\s*"#, "-"),
        ]
        return raw.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: replacement))
        }
    }()

    /// Replace spoken punctuation commands ("comma", "запятая", "question mark",
    /// "новая строка", …) with their literal marks. Idempotent — running it
    /// twice produces the same result, since the replacements don't themselves
    /// contain command words.
    static func substituteCommands(_ s: String) -> String {
        var result = s
        for (regex, template) in commandPatterns {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result
    }

    private static func lowercaseAfterComma(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #", (\p{Lu})"#) else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var result = s
        for match in matches.reversed() {
            let range = match.range(at: 1)
            let upper = (result as NSString).substring(with: range)
            let lower = upper.lowercased()
            result = (result as NSString).replacingCharacters(in: range, with: lower)
        }
        return result
    }
}

// MARK: - Audio delegate

extension DictationController: AudioEngineDelegate {
    func audioEngine(_ engine: AudioEngine, didCapture pcm: Data) {
        // Called from AudioEngine.callbackQueue; engine.send is thread-safe.
        self.engine?.send(pcm)
        // DatasetRecorder serializes appends on its own queue; a no-op when
        // no session is open, so it's safe to call unconditionally.
        dataset.appendPCM(pcm)
    }

    func audioEngine(_ engine: AudioEngine, didFailWith error: Error) {
        DispatchQueue.main.async { [weak self] in
            Log.dictation.error("audio engine failed: \(error.localizedDescription, privacy: .public)")
            self?.status = .error(error.localizedDescription)
            // Drop any audio captured during the doomed session — we don't
            // want half-utterances landing in the training corpus.
            self?.cancelDatasetIfActive()
            self?.stop()
        }
    }

    func audioEngineWantsRestartForDeviceChange(_ engine: AudioEngine) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            Log.dictation.info("restarting dictation session to switch input devices")
            self.restartSession()
        }
    }
}

// MARK: - Transcription engine delegate

extension DictationController: TranscriptionEngineDelegate {
    func engineDidOpen(_ engine: TranscriptionEngine) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.status = .recording
        }
    }

    func engine(_ engine: TranscriptionEngine, didReceiveInterim text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            let processed = Self.substituteCommands(text)
            self.interimText = processed
            if self.settings?.showHUD == true {
                self.hud.update(text: processed)
            }
            if self.settings?.subtitleMode == true {
                self.subtitles.setInterim(text: processed)
            }
        }
    }

    func engine(_ engine: TranscriptionEngine, didReceiveFinal text: String, speechFinal: Bool, words: [TranscriptWord]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let settings = self.settings else { return }

            let processed = Self.substituteCommands(text)

            // Store the recognizer's original (pre-command-substitution) text
            // alongside the audio — that's what the model actually produced,
            // and what we'd train against. Word timestamps come from Deepgram
            // and on-device WhisperKit; the HTTP Whisper server passes an empty
            // array.
            if self.datasetActiveForCurrentSession {
                self.dataset.appendFinal(text: text, speechFinal: speechFinal, words: words)
            }

            // Subtitle accumulation is independent of injection — we always
            // commit finals into the on-screen buffer when subtitle mode is
            // on, regardless of `injectOnFinal` or `speechFinal`.
            if settings.subtitleMode {
                self.subtitles.commit(text: processed)
            }

            // After tap-stop, isRecording is false but the engine may still
            // deliver one last final from its flush; type it anyway so
            // nothing's lost. injectOnFinal is only consulted while we're
            // actively recording.
            let postStop = !self.isRecording
            let shouldInject = postStop || settings.injectOnFinal || speechFinal
            guard shouldInject else { return }

            self.injector.type(self.formatChunk(processed))
            self.injectedSomething = true
            self.interimText = ""

            if postStop {
                self.engine?.delegate = nil
                self.engine?.stop()
                self.engine = nil
                // Clear the transcribing indicator and persist the dataset
                // session now that the final (with word timestamps) has landed.
                self.hud.hide()
                self.finalizeDatasetIfActive()
            } else if settings.showHUD {
                self.hud.update(text: "")
            }
        }
    }

    func engine(_ engine: TranscriptionEngine, didCloseWith error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.engine = nil
            // Always clear any transcribing indicator — whether the engine
            // produced a final, nothing, or an error.
            self.hud.hide()

            guard let error else {
                // Clean close. A batch engine that emitted no final (empty
                // transcript) still has an open dataset session; settle it here.
                self.finalizeDatasetIfActive()
                return
            }

            Log.dictation.error("engine closed with error: \(error.localizedDescription, privacy: .public)")
            // The session is gone; drop any half-recorded dataset audio rather
            // than pairing it with a transcript that never arrived.
            self.cancelDatasetIfActive()
            if self.isRecording {
                self.stop()
            }
            // Set after stop() so its `status = .idle` can't clobber the error.
            // Crucially this also surfaces *post-stop* failures (e.g. an
            // unreachable Whisper server), which happen when isRecording is
            // already false and would otherwise be swallowed silently.
            self.status = .error(error.localizedDescription)
        }
    }
}
