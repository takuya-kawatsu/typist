import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: "com.takuya.Typist", category: "WhisperService")

@Observable @MainActor
final class WhisperService {
    var partialResult: String = ""
    var isRecognizing: Bool = false

    private var whisperContext: WhisperContext?
    private let sampleBuffer = AudioSampleBuffer()
    private var periodicTask: Task<Void, Never>?
    private var inferenceTask: Task<Void, Never>?
    private weak var coordinator: AudioSessionCoordinator?

    private let modelManager: WhisperModelManager

    init(modelManager: WhisperModelManager) {
        self.modelManager = modelManager
    }

    // MARK: - Model loading

    func loadModel() async {
        modelManager.state = .loading
        do {
            let path = try await modelManager.ensureModel()
            modelManager.state = .loading
            whisperContext = try await Task.detached {
                try WhisperContext(modelPath: path)
            }.value
            modelManager.state = .ready(path: path)
            logger.info("Model ready")
        } catch {
            modelManager.state = .error(error.localizedDescription)
            logger.error("Model load failed: \(error)")
        }
    }

    var isModelLoaded: Bool { whisperContext != nil }

    // MARK: - Recording

    func startRecording(coordinator: AudioSessionCoordinator) {
        guard whisperContext != nil else {
            logger.warning("Model not loaded, cannot start recording")
            return
        }

        self.coordinator = coordinator
        sampleBuffer.reset()
        partialResult = ""
        isRecognizing = true

        coordinator.transitionTo(.listening)

        do {
            try coordinator.installTap { [weak self] buffer, _ in
                self?.sampleBuffer.append(buffer)
            }
        } catch {
            logger.error("Failed to install audio tap: \(error)")
            isRecognizing = false
            return
        }

        // Start periodic inference every 3 seconds for live partial results
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                self?.runPeriodicInference()
            }
        }

        logger.info("Recording started")
    }

    func stopRecording() async -> String {
        periodicTask?.cancel()
        periodicTask = nil

        // Wait for any in-flight periodic inference to complete
        if let task = inferenceTask {
            _ = await task.value
            inferenceTask = nil
        }

        coordinator?.removeTap()
        coordinator?.transitionTo(.idle)
        coordinator = nil

        let finalText = await runFinalInference()

        sampleBuffer.reset()
        isRecognizing = false
        partialResult = ""

        logger.info("Recording stopped, final: '\(finalText)'")
        return finalText
    }

    // MARK: - Inference

    private func runPeriodicInference() {
        guard inferenceTask == nil, let ctx = whisperContext else { return }

        let samples = sampleBuffer.snapshot()
        guard samples.count > 16000 else { return } // At least 1 second of audio

        inferenceTask = Task { [weak self] in
            let text = await ctx.infer(samples: samples)
            guard let self, self.isRecognizing else { return }
            if !text.isEmpty {
                self.partialResult = text
            }
            self.inferenceTask = nil
        }
    }

    private func runFinalInference() async -> String {
        guard let ctx = whisperContext else { return partialResult }

        let samples = sampleBuffer.snapshot()
        guard !samples.isEmpty else { return partialResult }

        let text = await ctx.infer(samples: samples)
        return text.isEmpty ? partialResult : text
    }
}
