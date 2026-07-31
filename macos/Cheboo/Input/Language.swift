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

    /// Language hints for OpenAI's `gpt-transcribe`, sent as repeated
    /// `languages[]` form fields. Unlike Whisper's singular `language` this is a
    /// *list* of languages the audio may contain, so the multilingual bucket
    /// sends an empty one: the API rejects a literal "auto", and omitting the
    /// field entirely is how detection is requested.
    var gptTranscribeLanguages: [String] {
        switch self {
        case .english: return ["en"]
        case .russian: return ["ru"]
        case .multilingual: return []
        }
    }
}

extension DictationLanguage {
    /// Keep only keyterms whose script matches this language's, before they're
    /// folded into a Whisper decoder prompt. A prompt in a different script than
    /// the audio (e.g. Cyrillic keyterms while transcribing English under the
    /// `<|en|>` token) conflicts with the language token and can make Whisper
    /// return an *empty* transcript, so cross-script terms are dropped rather
    /// than allowed to poison the decode.
    ///
    /// A term is dropped only if it contains a letter from a *different*
    /// alphabet — same-script terms and script-neutral ones (digits, acronyms
    /// like "R2", punctuation) are always kept. `.multilingual` auto-detects the
    /// language, so the target script is unknown ahead of time and every term is
    /// kept.
    func promptTerms(from terms: [String]) -> [String] {
        guard let target = promptScript else { return terms }
        return terms.filter { term in
            !term.unicodeScalars.contains { scalar in
                guard let script = Self.script(of: scalar) else { return false }
                return script != target
            }
        }
    }

    private enum Script { case latin, cyrillic }

    private var promptScript: Script? {
        switch self {
        case .english: return .latin
        case .russian: return .cyrillic
        case .multilingual: return nil
        }
    }

    /// Latin vs Cyrillic for letters in the ranges keyterms realistically use;
    /// `nil` for digits, punctuation, and other scripts (which never conflict).
    /// The `isAlphabetic` guard on the Latin range skips the two math symbols
    /// (×, ÷) that share the Latin-1 Supplement block.
    private static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x0400...0x052F:                                  // Cyrillic + Supplement
            return .cyrillic
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: // Latin + Latin-1/Extended
            return scalar.properties.isAlphabetic ? .latin : nil
        default:
            return nil
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
    /// current macOS keyboard input source: an English layout pins English, a
    /// Russian layout pins Russian, and anything else falls through to
    /// multilingual auto-detect.
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
        let primary = langs.first?.lowercased() ?? ""
        // Pin the layouts Whisper has a concrete code for; everything else
        // falls through to the multilingual auto-detect bucket.
        if primary.hasPrefix("en") { return .english }
        if primary.hasPrefix("ru") { return .russian }
        return .multilingual
    }
}
