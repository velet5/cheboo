import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var dictation: DictationController
    @StateObject private var inputDevices = InputDeviceMonitor.shared
    @ObservedObject private var whisperModels = WhisperKitModelManager.shared

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            engineTab.tabItem { Label("Engine", systemImage: "cpu") }
            keytermsTab.tabItem { Label("Keyterms", systemImage: "text.book.closed") }
            datasetTab.tabItem { Label("Dataset", systemImage: "waveform") }
            permissionsTab.tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .padding(20)
    }

    // MARK: Dataset

    private var datasetTab: some View {
        DatasetSettingsView(recorder: dictation.dataset)
            .environmentObject(settings)
    }

    // MARK: Engine

    private var engineTab: some View {
        Form {
            Section("Transcription engine") {
                Picker("Engine", selection: $settings.engineKind) {
                    ForEach(TranscriptionEngineKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Text(engineHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.engineKind == .deepgram {
                Section("Deepgram") {
                    SecureField("API Key", text: $settings.apiKey, prompt: Text("paste from console.deepgram.com"))
                        .textFieldStyle(.roundedBorder)
                    Text("Stored in the macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.engineKind == .whisperServer {
                Section("Whisper server") {
                    TextField("Base URL", text: $settings.whisperServerURL, prompt: Text("http://127.0.0.1:8080"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("API key (optional)", text: $settings.whisperServerAPIKey, prompt: Text("only for OpenAI cloud"))
                        .textFieldStyle(.roundedBorder)
                    Text("Point at any OpenAI-compatible /v1/audio/transcriptions endpoint. Run whisper.cpp's `server` example locally, or use faster-whisper-server / mlx-whisper-server. Leave the key empty for local servers; paste an OpenAI key to use api.openai.com instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.engineKind == .whisperLocal {
                Section("Whisper (on-device)") {
                    Picker("Model", selection: $settings.whisperKitModel) {
                        ForEach(WhisperKitModel.allCases) { model in
                            Text(model.label).tag(model.rawValue)
                        }
                    }
                    Picker("Recognition", selection: $settings.whisperKitStreaming) {
                        Text("Streaming (live interim text)").tag(true)
                        Text("One-pass (on release)").tag(false)
                    }
                    Text(settings.whisperKitStreaming
                        ? "Re-transcribes while you speak so text appears live. Uses more compute."
                        : "Transcribes once when you release the hotkey. Lower compute, no live text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(whisperModelStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(whisperModelBusy ? "Working…" : "Download / load") {
                            WhisperKitModelManager.shared.prewarm(modelName: settings.whisperKitModel)
                        }
                        .disabled(whisperModelBusy)
                    }
                    Text("Runs Whisper entirely on-device via Core ML on Apple Silicon — no network or API key. The selected model downloads once on first use and is cached locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Human-readable status for the on-device model, driven by the shared
    /// `WhisperKitModelManager` so the user can pre-download before dictating.
    private var whisperModelStatus: String {
        switch whisperModels.state {
        case .idle:
            return "Not loaded yet — downloads on first dictation."
        case .downloading(let fraction):
            return "Downloading… \(Int(fraction * 100))%"
        case .loading:
            return "Loading model…"
        case .ready(let model):
            // The manager caches one model at a time. If the user has since
            // picked a different one, the cached model no longer matches the
            // selection — report it as not-yet-loaded so the status doesn't
            // falsely claim the selected model is ready.
            guard model == settings.whisperKitModel else {
                return "Not loaded yet — downloads on first dictation."
            }
            return "Ready: \(model)"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    /// True while the shared manager is actively fetching or loading a model, so
    /// the Download button can be disabled to avoid stacking redundant loads.
    private var whisperModelBusy: Bool {
        switch whisperModels.state {
        case .downloading, .loading: return true
        default: return false
        }
    }

    private var engineHint: String {
        switch settings.engineKind {
        case .deepgram:
            return "Streams audio to Deepgram and shows interim text while you speak. Requires an API key (below) and a network connection."
        case .whisperServer:
            return "POSTs the full utterance to an OpenAI-compatible Whisper endpoint when you release the hotkey. No live interim text. Works against a local whisper.cpp server or OpenAI cloud."
        case .whisperLocal:
            return "Transcribes entirely on-device with Core ML on Apple Silicon — no network or API key. Streams live interim text or runs a single pass on release (see Recognition below). The selected model downloads once on first use."
        }
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("Microphone") {
                Picker("Input device", selection: micSelectionBinding) {
                    Text("System default").tag(String?.none)
                    if let uid = settings.preferredInputDeviceUID,
                       !inputDevices.devices.contains(where: { $0.uid == uid }) {
                        Text("\(savedDeviceLabel(uid)) (disconnected)").tag(String?.some(uid))
                    }
                    ForEach(inputDevices.devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Text(micHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hotkey") {
                HStack(spacing: 8) {
                    Toggle("⌘", isOn: modBinding(.command))
                    Toggle("⌥", isOn: modBinding(.option))
                    Toggle("⌃", isOn: modBinding(.control))
                    Toggle("⇧", isOn: modBinding(.shift))
                    Spacer()
                    Picker("", selection: $settings.hotkeyKeyCode) {
                        ForEach(KeyCode.pickable, id: \.code) { entry in
                            Text(entry.label).tag(entry.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                .toggleStyle(.button)
                .onChange(of: settings.hotkeyKeyCode) { _, _ in dictation.applyHotkey() }
                .onChange(of: settings.hotkeyModifiers) { _, _ in dictation.applyHotkey() }

                Text(hotkeyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paste hotkey") {
                HStack(spacing: 8) {
                    Toggle("⌘", isOn: pasteModBinding(.command))
                    Toggle("⌥", isOn: pasteModBinding(.option))
                    Toggle("⌃", isOn: pasteModBinding(.control))
                    Toggle("⇧", isOn: pasteModBinding(.shift))
                    Spacer()
                    Picker("", selection: $settings.pasteHotkeyKeyCode) {
                        Text("— None —").tag(UInt32(0))
                        ForEach(KeyCode.pickable, id: \.code) { entry in
                            Text(entry.label).tag(entry.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                .toggleStyle(.button)
                .onChange(of: settings.pasteHotkeyKeyCode) { _, _ in dictation.applyHotkey() }
                .onChange(of: settings.pasteHotkeyModifiers) { _, _ in dictation.applyHotkey() }

                Text("Press while dictating to immediately type whatever's in the HUD into the focused input. Useful when you don't want to wait for an endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Picker("Mode", selection: $settings.hotkeyBehavior) {
                    ForEach(HotkeyBehavior.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("Show interim transcript HUD near cursor", isOn: $settings.showHUD)
                Picker("HUD position", selection: $settings.hudPosition) {
                    ForEach(HUDPosition.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(!settings.showHUD)
                Text("Drag the HUD to override; it stays put until you change this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Inject on every interim final (snappier — recommended)", isOn: $settings.injectOnFinal)
            }

            Section("Language") {
                Picker("Recognize", selection: $settings.languageMode) {
                    ForEach(LanguageMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(languageHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Toggle("Auto-punctuation", isOn: $settings.autoPunctuation)
                Toggle("Auto-capitalization", isOn: $settings.autoCapitalization)
                Text("Off by default so you can dictate marks (\"comma\", \"period\") explicitly. Capitalization uses Deepgram smart formatting, which also re-enables punctuation regardless of the punctuation toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Subtitle mode") {
                Toggle("Show subtitles at the bottom of the screen", isOn: $settings.subtitleMode)
                ColorPicker("Main color", selection: subtitleColorBinding(\.subtitleMainColor), supportsOpacity: true)
                    .disabled(!settings.subtitleMode)
                ColorPicker("Outline color", selection: subtitleColorBinding(\.subtitleOutlineColor), supportsOpacity: true)
                    .disabled(!settings.subtitleMode)
                ColorPicker("Shadow color", selection: subtitleColorBinding(\.subtitleShadowColor), supportsOpacity: true)
                    .disabled(!settings.subtitleMode)
                Picker("Font", selection: $settings.subtitleFontFamily) {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .disabled(!settings.subtitleMode)
                HStack {
                    Text("Size")
                    Slider(value: $settings.subtitleFontSize, in: 16...96, step: 1)
                    Text("\(Int(settings.subtitleFontSize))")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .disabled(!settings.subtitleMode)
                Text("Captions wrap up to three lines and stay on screen until you press the clear hotkey. Designed for screencasts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clear subtitles hotkey") {
                HStack(spacing: 8) {
                    Toggle("⌘", isOn: clearModBinding(.command))
                    Toggle("⌥", isOn: clearModBinding(.option))
                    Toggle("⌃", isOn: clearModBinding(.control))
                    Toggle("⇧", isOn: clearModBinding(.shift))
                    Spacer()
                    Picker("", selection: $settings.clearSubtitlesHotkeyKeyCode) {
                        Text("— None —").tag(UInt32(0))
                        ForEach(KeyCode.pickable, id: \.code) { entry in
                            Text(entry.label).tag(entry.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                .toggleStyle(.button)
                .onChange(of: settings.clearSubtitlesHotkeyKeyCode) { _, _ in dictation.applyHotkey() }
                .onChange(of: settings.clearSubtitlesHotkeyModifiers) { _, _ in dictation.applyHotkey() }

                Text("Press to wipe the on-screen subtitle text and hide the band.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Bridge SwiftUI `Color` and the hex string we persist. Reading converts
    /// the stored hex back through `NSColor`; writing converts the picker's
    /// `Color` to sRGB hex with alpha. Falls back to white on parse failure
    /// (which only happens if the stored value got corrupted somehow).
    private func subtitleColorBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, String>) -> Binding<Color> {
        Binding(
            get: {
                let hex = settings[keyPath: keyPath]
                if let ns = NSColor(hexString: hex) { return Color(nsColor: ns) }
                return .white
            },
            set: { newColor in
                let ns = NSColor(newColor)
                settings[keyPath: keyPath] = ns.hexStringRGBA
            }
        )
    }

    private var languageHint: String {
        switch settings.languageMode {
        case .automatic:
            let name: String
            switch LanguageMode.automatic.resolved() {
            case .english: name = "English"
            case .russian: name = "Russian (Whisper pins ru; Deepgram falls back to multilingual)"
            case .multilingual: name = "Multilingual (auto-detect)"
            }
            return "Following your current input source: \(name). Re-checked each time you start dictating."
        case .english:
            return "Uses Deepgram nova-3, English only."
        case .russian:
            return "Pins Russian: Whisper transcribes as ru; Deepgram nova-3 falls back to multilingual mode (it has no single-language Russian code)."
        }
    }

    private var micHint: String {
        guard let uid = settings.preferredInputDeviceUID else {
            return "Follows whichever input macOS currently treats as default."
        }
        let attached = inputDevices.devices.contains(where: { $0.uid == uid })
        if attached {
            return "Cheboo records from this device. If it's disconnected mid-session, we fall back to the system default and switch back when it returns."
        }
        return "The chosen device isn't attached right now — Cheboo will use the system default until it reappears."
    }

    private var micSelectionBinding: Binding<String?> {
        Binding(
            get: { settings.preferredInputDeviceUID },
            set: { settings.preferredInputDeviceUID = $0 }
        )
    }

    private func savedDeviceLabel(_ uid: String) -> String {
        // Pure-UID strings aren't human-friendly. We don't have the name
        // cached past unplug, so surface a trimmed form of the UID instead.
        if let suffix = uid.split(separator: ":").last, !suffix.isEmpty {
            return String(suffix)
        }
        return uid
    }

    private var hotkeyHint: String {
        switch settings.hotkeyBehavior {
        case .pushToTalk:
            return "Hold the hotkey anywhere on macOS to dictate. Release to stop."
        case .toggle:
            return "Tap the hotkey to start dictating; tap again to stop and flush."
        }
    }

    private func modBinding(_ modifier: HotkeyModifier) -> Binding<Bool> {
        Binding(
            get: { settings.hotkeyModifiers & modifier.rawValue != 0 },
            set: { newValue in
                if newValue {
                    settings.hotkeyModifiers |= modifier.rawValue
                } else {
                    settings.hotkeyModifiers &= ~modifier.rawValue
                }
            }
        )
    }

    private func pasteModBinding(_ modifier: HotkeyModifier) -> Binding<Bool> {
        Binding(
            get: { settings.pasteHotkeyModifiers & modifier.rawValue != 0 },
            set: { newValue in
                if newValue {
                    settings.pasteHotkeyModifiers |= modifier.rawValue
                } else {
                    settings.pasteHotkeyModifiers &= ~modifier.rawValue
                }
            }
        )
    }

    private func clearModBinding(_ modifier: HotkeyModifier) -> Binding<Bool> {
        Binding(
            get: { settings.clearSubtitlesHotkeyModifiers & modifier.rawValue != 0 },
            set: { newValue in
                if newValue {
                    settings.clearSubtitlesHotkeyModifiers |= modifier.rawValue
                } else {
                    settings.clearSubtitlesHotkeyModifiers &= ~modifier.rawValue
                }
            }
        )
    }

    // MARK: Keyterms

    @State private var newTerm: String = ""
    @State private var newBundleID: String = ""
    @State private var editingListID: UUID?
    @State private var editingListName: String = ""

    private var keytermsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyterms bias Deepgram toward project- and shell-specific vocabulary. Assign apps to a list to auto-switch when that app is focused at dictation start; otherwise the default list below is used. Up to 100 terms per list are sent.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("Default list", selection: activeListBinding) {
                    Text("— None (no fallback) —").tag(UUID?.none)
                    ForEach(settings.keytermLists) { list in
                        Text(list.name).tag(UUID?.some(list.id))
                    }
                }
                .help("Used when the focused app doesn't match any list's app rules.")
                Button {
                    let new = KeytermList(name: uniqueListName("New list"), terms: [])
                    settings.keytermLists.append(new)
                    settings.selectedKeytermListID = new.id
                    editingListID = new.id
                    editingListName = new.name
                } label: {
                    Label("New list", systemImage: "plus")
                }
            }

            if let activeID = settings.selectedKeytermListID,
               let list = settings.keytermLists.first(where: { $0.id == activeID }) {
                activeListEditor(list)
            } else {
                Text("No default list selected. Cheboo will only send keyterms when the focused app matches a list's app rules. Pick a list above to set a default, or create a new one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private var activeListBinding: Binding<UUID?> {
        Binding(
            get: { settings.selectedKeytermListID },
            set: { newValue in
                settings.selectedKeytermListID = newValue
                // Switching away cancels any in-progress rename for the
                // previously-active list so the editor doesn't reappear
                // pre-armed when the user comes back.
                if editingListID != newValue {
                    editingListID = nil
                    editingListName = ""
                }
            }
        )
    }

    @ViewBuilder
    private func activeListEditor(_ list: KeytermList) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if editingListID == list.id {
                    TextField("Name", text: $editingListName, onCommit: {
                        commitListRename(for: list.id)
                    })
                    .textFieldStyle(.roundedBorder)
                    Button("Done") { commitListRename(for: list.id) }
                } else {
                    Text(list.name).font(.headline)
                    Spacer()
                    Button {
                        editingListID = list.id
                        editingListName = list.name
                    } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename list")
                    Button {
                        if let idx = settings.keytermLists.firstIndex(where: { $0.id == list.id }) {
                            let copy = KeytermList(name: uniqueListName(list.name + " copy"), terms: list.terms)
                            settings.keytermLists.insert(copy, at: idx + 1)
                            settings.selectedKeytermListID = copy.id
                        }
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Duplicate list")
                    Button {
                        settings.keytermLists.removeAll { $0.id == list.id }
                        settings.selectedKeytermListID = nil
                        editingListID = nil
                        editingListName = ""
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete list")
                }
            }

            appRulesEditor(for: list)

            HStack {
                TextField("Add term…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTerm(to: list.id) }
                Button("Add") { addTerm(to: list.id) }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Seed defaults") {
                    if let idx = settings.keytermLists.firstIndex(where: { $0.id == list.id }) {
                        let merged = mergePreservingOrder(settings.keytermLists[idx].terms, Keyterms.defaultTerms)
                        settings.keytermLists[idx].terms = merged
                    }
                }
            }

            List {
                ForEach(list.terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            if let idx = settings.keytermLists.firstIndex(where: { $0.id == list.id }) {
                                settings.keytermLists[idx].terms.removeAll { $0 == term }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 240)
        }
    }

    // MARK: App rules (per-list)

    @ViewBuilder
    private func appRulesEditor(for list: KeytermList) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Apply automatically to")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    let assigned = Set(list.bundleIDs)
                    let candidates = Self.runningRegularApps().filter { !assigned.contains($0.bundleID) }
                    if candidates.isEmpty {
                        Text("No other running apps")
                    } else {
                        ForEach(candidates, id: \.bundleID) { app in
                            Button(app.name) { addBundleID(app.bundleID, to: list.id) }
                        }
                    }
                } label: {
                    Label("Add running app", systemImage: "plus")
                }
                .fixedSize()
            }

            if list.bundleIDs.isEmpty {
                Text("No apps assigned. This list is only used when picked as the default.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list.bundleIDs, id: \.self) { bid in
                        let ref = Self.appRef(forBundleID: bid)
                        HStack(spacing: 6) {
                            if let icon = ref.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app.dashed")
                                    .frame(width: 16, height: 16)
                                    .foregroundStyle(.secondary)
                            }
                            Text(ref.name)
                            Text(bid)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                removeBundleID(bid, from: list.id)
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            HStack {
                TextField("Bundle ID (e.g. com.mitchellh.ghostty)", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitCustomBundleID(to: list.id) }
                Button("Add") { commitCustomBundleID(to: list.id) }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func addBundleID(_ id: String, to listID: UUID) {
        guard let idx = settings.keytermLists.firstIndex(where: { $0.id == listID }) else { return }
        if !settings.keytermLists[idx].bundleIDs.contains(id) {
            settings.keytermLists[idx].bundleIDs.append(id)
        }
    }

    private func removeBundleID(_ id: String, from listID: UUID) {
        guard let idx = settings.keytermLists.firstIndex(where: { $0.id == listID }) else { return }
        settings.keytermLists[idx].bundleIDs.removeAll { $0 == id }
    }

    private func commitCustomBundleID(to listID: UUID) {
        let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        addBundleID(trimmed, to: listID)
        newBundleID = ""
    }

    private static func runningRegularApps() -> [(bundleID: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let id = app.bundleIdentifier, id != own else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look up a display name + icon for an arbitrary bundle id, including
    /// apps that aren't currently running. Falls back to the raw id when the
    /// app isn't installed.
    private static func appRef(forBundleID id: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return (id, nil)
        }
        let bundle = Bundle(url: url)
        let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return (name, icon)
    }

    private func commitListRename(for id: UUID) {
        defer { editingListID = nil; editingListName = "" }
        guard let idx = settings.keytermLists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = editingListName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.keytermLists[idx].name = trimmed
    }

    private func addTerm(to listID: UUID) {
        let trimmed = newTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let idx = settings.keytermLists.firstIndex(where: { $0.id == listID }) else { return }
        if !settings.keytermLists[idx].terms.contains(trimmed) {
            settings.keytermLists[idx].terms.append(trimmed)
        }
        newTerm = ""
    }

    private func uniqueListName(_ base: String) -> String {
        let existing = Set(settings.keytermLists.map { $0.name })
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    private func mergePreservingOrder(_ existing: [String], _ additions: [String]) -> [String] {
        var seen = Set(existing)
        var merged = existing
        for term in additions where !seen.contains(term) {
            merged.append(term)
            seen.insert(term)
        }
        return merged
    }

    // MARK: Permissions (continued below; DatasetSettingsView lives at file scope)
}

private struct DatasetSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var recorder: DatasetRecorder

    var body: some View {
        Form {
            Section("Speech dataset") {
                Toggle(
                    "Save audio + transcript for each dictation session",
                    isOn: $settings.datasetCollectionEnabled
                )
                Text("Stores the raw 16 kHz mono audio your microphone produced together with the recognizer's finalized transcript. Deepgram word-level timestamps are saved alongside the text when available. Use this to build a personal corpus for fine-tuning a speech model on your own voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Statistics") {
                LabeledContent("Sessions") {
                    Text("\(recorder.stats.sessionCount)")
                        .monospacedDigit()
                }
                LabeledContent("Audio recorded") {
                    Text(DatasetSettingsView.formatDuration(recorder.stats.totalAudioSeconds))
                        .monospacedDigit()
                }
                LabeledContent("Words recognized") {
                    Text("\(recorder.stats.totalWords)")
                        .monospacedDigit()
                }
            }

            Section("Location") {
                Text(recorder.baseDirectory.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reveal in Finder") {
                        let url = recorder.sessionsDirectory
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Compact human-friendly duration. Sub-minute durations stay in seconds
    /// (helpful when you've just started collecting); longer ones promote to
    /// minutes / hours so the stat fits on one line.
    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

extension SettingsView {
    // MARK: Permissions

    private var permissionsTab: some View {
        Form {
            permissionRow(
                title: "Microphone",
                description: "Required to capture audio while the hotkey is held.",
                granted: Permissions.microphoneStatus() == .authorized,
                action: { Permissions.requestMicrophone { _ in } },
                openSettings: Permissions.openMicrophoneSettings
            )
            permissionRow(
                title: "Accessibility",
                description: "Required for CGEventPost to inject keystrokes into other apps.",
                granted: Permissions.hasAccessibility(),
                action: { Permissions.promptAccessibility() },
                openSettings: Permissions.openAccessibilitySettings
            )
            permissionRow(
                title: "Input Monitoring",
                description: "Required so the global hotkey works while another app is focused.",
                granted: Permissions.hasInputMonitoring(),
                action: { Permissions.requestInputMonitoring() },
                openSettings: Permissions.openInputMonitoringSettings
            )
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(granted ? Color.green : Color.orange)
                    Text(title).bold()
                    Spacer()
                    if granted {
                        Text("Granted").foregroundStyle(.secondary)
                    } else {
                        Button("Request", action: action)
                        Button("Open Settings", action: openSettings)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
