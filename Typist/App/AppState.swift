import SwiftUI
import Speech
import AVFoundation

@MainActor
final class AppState: ObservableObject {
    @Published var isPermissionGranted = false
    @Published var permissionError: String?

    let coordinator = AudioSessionCoordinator()
    let sttService = SpeechRecognitionService()
    let keyMonitor = KeyMonitor()
    let llmService = LLMTextCleanupService()
    let textInsertion = TextInsertionService()

    func startLoadingLLM() {
        Task { await llmService.loadModel() }
    }

    func requestPermissions() async {
        // Request speech recognition permission
        let speechStatus = await SpeechRecognitionService.requestAuthorization()
        guard speechStatus == .authorized else {
            permissionError = "Speech recognition permission denied."
            return
        }

        // Request microphone permission
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
