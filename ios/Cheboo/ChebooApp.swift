import SwiftData
import SwiftUI

@main
struct ChebooApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var dictation = DictationController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(dictation)
                .onAppear { dictation.bind(settings: settings) }
                .tint(.accentColor)
        }
        .modelContainer(for: Transcript.self)
    }
}
