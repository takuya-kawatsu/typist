import Cocoa
import SwiftUI
import Combine

@MainActor
final class ModelProgressPanel {
    private var panel: NSPanel?
    private var observation: AnyCancellable?

    private let panelWidth: CGFloat = 340
    private let panelHeight: CGFloat = 100

    func observe(_ llmService: LLMTextCleanupService) {
        observation = llmService.$state
            .sink { [weak self] state in
                print("[ModelProgress] State: \(state)")
                switch state {
                case .downloading(let progress):
                    self?.show(phase: .downloading(progress))
                case .loading:
                    self?.show(phase: .loading)
                case .ready, .error:
                    self?.hide()
                case .idle:
                    break
                }
            }
    }

    private func show(phase: ModelProgressPhase) {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }

        let hostingView = NSHostingView(rootView: ModelProgressContent(phase: phase))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        panel.contentView?.addSubview(hostingView)

        positionPanel()
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.title = "Typist"
        panel.isMovableByWindowBackground = true

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.midY - panelHeight / 2
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}

// MARK: - Phase

enum ModelProgressPhase {
    case downloading(Double)
    case loading
}

// MARK: - SwiftUI Content

private struct ModelProgressContent: View {
    let phase: ModelProgressPhase

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
            }

            switch phase {
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .loading:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var iconName: String {
        switch phase {
        case .downloading: return "arrow.down.circle"
        case .loading: return "cpu"
        }
    }

    private var title: String {
        switch phase {
        case .downloading: return "モデルをダウンロード中..."
        case .loading: return "モデルを読み込み中..."
        }
    }
}
