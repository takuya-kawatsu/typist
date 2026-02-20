import Cocoa
import SwiftUI

@Observable @MainActor
final class OverlayPanel {
    var typistState: TypistState = .idle
    var text: String = ""

    private var panel: NSPanel?
    private let panelWidth: CGFloat = 400
    private let panelHeight: CGFloat = 60

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
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
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

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.origin.y + 40  // 40pt from bottom

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}

// MARK: - SwiftUI Overlay Content

private struct OverlayContent: View {
    var overlay: OverlayPanel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            Text(displayText)
                .font(.system(size: 14))
                .lineLimit(2)
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
