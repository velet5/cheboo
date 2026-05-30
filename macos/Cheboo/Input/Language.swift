import Carbon

enum DictationLanguage {
    case english
    /// Explicitly Russian. Whisper accepts "ru" as a language code, so when the
    /// user pins Russian we forward it rather than paying for auto-detection.
    /// Deepgram nova-3 still has no single-language ru code, so it falls back to
    /// multilingual (see `deepgramLanguage`).
    case russian
    /// Anything non-English we can't pin to a concrete code — e.g. a non-English
    /// keyboard layout under Automatic. Deepgram nova-3's multilingual mode
    /// covers ru (and everything else it supports); Whisper auto-detects.
    case multilingual

    /// Deepgram model — nova-3 in every case.
    var deepgramModel: String { "nova-3" }

    /// BCP-47 code Deepgram expects on the `language` query param. nova-3
    /// doesn't expose Russian as a single-language code yet, so Russian routes
    /// through multilingual mode alongside the rest of the non-English bucket.
    var deepgramLanguage: String {
        switch self {
        case .english: return "en"
        case .russian, .multilingual: return "multi"
        }
    }

    /// Two-letter code Whisper expects (`whisper_full_params.language` for
    /// whisper.cpp, the `language` form field for the OpenAI-compatible API).
    /// Whisper supports "ru" directly, so an explicit Russian selection pins it.
    /// "auto" lets Whisper detect the language itself, the right default for the
    /// open-ended multilingual bucket.
    var whisperLanguage: String {
        switch self {
        case .english: return "en"
        case .russian: return "ru"
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
        case .russian: return .russian
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
