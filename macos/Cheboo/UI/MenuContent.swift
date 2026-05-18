import AppKit
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Text("Cheboo — \(dictation.status.label)")

        if let warning = engineWarning {
            Text(warning)
        } else {
            Text("Hotkey: \(settings.hotkeyModifiers.hotkeyModifierString)\(KeyCode.label(for: settings.hotkeyKeyCode))")
        }

        Divider()

        Toggle("Auto-capitalization", isOn: $settings.autoCapitalization)
        Toggle("Auto-punctuation", isOn: $settings.autoPunctuation)
        Toggle("Subtitle mode", isOn: $settings.subtitleMode)

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Cheboo") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var engineWarning: String? {
        switch settings.engineKind {
        case .deepgram:
            return settings.apiKey.isEmpty ? "⚠︎ No Deepgram API key set" : nil
        case .whisperServer:
            return settings.whisperServerURL.isEmpty ? "⚠︎ No Whisper server URL set" : nil
        }
    }
}
