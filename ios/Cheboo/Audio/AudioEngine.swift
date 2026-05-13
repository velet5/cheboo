import AVFoundation
import Foundation

protocol AudioEngineDelegate: AnyObject {
    func audioEngine(_ engine: AudioEngine, didCapture pcm: Data)
    func audioEngine(_ engine: AudioEngine, didFailWith error: Error)
}

/// Captures mic audio and converts to 16 kHz mono Int16 PCM frames suitable for
/// Deepgram's `encoding=linear16&sample_rate=16000&channels=1` stream.
final class AudioEngine {
    weak var delegate: AudioEngineDelegate?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let callbackQueue = DispatchQueue(label: "com.github.velet5.cheboo.audio")

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw NSError(
                domain: "AudioEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input available."]
            )
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        converter = nil
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var supplied = false
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let convertError {
                callbackQueue.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.audioEngine(self, didFailWith: convertError)
                }
            }
            return
        }

        let frameCount = Int(output.frameLength)
        guard frameCount > 0, let channelData = output.int16ChannelData?[0] else { return }
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let data = Data(bytes: channelData, count: byteCount)

        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioEngine(self, didCapture: data)
        }
    }
}
