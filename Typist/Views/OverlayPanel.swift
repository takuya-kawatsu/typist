import Cocoa
import SwiftUI

@Observable @MainActor
final class OverlayPanel {
    var typistState: TypistState = .idle
    var text: String = ""

    private var panel: NSPanel?
    private let panelWidth: CGFloat = 400
    private let compactHeight: CGFloat = 60

    func show(state: TypistState, text: String) {
        typistState = state
        self.text = text
        ensurePanel()
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: compactHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: OverlayContent(overlay: self))
        hostingView.frame = p.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hostingView)

        panel = p
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }

        let height = panelHeight
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.origin.y + 40  // 40pt from bottom

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true, animate: false)
    }

    /// Compact during recording/processing; taller for done to show full text.
    private var panelHeight: CGFloat {
        guard typistState == .done, !text.isEmpty else {
            return compactHeight
        }
        // Estimate lines: ~22 Japanese chars or ~35 ASCII chars per line at 14pt in ~350pt width
        let charsPerLine = 22
        let lineCount = max(1, (text.count + charsPerLine - 1) / charsPerLine)
        let clampedLines = min(lineCount, 8)
        let textHeight = CGFloat(clampedLines) * 20  // ~20pt per line at font size 14
        return max(compactHeight, textHeight + 40)    // 40pt for vertical padding + icon
    }
}

// MARK: - SwiftUI Overlay Content

private struct OverlayContent: View {
    var overlay: OverlayPanel

    private var isStreaming: Bool {
        overlay.typistState == .recording || overlay.typistState == .processing
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 24, alignment: .center)

            Text(displayText)
                .font(.system(size: 14))
                .lineLimit(isStreaming ? 2 : 8)
                .truncationMode(isStreaming ? .head : .tail)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
        )
        .padding(4)
    }

    private var iconName: String {
        switch overlay.typistState {
        case .idle: return "keyboard"
        case .recording: return "mic.fill"
        case .processing: return "brain"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch overlay.typistState {
        case .idle: return .white
        case .recording: return .red
        case .processing: return .orange
        case .done: return .green
        }
    }

    private var backgroundColor: Color {
        Color.black.opacity(0.85)
    }

    private var displayText: String {
        if overlay.text.isEmpty {
            switch overlay.typistState {
            case .idle: return ""
            case .recording: return "Listening..."
            case .processing: return "Processing..."
            case .done: return "Done"
            }
        }
        return overlay.text
    }
}
