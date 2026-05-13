import Combine
import Foundation

/// Persisted user settings. All access from the main thread.
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let keyterms = "keyterms"
        static let languageMode = "languageMode"
        static let autoPunctuation = "autoPunctuation"
        static let autoCapitalization = "autoCapitalization"
        static let saveToHistory = "saveToHistory"
    }

    @Published var keyterms: [String] {
        didSet { UserDefaults.standard.set(keyterms, forKey: Keys.keyterms) }
    }

    @Published var languageMode: LanguageMode {
        didSet { UserDefaults.standard.set(languageMode.rawValue, forKey: Keys.languageMode) }
    }

    /// When false, Deepgram is asked not to auto-insert punctuation. The user
    /// dictates marks explicitly ("comma", "period").
    @Published var autoPunctuation: Bool {
        didSet { UserDefaults.standard.set(autoPunctuation, forKey: Keys.autoPunctuation) }
    }

    /// Enables Deepgram smart formatting, which also re-enables punctuation
    /// regardless of `autoPunctuation` — that coupling is on Deepgram's side.
    @Published var autoCapitalization: Bool {
        didSet { UserDefaults.standard.set(autoCapitalization, forKey: Keys.autoCapitalization) }
    }

    @Published var saveToHistory: Bool {
        didSet { UserDefaults.standard.set(saveToHistory, forKey: Keys.saveToHistory) }
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

    init() {
        let defaults = UserDefaults.standard
        self.keyterms = (defaults.array(forKey: Keys.keyterms) as? [String]) ?? Keyterms.defaults
        let storedLanguage = defaults.string(forKey: Keys.languageMode).flatMap(LanguageMode.init(rawValue:))
        self.languageMode = storedLanguage ?? .automatic
        self.autoPunctuation = defaults.object(forKey: Keys.autoPunctuation) as? Bool ?? true
        self.autoCapitalization = defaults.object(forKey: Keys.autoCapitalization) as? Bool ?? true
        self.saveToHistory = defaults.object(forKey: Keys.saveToHistory) as? Bool ?? true
        self.apiKey = Keychain.load() ?? ""
    }
}
