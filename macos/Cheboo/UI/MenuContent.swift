import AppKit
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openSettings) private var openSettings

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

        // Deliberately not a `SettingsLink`. Cheboo is an LSUIElement app, so
        // it runs with the `.accessory` activation policy and is never made
        // frontmost just because one of its windows is ordered front — the
        // Settings window opens *underneath* whatever app the user was in.
        // With no Dock icon and no Cmd-Tab entry (accessory apps are excluded
        // from both), a buried Settings window is unreachable, and clicking
        // this item again doesn't help: the window already exists, so opening
        // it is a no-op that still leaves the app inactive.
        //
        // `openSettings` is the macOS 14 equivalent of SettingsLink's action,
        // and unlike the link it lets us activate alongside it — menu-style
        // MenuBarExtra content becomes a real NSMenu, so gestures attached to
        // a SettingsLink never fire.
        Button("Settings…") { showSettings() }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Cheboo") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Raise the Settings window and put Cheboo in front of whatever the user
    /// was working in.
    ///
    /// `openSettings()` on its own only covers the first open: once the window
    /// exists the call is a no-op, so a Settings window that has since been
    /// buried stays buried and — with no Dock icon and no Cmd-Tab entry —
    /// becomes unreachable. Ordering it front explicitly is what makes a
    /// second click recover it.
    private func showSettings() {
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
        // On a first open the window doesn't exist yet, so let SwiftUI create
        // it before we reach for it.
        DispatchQueue.main.async {
            // The HUD and subtitle overlays are non-activating panels that
            // can't become main, which leaves the Settings window as the only
            // candidate.
            NSApplication.shared.windows
                .first { $0.canBecomeMain }?
                .makeKeyAndOrderFront(nil)
        }
    }

    private var engineWarning: String? {
        switch settings.engineKind {
        case .deepgram:
            return settings.apiKey.isEmpty ? "⚠︎ No Deepgram API key set" : nil
        case .gptTranscribe, .gptLiveTranscribe:
            return settings.openAIAPIKey.isEmpty ? "⚠︎ No OpenAI API key set" : nil
        case .whisperServer:
            return settings.whisperServerURL.isEmpty ? "⚠︎ No Whisper server URL set" : nil
        case .whisperLocal:
            // On-device engine needs no key or URL — model downloads on first use.
            return nil
        }
    }
}
