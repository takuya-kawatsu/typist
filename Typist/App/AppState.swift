import SwiftUI
import AVFoundation

@Observable @MainActor
final class AppState {
    var isPermissionGranted = false
    var permissionError: String?

    let coordinator = AudioSessionCoordinator()
    let keyMonitor = KeyMonitor()
    let llmService = LLMTextCleanupService()
    let textInsertion = TextInsertionService()
    let whisperModelManager = WhisperModelManager()
    let whisperService: WhisperService
    private let modelProgress = ModelProgressPanel()

    init() {
        self.whisperService = WhisperService(modelManager: whisperModelManager)
    }

    func bootstrap() {
        // LLM and Whisper model loading — start in parallel
        modelProgress.observe(whisperModelManager: whisperModelManager, llmService: llmService)
        Task { await llmService.loadModel() }
        Task { await whisperService.loadModel() }

        // Permissions — runs in parallel with model loading
        Task { await requestPermissions() }
    }

    private func requestPermissions() async {
        // Request microphone permission (still needed for audio capture)
        let micGranted: Bool
        if #available(macOS 14.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard micGranted else {
            permissionError = "Microphone permission denied."
            return
        }

        // Request accessibility permission (non-blocking — works without it via clipboard fallback)
        textInsertion.requestAccessibility()

        isPermissionGranted = true
    }
}
