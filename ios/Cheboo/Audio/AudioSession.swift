import AVFoundation
import Foundation

/// iOS audio session management. Must be activated before `AudioEngine.start()`
/// or the input node returns a zero-rate format.
enum AudioSession {
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: [])
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
