import SwiftUI
import os

private let logger = Logger(subsystem: "com.takuya.Typist", category: "Typist")

enum TypistState {
    case idle
    case recording
    case processing
    case done
}

@Observable @MainActor
final class TypistViewModel {
    var state: TypistState = .idle
    var recognizedText: String = ""
    var cleanedText: String = ""

    private let appState: AppState
    private var permissionTask: Task<Void, Never>?
    private var holdingTask: Task<Void, Never>?
    private var partialResultTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var overlayPanel: OverlayPanel?

    init(appState: AppState) {
        self.appState = appState
        permissionTask = Task { [weak self] in
            await self?.observePermission()
        }
    }

    private func observePermission() async {
        while !Task.isCancelled {
            if appState.isPermissionGranted {
                startKeyMonitoring()
                return
            }
            await withCheckedContinuation { c in
                withObservationTracking {
                    _ = appState.isPermissionGranted
                } onChange: { c.resume() }
            }
        }
    }

    private func startKeyMonitoring() {
        appState.keyMonitor.startMonitoring()

        holdingTask = Task { [weak self] in
            await self?.observeKeyHolding()
        }
    }

    private func observeKeyHolding() async {
        var prev = appState.keyMonitor.isHolding
        while !Task.isCancelled {
            await withCheckedContinuation { c in
                withObservationTracking {
                    _ = appState.keyMonitor.isHolding
                } onChange: { c.resume() }
            }
            let now = appState.keyMonitor.isHolding
            guard now != prev else { continue }
            prev = now
            if now {
                startRecording()
            } else if state == .recording {
                stopRecordingAndProcess()
            }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard state == .idle || state == .done else { return }
        guard appState.whisperService.isModelLoaded else {
            logger.warning("Whisper model not loaded yet")
            return
        }

        dismissTask?.cancel()
        dismissTask = nil

        state = .recording
        recognizedText = ""
        cleanedText = ""

        partialResultTask = Task { [weak self] in
            await self?.observePartialResult()
        }

        appState.whisperService.startRecording(coordinator: appState.coordinator)
        showOverlay()
    }

    private func observePartialResult() async {
        while !Task.isCancelled {
            await withCheckedContinuation { c in
                withObservationTracking {
                    _ = appState.whisperService.partialResult
                } onChange: { c.resume() }
            }
            let text = appState.whisperService.partialResult
            if !text.isEmpty {
                recognizedText = text
                updateOverlay()
            }
        }
    }

    private func stopRecordingAndProcess() {
        partialResultTask?.cancel()
        partialResultTask = nil

        state = .processing
        updateOverlay()

        Task {
            let recognized = await appState.whisperService.stopRecording()

            logger.info("Recognized: '\(recognized)'")

            guard !recognized.isEmpty else {
                logger.info("No text recognized, returning to idle")
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
                    logger.info("Cleaned: '\(finalText)'")
                } catch {
                    logger.error("LLM cleanup error: \(error), using raw text")
                    finalText = recognized
                }
            } else {
                logger.info("LLM not ready, using raw text")
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
