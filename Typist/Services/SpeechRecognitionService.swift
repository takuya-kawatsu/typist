import Speech
import AVFoundation

@MainActor
final class SpeechRecognitionService: ObservableObject {
    @Published var partialResult: String = ""
    @Published var isRecognizing: Bool = false

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var coordinator: AudioSessionCoordinator?
    private var currentLocale: Locale?

    /// When true, recognition auto-restarts on timeout/no-speech errors.
    private var autoRestart = false
    /// When true, partialResult accumulates text across session restarts.
    private var accumulateText = false
    /// Text committed from previous sessions or in-session resets (used when accumulateText is true).
    private var accumulatedText = ""
    /// Tracks the latest bestTranscription within the current session to detect in-session resets.
    private var previousSessionText = ""
    /// Monotonic counter to discard callbacks from stale (cancelled) recognition tasks.
    private var taskGeneration = 0
    private var pendingRestart: DispatchWorkItem?

    // MARK: - Backoff & restart limit

    private var consecutiveRestarts = 0
    private let maxConsecutiveRestarts = 10
    private let baseRestartDelay: TimeInterval = 0.3
    private let backoffMultiplier: Double = 1.5
    private let maxRestartDelay: TimeInterval = 5.0

    // MARK: - Watchdog

    private var watchdogTask: Task<Void, Never>?
    private let watchdogTimeout: TimeInterval = 60

    // MARK: - Recoverable errors

    /// Error codes in kAFAssistantErrorDomain that we can recover from by restarting.
    private static let recoverableErrorCodes: Set<Int> = [
        216,   // 60-second timeout
        1110,  // No speech detected
        1101,  // Recognition service reset
        1700,  // Recognition request was canceled
    ]

    // MARK: - Callbacks

    var onFinalResult: ((String) -> Void)?
    var onSessionWillRestart: (() -> Void)?
    var onRestartLimitReached: (() -> Void)?
    var onError: ((Error) -> Void)?

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Start / Stop

    func startRecognition(locale: Locale, coordinator: AudioSessionCoordinator, autoRestart: Bool = false, accumulateText: Bool = false) {
        self.coordinator = coordinator
        self.currentLocale = locale
        self.autoRestart = autoRestart
        self.accumulateText = accumulateText
        self.accumulatedText = ""
        self.previousSessionText = ""
        self.consecutiveRestarts = 0

        // Cancel any pending restart
        pendingRestart?.cancel()
        pendingRestart = nil

        // Clean up previous session without cancelling autoRestart flag
        stopRecognitionInternal()

        recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer else {
            print("[STT] Failed to create recognizer for \(locale.identifier)")
            return
        }
        guard recognizer.isAvailable else {
            print("[STT] Recognizer not available for \(locale.identifier)")
            return
        }

        recognizer.supportsOnDeviceRecognition = true

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }

        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true

