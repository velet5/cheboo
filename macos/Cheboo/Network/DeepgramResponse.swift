import Foundation

/// Subset of Deepgram's streaming response that we care about.
/// Reference: https://developers.deepgram.com/docs/streaming-listening
struct DeepgramResponse: Decodable {
    let type: String?
    let channel: Channel?
    let isFinal: Bool?
    let speechFinal: Bool?

    struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    struct Alternative: Decodable {
        let transcript: String
        let confidence: Double?
        let words: [Word]?
    }

    struct Word: Decodable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Double?
        /// Present when smart_format / punctuate produced a cased + punctuated
        /// surface form; prefer it over `word` when we have it because it's
        /// what actually ends up in the user-facing transcript.
        let punctuatedWord: String?

        enum CodingKeys: String, CodingKey {
            case word
            case start
            case end
            case confidence
            case punctuatedWord = "punctuated_word"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case channel
        case isFinal = "is_final"
        case speechFinal = "speech_final"
    }

    var firstTranscript: String? {
        let raw = channel?.alternatives.first?.transcript
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    var firstWords: [Word] {
        channel?.alternatives.first?.words ?? []
    }
}
