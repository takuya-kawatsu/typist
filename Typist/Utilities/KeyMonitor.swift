import Cocoa
import Combine

@MainActor
final class KeyMonitor: ObservableObject {
    @Published var isHolding = false

    private var localMonitor: Any?
    private var globalMonitor: Any?

    // Fn (Globe) key = keyCode 63
    private let fnKeyCode: UInt16 = 63

    func startMonitoring() {
        // Local monitor (when app is focused)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        // Global monitor (when app is not focused)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handleEvent(event)
        }
    }

    func stopMonitoring() {
        if let local = localMonitor {
            NSEvent.removeMonitor(local)
            localMonitor = nil
        }
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
        isHolding = false
    }

    private func handleEvent(_ event: NSEvent) {
        // Detect Ctrl + Fn combination
        // Fn key is keyCode 63 and appears as flagsChanged
        // We check for Control modifier + Fn key
        if event.type == .flagsChanged && event.keyCode == fnKeyCode {
            let controlPressed = event.modifierFlags.contains(.control)
            let fnPressed = event.modifierFlags.contains(.function)

            let shouldHold = controlPressed && fnPressed
            if isHolding != shouldHold {
                isHolding = shouldHold
            }
        } else if event.type == .flagsChanged {
            // If Control is released while Fn is still held (or vice versa)
            let controlPressed = event.modifierFlags.contains(.control)
            let fnPressed = event.modifierFlags.contains(.function)
            let shouldHold = controlPressed && fnPressed
            if isHolding && !shouldHold {
                isHolding = false
            }
        }
    }

}
