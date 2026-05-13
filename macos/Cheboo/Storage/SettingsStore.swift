import Carbon.HIToolbox
import Combine
import Foundation

enum HotkeyBehavior: String, CaseIterable, Identifiable {
    case pushToTalk
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pushToTalk: return "Push to talk (hold)"
        case .toggle: return "Toggle (tap to start, tap to stop)"
        }
    }
}

enum HUDPosition: String, CaseIterable, Identifiable {
    case above
    case below

    var id: String { rawValue }

    var label: String {
        switch self {
        case .above: return "Above cursor"
        case .below: return "Below cursor"
        }
    }
}

/// Which speech-to-text backend the dictation pipeline should drive.
enum TranscriptionEngineKind: String, CaseIterable, Identifiable {
    case deepgram
    case whisperServer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deepgram: return "Deepgram (cloud, streaming)"
        case .whisperServer: return "Whisper API (OpenAI-compatible, batch)"
        }
    }
}

/// Persisted user settings. All access happens on the main thread by
/// convention — SwiftUI views and `DictationController`'s main-queue
/// callbacks. Not annotated `@MainActor` so it can be stored on
/// non-isolated owners.
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        // Legacy single-list keyterms — read once at boot for migration into
        // `keytermLists`, then never written again.
        static let keytermsLegacy = "keyterms"
        static let keytermLists = "keytermLists"
        static let selectedKeytermListID = "selectedKeytermListID"
        static let showHUD = "showHUD"
        static let injectOnFinal = "injectOnFinal"
        static let hotkeyBehavior = "hotkeyBehavior"
        static let languageMode = "languageMode"
        static let hudPosition = "hudPosition"
        static let pasteHotkeyKeyCode = "pasteHotkeyKeyCode"
        static let pasteHotkeyModifiers = "pasteHotkeyModifiers"
        static let autoPunctuation = "autoPunctuation"
        static let autoCapitalization = "autoCapitalization"
        static let subtitleMode = "subtitleMode"
        static let subtitleMainColor = "subtitleMainColor"
        static let subtitleOutlineColor = "subtitleOutlineColor"
        static let subtitleShadowColor = "subtitleShadowColor"
        static let subtitleFontFamily = "subtitleFontFamily"
        static let subtitleFontSize = "subtitleFontSize"
        static let clearSubtitlesHotkeyKeyCode = "clearSubtitlesHotkeyKeyCode"
        static let clearSubtitlesHotkeyModifiers = "clearSubtitlesHotkeyModifiers"
        static let engineKind = "engineKind"
        static let whisperServerURL = "whisperServerURL"
        static let whisperServerAPIKey = "whisperServerAPIKey"
    }

    enum WhisperServerDefaults {
        /// whisper.cpp's `server` example binds to :8080 by default. Keep the
        /// scheme explicit so the URL is unambiguous when we tack the OpenAI
        /// route on top.
        static let url = "http://127.0.0.1:8080"
    }

    enum SubtitleDefaults {
        static let mainColor = "#FFFFFFFF"
        static let outlineColor = "#000000FF"
        static let shadowColor = "#000000B3"
        static let fontFamily = "Helvetica Neue"
        static let fontSize: Double = 38
    }

    @Published var hotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode) }
    }

    @Published var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers) }
    }

    /// All keyterm lists known to the user. Stored as JSON in UserDefaults.
    @Published var keytermLists: [KeytermList] {
        didSet { Self.persistKeytermLists(keytermLists) }
    }

    /// `nil` means "don't send any keyterms" — Deepgram stays on its cheaper
    /// per-minute tier when no `keyterm=` params are on the URL.
    @Published var selectedKeytermListID: UUID? {
        didSet {
            if let id = selectedKeytermListID {
                UserDefaults.standard.set(id.uuidString, forKey: Keys.selectedKeytermListID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedKeytermListID)
            }
        }
    }

    @Published var showHUD: Bool {
        didSet { UserDefaults.standard.set(showHUD, forKey: Keys.showHUD) }
    }

    /// If true, inject on every `is_final: true` event (snappier).
    /// If false, wait for `speech_final: true` (cleaner punctuation).
    @Published var injectOnFinal: Bool {
        didSet { UserDefaults.standard.set(injectOnFinal, forKey: Keys.injectOnFinal) }
    }

    @Published var hotkeyBehavior: HotkeyBehavior {
        didSet { UserDefaults.standard.set(hotkeyBehavior.rawValue, forKey: Keys.hotkeyBehavior) }
    }

    @Published var languageMode: LanguageMode {
        didSet { UserDefaults.standard.set(languageMode.rawValue, forKey: Keys.languageMode) }
    }

    @Published var hudPosition: HUDPosition {
        didSet { UserDefaults.standard.set(hudPosition.rawValue, forKey: Keys.hudPosition) }
    }

    /// 0 means the paste hotkey is unbound.
    @Published var pasteHotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(pasteHotkeyKeyCode), forKey: Keys.pasteHotkeyKeyCode) }
    }

    @Published var pasteHotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(pasteHotkeyModifiers), forKey: Keys.pasteHotkeyModifiers) }
    }

    /// When false, Deepgram is asked not to auto-insert punctuation. The user
    /// dictates marks explicitly ("comma", "period").
    @Published var autoPunctuation: Bool {
        didSet { UserDefaults.standard.set(autoPunctuation, forKey: Keys.autoPunctuation) }
    }

    /// When false, transcripts come back lowercase. Enabling it turns on
    /// Deepgram smart formatting, which also re-enables punctuation regardless
    /// of `autoPunctuation` — that coupling is on Deepgram's side.
    @Published var autoCapitalization: Bool {
        didSet { UserDefaults.standard.set(autoCapitalization, forKey: Keys.autoCapitalization) }
    }

    /// When true, dictation text is rendered as a subtitle strip at the bottom
    /// of the screen — designed for screencasts. Independent of the HUD.
    @Published var subtitleMode: Bool {
        didSet { UserDefaults.standard.set(subtitleMode, forKey: Keys.subtitleMode) }
    }

    /// Subtitle text color, stored as "#RRGGBBAA".
    @Published var subtitleMainColor: String {
        didSet { UserDefaults.standard.set(subtitleMainColor, forKey: Keys.subtitleMainColor) }
    }

    /// Subtitle outline (stroke) color, stored as "#RRGGBBAA".
    @Published var subtitleOutlineColor: String {
        didSet { UserDefaults.standard.set(subtitleOutlineColor, forKey: Keys.subtitleOutlineColor) }
    }

    /// Subtitle drop-shadow color, stored as "#RRGGBBAA".
    @Published var subtitleShadowColor: String {
        didSet { UserDefaults.standard.set(subtitleShadowColor, forKey: Keys.subtitleShadowColor) }
    }

    @Published var subtitleFontFamily: String {
        didSet { UserDefaults.standard.set(subtitleFontFamily, forKey: Keys.subtitleFontFamily) }
    }

    @Published var subtitleFontSize: Double {
        didSet { UserDefaults.standard.set(subtitleFontSize, forKey: Keys.subtitleFontSize) }
    }

    /// 0 means the clear-subtitles hotkey is unbound. Pressing this hotkey
    /// wipes the on-screen subtitle buffer and hides the overlay.
    @Published var clearSubtitlesHotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(clearSubtitlesHotkeyKeyCode), forKey: Keys.clearSubtitlesHotkeyKeyCode) }
    }

    @Published var clearSubtitlesHotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(clearSubtitlesHotkeyModifiers), forKey: Keys.clearSubtitlesHotkeyModifiers) }
    }

    @Published var engineKind: TranscriptionEngineKind {
        didSet { UserDefaults.standard.set(engineKind.rawValue, forKey: Keys.engineKind) }
    }

    /// Base URL of an OpenAI-compatible Whisper transcription endpoint. The
    /// engine accepts either a bare origin (e.g. `http://127.0.0.1:8080`) and
    /// appends `/v1/audio/transcriptions` itself, or a full URL the user has
    /// pasted verbatim.
    @Published var whisperServerURL: String {
        didSet { UserDefaults.standard.set(whisperServerURL, forKey: Keys.whisperServerURL) }
    }

    /// Optional Bearer token for the Whisper endpoint. Local whisper.cpp
    /// servers ignore it; OpenAI cloud requires it. Empty = no Authorization
    /// header sent.
    @Published var whisperServerAPIKey: String {
        didSet { UserDefaults.standard.set(whisperServerAPIKey, forKey: Keys.whisperServerAPIKey) }
    }

    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                Keychain.delete()
            } else if apiKey != oldValue {
                Keychain.save(apiKey)
            }
        }
    }

    /// Resolve the keyterms to actually pass to Deepgram. `nil` selection or
    /// an unknown id collapses to an empty array — Deepgram then stays on its
    /// cheaper non-keyterm pricing tier.
    var activeKeyterms: [String] {
        guard let id = selectedKeytermListID,
              let list = keytermLists.first(where: { $0.id == id })
        else { return [] }
        return list.terms
    }

    init() {
        let defaults = UserDefaults.standard

        let storedKey = defaults.object(forKey: Keys.hotkeyKeyCode) as? Int
        self.hotkeyKeyCode = UInt32(storedKey ?? kVK_Space)

        let storedMods = defaults.object(forKey: Keys.hotkeyModifiers) as? Int
        self.hotkeyModifiers = UInt32(storedMods ?? optionKey)

        let (lists, selectedID) = Self.loadKeytermState(defaults: defaults)
        self.keytermLists = lists
        self.selectedKeytermListID = selectedID

        self.showHUD = defaults.object(forKey: Keys.showHUD) as? Bool ?? true
        self.injectOnFinal = defaults.object(forKey: Keys.injectOnFinal) as? Bool ?? true
        let storedBehavior = defaults.string(forKey: Keys.hotkeyBehavior).flatMap(HotkeyBehavior.init(rawValue:))
        self.hotkeyBehavior = storedBehavior ?? .pushToTalk
        let storedLanguage = defaults.string(forKey: Keys.languageMode).flatMap(LanguageMode.init(rawValue:))
        self.languageMode = storedLanguage ?? .automatic
        let storedHudPosition = defaults.string(forKey: Keys.hudPosition).flatMap(HUDPosition.init(rawValue:))
        self.hudPosition = storedHudPosition ?? .above
        let storedPasteKey = defaults.object(forKey: Keys.pasteHotkeyKeyCode) as? Int
        self.pasteHotkeyKeyCode = UInt32(storedPasteKey ?? 0)
        let storedPasteMods = defaults.object(forKey: Keys.pasteHotkeyModifiers) as? Int
        self.pasteHotkeyModifiers = UInt32(storedPasteMods ?? 0)
        self.autoPunctuation = defaults.object(forKey: Keys.autoPunctuation) as? Bool ?? false
        self.autoCapitalization = defaults.object(forKey: Keys.autoCapitalization) as? Bool ?? false
        self.subtitleMode = defaults.object(forKey: Keys.subtitleMode) as? Bool ?? false
        self.subtitleMainColor = defaults.string(forKey: Keys.subtitleMainColor) ?? SubtitleDefaults.mainColor
        self.subtitleOutlineColor = defaults.string(forKey: Keys.subtitleOutlineColor) ?? SubtitleDefaults.outlineColor
        self.subtitleShadowColor = defaults.string(forKey: Keys.subtitleShadowColor) ?? SubtitleDefaults.shadowColor
        self.subtitleFontFamily = defaults.string(forKey: Keys.subtitleFontFamily) ?? SubtitleDefaults.fontFamily
        self.subtitleFontSize = defaults.object(forKey: Keys.subtitleFontSize) as? Double ?? SubtitleDefaults.fontSize
        let storedClearKey = defaults.object(forKey: Keys.clearSubtitlesHotkeyKeyCode) as? Int
        self.clearSubtitlesHotkeyKeyCode = UInt32(storedClearKey ?? 0)
        let storedClearMods = defaults.object(forKey: Keys.clearSubtitlesHotkeyModifiers) as? Int
        self.clearSubtitlesHotkeyModifiers = UInt32(storedClearMods ?? 0)
        let storedEngine = defaults.string(forKey: Keys.engineKind).flatMap(TranscriptionEngineKind.init(rawValue:))
        self.engineKind = storedEngine ?? .deepgram
        self.whisperServerURL = defaults.string(forKey: Keys.whisperServerURL) ?? WhisperServerDefaults.url
        self.whisperServerAPIKey = defaults.string(forKey: Keys.whisperServerAPIKey) ?? ""
        self.apiKey = Keychain.load() ?? ""
    }

    // MARK: - Keyterm list persistence

    /// Migrate the old flat `[String]` shape into the new lists shape on first
    /// launch, and otherwise decode the JSON-encoded list array. Returns the
    /// list array plus the currently selected id (validated against the loaded
    /// lists).
    private static func loadKeytermState(defaults: UserDefaults) -> ([KeytermList], UUID?) {
        if let data = defaults.data(forKey: Keys.keytermLists),
           let decoded = try? JSONDecoder().decode([KeytermList].self, from: data) {
            let selected = (defaults.string(forKey: Keys.selectedKeytermListID))
                .flatMap(UUID.init(uuidString:))
            let validated = selected.flatMap { id in
                decoded.contains(where: { $0.id == id }) ? id : nil
            }
            return (decoded, validated)
        }

        // First boot in the new shape — migrate the legacy flat list into a
        // single "Default" list if the user already had terms. Auto-select it
        // so behavior is preserved across the upgrade.
        if let legacy = defaults.array(forKey: Keys.keytermsLegacy) as? [String], !legacy.isEmpty {
            let migrated = KeytermList(name: "Default", terms: legacy)
            persistKeytermLists([migrated])
            defaults.set(migrated.id.uuidString, forKey: Keys.selectedKeytermListID)
            return ([migrated], migrated.id)
        }

        // Brand-new install — seed the bundled default list but leave the
        // selection unset, matching the new "no list = no keyterms" semantics.
        let seed = Keyterms.defaultList()
        persistKeytermLists([seed])
        return ([seed], nil)
    }

    private static func persistKeytermLists(_ lists: [KeytermList]) {
        guard let data = try? JSONEncoder().encode(lists) else {
            Log.settings.error("failed to encode keytermLists for persistence")
            return
        }
        UserDefaults.standard.set(data, forKey: Keys.keytermLists)
    }
}
