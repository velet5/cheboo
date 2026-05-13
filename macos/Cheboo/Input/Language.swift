import Carbon

enum DictationLanguage {
    case english
    /// Anything non-English. Deepgram nova-3 doesn't expose Russian as a
    /// single-language code yet, so we route every non-English layout through
    /// nova-3's multilingual mode which covers ru (and incidentally everything
    /// else nova-3 supports).
    case multilingual

    /// Deepgram model — nova-3 in both cases.
    var deepgramModel: String { "nova-3" }

    /// BCP-47 code Deepgram expects on the `language` query param.
    var deepgramLanguage: String {
        switch self {
        case .english: return "en"
        case .multilingual: return "multi"
        }
    }

    /// Two-letter code whisper.cpp expects in `whisper_full_params.language`.
    /// "auto" lets whisper detect the language itself, which is the right
    /// default for our multilingual bucket.
    var whisperLanguage: String {
        switch self {
        case .english: return "en"
        case .multilingual: return "auto"
        }
    }
}

enum LanguageMode: String, CaseIterable, Identifiable {
    case automatic
    case english
    case russian

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic (follow input source)"
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    /// Resolve to a concrete dictation language. For `.automatic`, peek at the
    /// current macOS keyboard input source: if it advertises English we use
    /// English; anything else falls through to multilingual.
    func resolved() -> DictationLanguage {
        switch self {
        case .english: return .english
        case .russian: return .multilingual
        case .automatic: return InputSourceLanguage.current()
        }
    }
}

enum InputSourceLanguage {
    static func current() -> DictationLanguage {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return .english }

        let langs = (Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]) ?? []
        if langs.first?.lowercased().hasPrefix("en") == true { return .english }
        return .multilingual
    }
}
