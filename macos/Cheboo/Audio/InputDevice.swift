import Combine
import CoreAudio
import Foundation

/// One enumerable audio input device — the bits we surface to the user and
/// also use to set the underlying AUHAL device on `AVAudioEngine.inputNode`.
struct InputDevice: Equatable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Read-only Core Audio HAL queries used by both the settings UI and the
/// audio engine. The HAL identifies each device with a stable `UID` string
/// (e.g. `BuiltInMicrophoneDevice`, `AppleUSBAudioEngine:...`) and a
/// per-process `AudioDeviceID` int — we persist the UID and resolve to the
/// int on demand, so the user's pick survives reboots and re-plugs.
enum InputDevices {
    /// All currently-attached devices that expose at least one input stream.
    static func availableDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBufferPointer { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &dataSize, base
            )
        }
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id -> InputDevice? in
            guard hasInputStream(id) else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Look up an `AudioDeviceID` for a previously-saved UID. Returns nil if
    /// no attached device matches — caller should fall back to the system
    /// default in that case.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        availableDevices().first { $0.uid == uid }?.id
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    // MARK: - Private helpers

    private static func hasInputStream(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let unmanaged = value else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}

/// Observable wrapper around the device list, kept fresh by a Core Audio
/// property listener on `kAudioHardwarePropertyDevices`. SwiftUI views can
/// subscribe to `devices` and the picker re-renders as mics hot-plug.
final class InputDeviceMonitor: ObservableObject {
    static let shared = InputDeviceMonitor()

    @Published private(set) var devices: [InputDevice]

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {
        self.devices = InputDevices.availableDevices()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Dispatch hop is already on .main per the listener registration.
            self?.refresh()
        }
        self.listenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            Log.audio.error("InputDeviceMonitor: failed to add property listener (\(status, privacy: .public))")
        }
    }

    deinit {
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
        }
    }

    private func refresh() {
        devices = InputDevices.availableDevices()
    }
}
