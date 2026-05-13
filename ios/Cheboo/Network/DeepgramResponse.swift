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
}
