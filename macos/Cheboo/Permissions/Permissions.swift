import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid

enum Permissions {
    // MARK: Microphone

    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: Accessibility (required for CGEventPost)

    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user and adds Cheboo to the Accessibility list. Returns the
    /// current trust state synchronously; the user will need to flip the switch
    /// in System Settings before subsequent calls return true.
    @discardableResult
    static func promptAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: Any] = [key: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: Input Monitoring (required for global hotkey on modern macOS)

    static func hasInputMonitoring() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: Deep links into System Settings

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
