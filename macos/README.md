# Cheboo — macOS dictation app

Menubar-resident push-to-talk dictation. Streams mic audio to Deepgram Nova-3 over WebSocket and injects the transcript as Unicode keystrokes into whatever app has focus.

See `../../claude/docs/macos-app-plan.md` for the full design plan (uses "Murmur" as the working name — same app).

## Layout

```
macos/
├── project.yml              # XcodeGen spec — generates Cheboo.xcodeproj
├── Cheboo/
│   ├── ChebooApp.swift           # @main, MenuBarExtra + Settings scenes
│   ├── DictationController.swift # owns audio + socket + injection lifecycle
│   ├── Audio/                    # AVAudioEngine → 16 kHz Int16 PCM frames
│   ├── Network/                  # Deepgram WebSocket client + JSON types
│   ├── Input/                    # Global hotkey (Carbon) + CGEvent injection
│   ├── UI/                       # HUD overlay, menu, settings
│   ├── Storage/                  # UserDefaults + Keychain
│   ├── Permissions/              # Mic, Accessibility, Input Monitoring
│   ├── Resources/                # Default keyterm list
│   └── Cheboo.entitlements
└── README.md
```

`Audio/`, `Network/`, `Storage/Keychain.swift`, and `Resources/Keyterms.swift` are intentionally free of AppKit and should drop into a future iOS target with no changes.

## Build

```sh
brew install xcodegen          # one-time
cd macos
xcodegen generate              # creates Cheboo.xcodeproj
open Cheboo.xcodeproj          # build & run from Xcode (⌘R)
```

For a release build from CLI:

```sh
xcodebuild -project Cheboo.xcodeproj \
  -scheme Cheboo \
  -configuration Release \
  -derivedDataPath build \
  build
cp -R build/Build/Products/Release/Cheboo.app /Applications/
```

The app ships ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`). Notarization is deferred to v2.

## First run

1. Launch `Cheboo.app` — a microphone icon appears in the menubar.
2. Click the icon → **Settings…** → paste your Deepgram API key (stored in Keychain).
3. macOS will prompt for **Microphone** access on the first hotkey press, and for **Accessibility** + **Input Monitoring** when registering the hotkey / injecting keystrokes. Grant all three.
4. Default hotkey is **⌥Space**. Press and hold anywhere → speak → release.

If a prompt is missed, the Settings window has buttons to re-open the relevant System Settings panes.

## Hotkey

Press-and-hold is implemented via Carbon `RegisterEventHotKey` with both `kEventHotKeyPressed` and `kEventHotKeyReleased`. Keycodes use Carbon `kVK_*` values; modifiers use Carbon flag constants (`optionKey`, `cmdKey`, `controlKey`, `shiftKey`).

## Status

- M1 (end-to-end spike): socket + audio + stdout transcript — done
- M2 (text injection): `CGEventKeyboardSetUnicodeString` path — done
- M3 (menubar + settings): API key (Keychain), hotkey picker, keyterm editor — done
- M4 (HUD overlay): floating panel near mouse cursor — done (caret tracking deferred)
- M5 (polish): permission helpers, error surfacing — done; reconnect-on-drop is TODO
