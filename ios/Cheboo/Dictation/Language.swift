import Foundation

enum DictationLanguage {
    case english
    /// Anything non-English. Nova-3 doesn't expose every BCP-47 code as a
    /// single-language model yet, so non-English routes through nova-3's
    /// multilingual mode which covers ru and the rest of nova-3's languages.
    case multilingual

    var deepgramModel: String { "nova-3" }

    var deepgramLanguage: String {
        switch self {
        case .english: return "en"
        case .multilingual: return "multi"
        }
    }
}

enum LanguageMode: String, CaseIterable, Identifiable, Codable {
    case automatic
    case english
    case russian

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic (device language)"
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    /// Resolve to a concrete dictation language. `.automatic` peeks at the
    /// device locale: English → English, anything else → multilingual.
    func resolved() -> DictationLanguage {
        switch self {
        case .english: return .english
        case .russian: return .multilingual
        case .automatic:
            let lang = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"
            return lang.hasPrefix("en") ? .english : .multilingual
        }
    }
}
