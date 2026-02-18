import Cocoa
import SwiftUI

final class OverlayPanel {
    private var panel: NSPanel?
    private let panelWidth: CGFloat = 400
    private let panelHeight: CGFloat = 60

    @MainActor
    func show(state: TypistState, text: String) {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        let hostingView = NSHostingView(rootView: OverlayContent(state: state, text: text))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        panel.contentView?.addSubview(hostingView)

        positionPanel()
        panel.orderFrontRegardless()
    }

    @MainActor
    func hide() {
        panel?.orderOut(nil)
    }

    @MainActor
    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        self.panel = panel
    }

    @MainActor
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
    let state: TypistState
    let text: String

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
        switch state {
        case .idle: return "keyboard"
        case .recording: return "mic.fill"
        case .processing: return "brain"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch state {
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
        if text.isEmpty {
            switch state {
            case .idle: return ""
            case .recording: return "Listening..."
            case .processing: return "Processing..."
            case .done: return "Done"
            }
        }
        return text
    }
}
