import Cocoa
import os

private let logger = Logger(subsystem: "com.takuya.Typist", category: "TextInsertion")

@Observable @MainActor
final class TextInsertionService {

    /// Whether accessibility permission is granted (polled periodically).
    private(set) var isAccessibilityGranted = AXIsProcessTrusted()

    /// Start periodic polling for accessibility permission changes.
    func startAccessibilityPolling() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let granted = AXIsProcessTrusted()
                if granted != isAccessibilityGranted {
                    isAccessibilityGranted = granted
                    logger.info("Accessibility permission changed: \(granted)")
                }
            }
        }
    }

    /// Prompt the user for accessibility permission (shows system dialog).
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Insert text at the cursor position of the frontmost application.
    /// Primary: clipboard + Cmd+V (most reliable across apps).
    /// Fallback: clipboard copy only (when no accessibility).
    func insertText(_ text: String) {
        logger.debug("Accessibility: \(self.isAccessibilityGranted)")

        if isAccessibilityGranted {
            logger.debug("Using clipboard + Cmd+V")
            insertViaClipboard(text)
            return
        }

        // No accessibility — just copy to clipboard (CGEvent won't work either)
        logger.debug("No accessibility, copying to clipboard only")
        copyToClipboard(text)
    }

    // MARK: - Clipboard

    /// Copy text to clipboard only (no paste simulation).
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Copied to clipboard — press Cmd+V to paste")
    }

    /// Copy text to clipboard and simulate Cmd+V (requires accessibility).
    private func insertViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        Task {
            try? await Task.sleep(for: .milliseconds(50))
            simulateCmdV()
            logger.debug("Cmd+V simulated")

            // Restore previous clipboard after paste completes
            if let previous = previousContents {
                try? await Task.sleep(for: .milliseconds(500))
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // 0x09 = 'V'
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
