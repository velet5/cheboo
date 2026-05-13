import Foundation
import SwiftData

@Model
final class Transcript {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var text: String
    var durationSeconds: Double

    init(text: String, durationSeconds: Double, createdAt: Date = .now) {
        self.id = UUID()
        self.createdAt = createdAt
        self.text = text
        self.durationSeconds = durationSeconds
    }

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 140 { return trimmed }
        return String(trimmed.prefix(140)) + "…"
    }
}
