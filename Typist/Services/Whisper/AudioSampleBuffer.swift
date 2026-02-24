import AVFoundation
import Synchronization
import os

private let logger = Logger(subsystem: "jp.kw2.Typist", category: "AudioSampleBuffer")

final class AudioSampleBuffer: @unchecked Sendable {
    private let samples = Mutex<[Float]>([])
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

        samples.withLock { $0.append(contentsOf: UnsafeBufferPointer(start: floatData, count: count)) }
    }

    func snapshot() -> [Float] {
        samples.withLock { Array($0) }
    }

    func reset() {
        samples.withLock { $0.removeAll(keepingCapacity: true) }
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
            logger.error("Resample error: \(error)")
            return nil
        }

        return outputBuffer
    }
}
