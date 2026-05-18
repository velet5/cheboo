import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var dictation: DictationController
    @StateObject private var inputDevices = InputDeviceMonitor.shared

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            engineTab.tabItem { Label("Engine", systemImage: "cpu") }
            keytermsTab.tabItem { Label("Keyterms", systemImage: "text.book.closed") }
            permissionsTab.tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .padding(20)
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
        }
        .formStyle(.grouped)
    }

    private var engineHint: String {
        switch settings.engineKind {
        case .deepgram:
            return "Streams audio to Deepgram and shows interim text while you speak. Requires an API key (below) and a network connection."
        case .whisperServer:
            return "POSTs the full utterance to an OpenAI-compatible Whisper endpoint when you release the hotkey. No live interim text. Works against a local whisper.cpp server or OpenAI cloud."
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
            let current = LanguageMode.automatic.resolved()
            let name = current == .english ? "English (nova-3)" : "Multilingual (nova-3)"
            return "Following your current input source: \(name). Re-checked each time you start dictating."
        case .english:
            return "Uses Deepgram nova-3, English only."
        case .russian:
            return "Uses Deepgram nova-3 multilingual (covers Russian and other non-English languages nova-3 supports)."
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
    @State private var editingListID: UUID?
    @State private var editingListName: String = ""

    private var keytermsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyterms bias Deepgram toward project- and shell-specific vocabulary. Keep separate lists per project; pick one (or none) to send at connect time. Up to 100 terms per list are sent.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("Active list", selection: activeListBinding) {
                    Text("— None (no keyterms) —").tag(UUID?.none)
                    ForEach(settings.keytermLists) { list in
                        Text(list.name).tag(UUID?.some(list.id))
                    }
                }
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
                Text("No list selected — Cheboo won't send any keyterms when dictating. Pick a list above to edit it, or create a new one.")
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