        taskGeneration += 1
        let generation = taskGeneration
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.taskGeneration == generation else { return }
                self.handleRecognitionResult(result, error: error)
            }
        }

        do {
            try coordinator.installTap { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            isRecognizing = true
            resetWatchdog()
            print("[STT] Started recognition for \(locale.identifier) (autoRestart=\(autoRestart))")
        } catch {
            print("[STT] Failed to install tap: \(error)")
            onError?(error)
        }
    }

    /// Full stop — cancels auto-restart, cleans up everything
    func stopRecognition() {
        autoRestart = false
        accumulatedText = ""
        previousSessionText = ""
        pendingRestart?.cancel()
        pendingRestart = nil
        cancelWatchdog()
        stopRecognitionInternal()
    }

    /// Internal cleanup — does NOT change autoRestart flag.
    /// When `preserveAudioPipeline` is true, keeps AVAudioEngine and tap running.
    private func stopRecognitionInternal(preserveAudioPipeline: Bool = false) {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognizer = nil

        if preserveAudioPipeline {
            // Only nil out the handler content — the tap stays installed
            coordinator?.replaceTapHandler { _, _ in /* discard until new request */ }
        } else {
            coordinator?.removeTap()
        }

        isRecognizing = false
        if !(preserveAudioPipeline && accumulateText) {
            partialResult = ""
        }
    }

    // MARK: - Recognition result handling

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let sessionText = result.bestTranscription.formattedString

            // Detect in-session transcription reset: the recognizer sometimes
            // restarts its internal context after a pause, producing a much
            // shorter string that doesn't extend the previous text.
            if accumulateText
                && !previousSessionText.isEmpty
                && !sessionText.isEmpty
                && sessionText.count < previousSessionText.count / 2
                && !sessionText.hasPrefix(previousSessionText) {
                accumulatedText += previousSessionText
            }
            previousSessionText = sessionText
            partialResult = accumulatedText + sessionText

            // Successful speech received — reset backoff counter
            consecutiveRestarts = 0
            resetWatchdog()

            if result.isFinal {
                if accumulateText {
                    accumulatedText = partialResult
                    previousSessionText = ""
                } else {
                    partialResult = ""
                }
                onFinalResult?(sessionText)

                // Recognition task is done after isFinal — restart to keep listening
                if autoRestart {
                    scheduleRestart()
                    return
                }
            }
        }

        if let error {
            let nsError = error as NSError

            if autoRestart && isRecoverableError(nsError) {
                scheduleRestart()
                return
            }

            // For all other errors or when autoRestart is off, just report
            if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 1 {
                // code 1 = cancelled (expected when we call stopRecognition)
                print("[STT] Recognition error: \(nsError.domain) code=\(nsError.code)")
            }
        }
    }

    // MARK: - Recoverable error check

    private func isRecoverableError(_ error: NSError) -> Bool {
        error.domain == "kAFAssistantErrorDomain"
            && Self.recoverableErrorCodes.contains(error.code)
    }

    // MARK: - Restart logic

    private func scheduleRestart() {
        guard autoRestart, let coordinator, let currentLocale else { return }

        pendingRestart?.cancel()
        pendingRestart = nil

        consecutiveRestarts += 1

        if consecutiveRestarts > maxConsecutiveRestarts {
            print("[STT] Restart limit reached (\(maxConsecutiveRestarts) consecutive restarts)")
            cancelWatchdog()
            stopRecognitionInternal()
            onRestartLimitReached?()
            return
        }

        onSessionWillRestart?()

        let delay = restartDelay()
        print("[STT] Scheduling restart #\(consecutiveRestarts) after \(String(format: "%.2f", delay))s")

        // Save accumulated text before stopping
        if accumulateText {
            accumulatedText = partialResult
            previousSessionText = ""
        }

        // Stop recognition session but keep audio pipeline alive
        stopRecognitionInternal(preserveAudioPipeline: true)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.autoRestart else { return }
            self.restartRecognitionSession(locale: currentLocale, coordinator: coordinator)
        }
        pendingRestart = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Lightweight restart: rebuilds recognizer/request/task only, reuses existing AVAudioEngine tap.
    private func restartRecognitionSession(locale: Locale, coordinator: AudioSessionCoordinator) {
        recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer else {
            print("[STT] Failed to create recognizer for lightweight restart")
            return
        }
        guard recognizer.isAvailable else {
            print("[STT] Recognizer not available for lightweight restart")
            return
        }

        recognizer.supportsOnDeviceRecognition = true

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }

        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true

        taskGeneration += 1
        let generation = taskGeneration
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.taskGeneration == generation else { return }
                self.handleRecognitionResult(result, error: error)
            }
        }

        // Redirect existing tap to the new request
        coordinator.replaceTapHandler { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        isRecognizing = true
        resetWatchdog()
        print("[STT] Restarted recognition session (audio tap preserved)")
    }

    /// Calculate restart delay with exponential backoff.
    private func restartDelay() -> TimeInterval {
        let exponent = max(0, consecutiveRestarts - 1)
        let delay = baseRestartDelay * pow(backoffMultiplier, Double(exponent))
        return min(delay, maxRestartDelay)
    }

    // MARK: - Watchdog

    private func resetWatchdog() {
        cancelWatchdog()
        guard autoRestart else { return }
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.watchdogTimeout ?? 60))
            guard !Task.isCancelled else { return }
            guard let self, self.autoRestart else { return }
            print("[STT] Watchdog: no activity for \(self.watchdogTimeout)s — forcing restart")
            self.scheduleRestart()
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }
}
