import AVFoundation

enum AudioState: Sendable {
    case idle
    case listening
}

@Observable @MainActor
final class AudioSessionCoordinator {
    private(set) var state: AudioState = .idle

    let audioEngine = AVAudioEngine()
    private var currentTapInstalled = false

    /// Indirect tap handler — allows swapping the handler without removing/reinstalling the tap.
    nonisolated(unsafe) var tapHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    func transitionTo(_ newState: AudioState) {
        let oldState = state
        guard oldState != newState else { return }

        // Always clean up: remove tap and stop engine
        cleanupEngine()
        state = newState
    }

    func installTap(bufferSize: AVAudioFrameCount = 1024, handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        // Always start from a clean state
        cleanupEngine()

        self.tapHandler = handler

        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("[Audio] Invalid format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
            throw NSError(domain: "AudioSessionCoordinator", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid audio input format"])
        }

        audioEngine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            // Trampoline: delegate to the current tapHandler so it can be swapped at runtime.
            self?.tapHandler?(buffer, time)
        }
        currentTapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Replace the tap handler without touching AVAudioEngine or the installed tap.
    func replaceTapHandler(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.tapHandler = handler
    }

    func removeTap() {
        cleanupEngine()
    }

    func stopEngine() {
        cleanupEngine()
        state = .idle
    }

    private func cleanupEngine() {
        tapHandler = nil
        if currentTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            currentTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }
}
