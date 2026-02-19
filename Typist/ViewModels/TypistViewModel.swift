import SwiftUI
import Combine

enum TypistState {
    case idle
    case recording
    case processing
    case done
}

@MainActor
final class TypistViewModel: ObservableObject {
    @Published var state: TypistState = .idle
    @Published var recognizedText: String = ""
    @Published var cleanedText: String = ""

    private var appState: AppState?
    private var permissionCancellable: AnyCancellable?
    private var holdingCancellable: AnyCancellable?
    private var partialResultCancellable: AnyCancellable?
    private var dismissTask: Task<Void, Never>?
    private var overlayPanel: OverlayPanel?

    /// Bind to AppState — starts key monitoring as soon as permissions are granted.
    func bind(appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState

        permissionCancellable = appState.$isPermissionGranted
            .filter { $0 }
            .first()
            .sink { [weak self] _ in
                self?.startKeyMonitoring()
            }
    }

    private func startKeyMonitoring() {
        guard let appState else { return }

        appState.keyMonitor.startMonitoring()

        holdingCancellable = appState.keyMonitor.$isHolding
            .removeDuplicates()
            .sink { [weak self] isHolding in
                guard let self else { return }
                if isHolding {
                    self.startRecording()
                } else if self.state == .recording {
                    self.stopRecordingAndProcess()
                }
            }
    }

    // MARK: - Recording

    private func startRecording() {
        guard let appState, state == .idle || state == .done else { return }
        guard appState.whisperService.isModelLoaded else {
            print("[Typist] Whisper model not loaded yet")
            return
        }

        dismissTask?.cancel()
        dismissTask = nil

        state = .recording
        recognizedText = ""
        cleanedText = ""

        partialResultCancellable = appState.whisperService.$partialResult
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                if !text.isEmpty {
                    self.recognizedText = text
                    self.updateOverlay()
                }
            }

        appState.whisperService.startRecording(coordinator: appState.coordinator)
        showOverlay()
    }

    private func stopRecordingAndProcess() {
        guard let appState else { return }

        partialResultCancellable?.cancel()
        partialResultCancellable = nil

        state = .processing
        updateOverlay()

        Task {
            let recognized = await appState.whisperService.stopRecording()

            print("[Typist] Recognized: '\(recognized)'")

            guard !recognized.isEmpty else {
                print("[Typist] No text recognized, returning to idle")
                state = .idle
                hideOverlay()
                return
            }

            recognizedText = recognized
            updateOverlay()

            let finalText: String
            if appState.llmService.isReady {
                do {
                    finalText = try await appState.llmService.cleanupText(recognized)
                    print("[Typist] Cleaned: '\(finalText)'")
                } catch {
                    print("[Typist] LLM cleanup error: \(error), using raw text")
                    finalText = recognized
                }
            } else {
                print("[Typist] LLM not ready, using raw text")
                finalText = recognized
            }

            cleanedText = finalText
            appState.textInsertion.insertText(finalText)

            state = .done
            updateOverlay()
            scheduleDismiss()
        }
    }

    // MARK: - Auto-dismiss

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            state = .idle
            hideOverlay()
        }
    }

    // MARK: - Overlay

    private func showOverlay() {
        if overlayPanel == nil {
            overlayPanel = OverlayPanel()
        }
        overlayPanel?.show(state: state, text: recognizedText)
    }

    private func updateOverlay() {
        let displayText: String
        switch state {
        case .recording:
            displayText = recognizedText
        case .processing:
            displayText = recognizedText
        case .done:
            displayText = cleanedText
        case .idle:
            displayText = ""
        }
        overlayPanel?.show(state: state, text: displayText)
    }

    private func hideOverlay() {
        overlayPanel?.hide()
    }
}
