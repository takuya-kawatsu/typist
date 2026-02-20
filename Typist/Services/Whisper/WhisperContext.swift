import Foundation
import whisper
import os

private let logger = Logger(subsystem: "com.takuya.Typist", category: "Whisper")

/// whisper.cpp C API wrapper.
/// All calls to `whisper_full()` are serialised by actor isolation
/// so the underlying C context is never accessed concurrently.
actor WhisperContext {
    private var context: OpaquePointer

    init(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true  // Use Metal if available; Core ML warning is harmless
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.failedToLoadModel(modelPath)
        }
        self.context = ctx
        logger.info("Model loaded: \(modelPath)")
    }

    deinit {
        whisper_free(context)
    }

    /// Run inference synchronously on the actor's serial executor.
    func infer(samples: [Float], language: String = "auto") -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let threadCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)

        params.n_threads = Int32(threadCount)
        params.translate = false
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.no_timestamps = false
        params.single_segment = false
        params.max_initial_ts = 5.0

        // Limit encoder work to actual audio length instead of full 30s window.
        // hop_size = 160 for whisper mel spectrogram.
        // Round up to multiple of 64 to satisfy Metal's F16/F32 alignment requirements.
        let melColumns = samples.count / 160
        let rawCtx = melColumns + 100
        let alignedCtx = ((rawCtx + 63) / 64) * 64
        params.audio_ctx = Int32(min(alignedCtx, 1500))

        let duration = Float(samples.count) / 16000.0
        var minVal: Float = 0, maxVal: Float = 0
        if let mi = samples.min(), let ma = samples.max() { minVal = mi; maxVal = ma }
        logger.info("Inference: \(samples.count) samples (\(String(format: "%.1f", duration))s), audio_ctx=\(params.audio_ctx), range [\(minVal), \(maxVal)]")

        let result: Int32 = language.withCString { langPtr in
            params.language = langPtr
            return samples.withUnsafeBufferPointer { bufferPtr in
                whisper_full(context, params, bufferPtr.baseAddress!, Int32(samples.count))
            }
        }

        guard result == 0 else {
            logger.error("Inference failed with code \(result)")
            return ""
        }

        let segmentCount = whisper_full_n_segments(context)
        var text = ""
        for i in 0..<segmentCount {
            if let cStr = whisper_full_get_segment_text(context, i) {
                text += String(cString: cStr)
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Result: \(segmentCount) segments, text='\(trimmed)'")
        return trimmed
    }
}

enum WhisperError: LocalizedError {
    case failedToLoadModel(String)

    var errorDescription: String? {
        switch self {
        case .failedToLoadModel(let path):
            return "Failed to load Whisper model at \(path)"
        }
    }
}
