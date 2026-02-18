import Cocoa

@MainActor
final class TextInsertionService {

    /// Check if accessibility permission is granted.
    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
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
        print("[Insert] Accessibility: \(isAccessibilityGranted)")

        if isAccessibilityGranted {
            print("[Insert] Using clipboard + Cmd+V")
            insertViaClipboard(text)
            return
        }

        // No accessibility — just copy to clipboard (CGEvent won't work either)
        print("[Insert] No accessibility, copying to clipboard only")
        copyToClipboard(text)
    }

    // MARK: - Clipboard

    /// Copy text to clipboard only (no paste simulation).
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("[Insert] Copied to clipboard — press Cmd+V to paste")
    }

    /// Copy text to clipboard and simulate Cmd+V (requires accessibility).
    private func insertViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure clipboard is set before paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.simulateCmdV()
            print("[Insert] Cmd+V simulated")

            // Restore previous clipboard after paste completes
            if let previous = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
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
