import AVFoundation
import Foundation

enum Permissions {
    static func microphoneStatus() -> AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestMicrophone() async -> Bool {
        if microphoneStatus() == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }
}
