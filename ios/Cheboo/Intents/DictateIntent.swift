import AppIntents
import Foundation

/// Opens Cheboo and arms a dictation session. The intent itself only opens
/// the app — actual audio capture happens in the foreground because iOS
/// requires user-visible mic activity.
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription(
        "Opens Cheboo and immediately starts recording a transcript."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .cheboorequestStartDictation, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let cheboorequestStartDictation = Notification.Name("com.github.velet5.cheboo.startDictation")
}

struct ChebooShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start dictation in \(.applicationName)",
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}
