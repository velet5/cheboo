# Cheboo — iOS dictation app

Standalone tap-to-record iOS app. Streams mic audio to Deepgram Nova-3 over WebSocket, shows the partial transcript live as you speak, then drops the final into an editable view you can copy, share, or save.

The design plan lives in `../../claude/docs/ios-app-plan.md` (working name there: "Murmur Mobile" — same app). Apple blocks mic access in keyboard extensions, which is why this is a standalone app rather than a system-wide keyboard.

## Layout

```
ios/
├── project.yml                       # XcodeGen spec — generates Cheboo.xcodeproj
├── Cheboo/
│   ├── ChebooApp.swift               # @main, SwiftData container
│   ├── Info.plist
│   ├── Audio/
│   │   ├── AudioEngine.swift         # 16 kHz Int16 PCM (shared verbatim with macOS)
│   │   └── AudioSession.swift        # iOS AVAudioSession setup
│   ├── Network/                      # Deepgram WebSocket (shared verbatim with macOS)
│   ├── Storage/
│   │   ├── Keychain.swift            # API key (shared verbatim)
│   │   ├── SettingsStore.swift       # iOS-flavored UserDefaults wrapper
│   │   └── TranscriptStore.swift     # SwiftData @Model
│   ├── Resources/Keyterms.swift      # default dev-jargon list (shared verbatim)
│   ├── Dictation/
│   │   ├── DictationController.swift # tap-to-toggle state machine
│   │   ├── Language.swift            # locale → Deepgram language code
│   │   └── Permissions.swift         # AVAudioApplication mic permission
│   ├── Intents/DictateIntent.swift   # Shortcuts / Siri entry
│   └── UI/                           # SwiftUI views
└── README.md
```

`Audio/AudioEngine.swift`, `Network/`, `Storage/Keychain.swift`, and `Resources/Keyterms.swift` are duplicates of their macOS counterparts. Keep them in sync (or pull both projects into a shared SPM package once we tire of doing it by hand).

## Build

```sh
brew install xcodegen          # one-time
cd ios
xcodegen generate              # creates Cheboo.xcodeproj
open Cheboo.xcodeproj          # build & run from Xcode (⌘R)
```

For a device build from CLI (replace `<destination>` with your device or `generic/platform=iOS Simulator,name=iPhone 15`):

```sh
xcodebuild -project Cheboo.xcodeproj \
  -scheme Cheboo \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

The simulator's microphone is unreliable; do real-device testing for the mic + Deepgram pipeline.

## First run

1. Launch the app. If no API key is set, the Welcome sheet asks for one.
2. Paste your Deepgram API key (stored in Keychain).
3. iOS prompts for **Microphone** access on first tap of the mic button. Grant it.
4. Tap mic → talk → tap mic again. Live partials show above the button; final text moves into an editable view with Copy / Share / Discard.

## Settings

- **Language** — Automatic (device locale), English, or Русский (multilingual model).
- **Auto punctuation** — let Deepgram insert marks vs. dictating them ("comma", "period").
- **Smart formatting** — capitalization, numbers, etc. Also forces punctuation back on (Deepgram quirk).
- **Save to history** — when off, finished transcripts aren't persisted to SwiftData.
- **Keyterms** — dev-jargon biasing terms (up to 100), editable.

## Shortcuts

The app exposes a `StartDictationIntent` ("Start Dictation"). Add it to the Action Button, an Apple Watch complication, or any Shortcut to launch the app armed for capture.

## Status

- M1 (end-to-end spike): audio → socket → live transcript — done
- M2 (real UI): waveform-reactive mic button, post-recording editor — done
- M3 (history + persistence): SwiftData store, list + search + swipe-delete — done
- M4 (settings + keychain): API key entry, keyterm editor, language picker — done
- M5 (Shortcuts integration): `StartDictationIntent` + `AppShortcutsProvider` — done
- M6 (background capture + polish): interruption + route-change handling — partial; background audio mode not enabled (decide before public release)

## Known limits / TODO

- Background mic capture is **not** enabled. Add `UIBackgroundModes: audio` if you need screen-lock tolerance — and brace for App Store review questions.
- No reconnect-on-drop yet. A flaky network ends the current session; user must re-tap.
- BYO API key only. v2 should route through a token-broker backend before any public release; the master key is trivially extracted from an IPA otherwise.
