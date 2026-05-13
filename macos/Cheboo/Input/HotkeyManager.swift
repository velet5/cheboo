import AppKit
import Carbon.HIToolbox

/// Press-and-hold global hotkey via Carbon's `RegisterEventHotKey`.
///
/// Carbon was the only API that survived deprecation rounds for system-wide
/// hotkeys; `NSEvent.addGlobalMonitorForEvents` cannot deliver release events
/// for arbitrary keys. We register both `kEventHotKeyPressed` and
/// `kEventHotKeyReleased` so dictation can be push-to-talk style.
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = OSType(0x4348424F) // 'CHBO'
    private let hotKeyID: UInt32

    init(id: UInt32 = 1) {
        self.hotKeyID = id
    }

    /// Register the hotkey. Passing keyCode 0 means "unbound" — any existing
    /// binding is dropped and no event handler is installed.
    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        guard keyCode != 0 else { return }

        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("HotkeyManager: RegisterEventHotKey failed with \(status)")
            return
        }
        hotKeyRef = ref

        let types = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            // Carbon delivers every hotkey event to every installed handler,
            // so we have to gate on the hotkey ID ourselves — otherwise a
            // second HotkeyManager would fire on the first manager's key.
            var hkID = EventHotKeyID()
            let getStatus = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard getStatus == noErr, hkID.id == manager.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }

            let kind = GetEventKind(eventRef)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) {
                    manager.onPress?()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    manager.onRelease?()
                }
            }
            return noErr
        }

        var handler: EventHandlerRef?
        types.withUnsafeBufferPointer { buffer in
            _ = InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                buffer.count,
                buffer.baseAddress,
                selfPtr,
                &handler
            )
        }
        handlerRef = handler
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}

/// Lightweight Carbon-modifier helpers so the UI doesn't have to import Carbon.
enum HotkeyModifier: UInt32, CaseIterable, Identifiable {
    case command = 256       // cmdKey
    case option = 2048       // optionKey
    case control = 4096      // controlKey
    case shift = 512         // shiftKey

    var id: UInt32 { rawValue }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }
}

extension UInt32 {
    /// Render Carbon modifier flags as their key-cap symbols (e.g. "⌥⌘").
    var hotkeyModifierString: String {
        HotkeyModifier.allCases
            .filter { self & $0.rawValue != 0 }
            .map(\.symbol)
            .joined()
    }
}
