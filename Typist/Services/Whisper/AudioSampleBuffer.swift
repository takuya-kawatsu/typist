import AVFoundation

final class AudioSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    init() {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = resample(buffer) else { return }
        guard let floatData = converted.floatChannelData?[0] else { return }
        let count = Int(converted.frameLength)

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: floatData, count: count))
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format

        if sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == targetFormat.channelCount
            && sourceFormat.commonFormat == targetFormat.commonFormat {
            return buffer
        }

        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            print("[AudioSampleBuffer] Resample error: \(error)")
            return nil
        }

        return outputBuffer
    }
}
