import SwiftUI

@main
struct ChebooApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var dictation = DictationController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(settings)
                .environmentObject(dictation)
                .onAppear { dictation.bind(settings: settings) }
        } label: {
            Label {
                Text("Cheboo")
            } icon: {
                if dictation.isRecording {
                    Image(systemName: "waveform")
                } else {
                    Image("IconTemplate")
                }
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(dictation)
                .frame(width: 520)
        }
    }
}
