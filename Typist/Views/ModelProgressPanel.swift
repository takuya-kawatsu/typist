import Cocoa
import SwiftUI

@Observable @MainActor
final class ModelProgressPanel {
    var phases: [ModelProgressPhase] = []

    private var panel: NSPanel?
    private var observationTask: Task<Void, Never>?

    private let panelWidth: CGFloat = 340
    private let panelHeight: CGFloat = 120

    func observe(whisperModelManager: WhisperModelManager, llmService: LLMTextCleanupService) {
        observationTask?.cancel()

        // Initial update
        updatePhases(whisperState: whisperModelManager.state, llmState: llmService.state)

        observationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await withCheckedContinuation { c in
                    withObservationTracking {
                        _ = whisperModelManager.state
                        _ = llmService.state
                    } onChange: { c.resume() }
                }
                self.updatePhases(whisperState: whisperModelManager.state, llmState: llmService.state)
            }
        }
    }

    private func updatePhases(whisperState: WhisperModelState, llmState: LLMModelState) {
        let whisperPhase = phase(from: whisperState, label: "Whisper")
        let llmPhase = phase(from: llmState, label: "LLM")
        phases = [whisperPhase, llmPhase].compactMap { $0 }

        if phases.isEmpty {
            hide()
        } else {
            ensurePanel()
            positionPanel()
            panel?.orderFrontRegardless()
        }
    }

    private func phase(from whisperState: WhisperModelState, label: String) -> ModelProgressPhase? {
        switch whisperState {
        case .downloading(let progress):
            return .downloading(label: label, progress: progress)
        case .loading:
            return .loading(label: label)
        case .idle, .ready, .error:
            return nil
        }
    }

    private func phase(from llmState: LLMModelState, label: String) -> ModelProgressPhase? {
        switch llmState {
        case .downloading(let progress):
            return .downloading(label: label, progress: progress)
        case .loading:
            return .loading(label: label)
        case .idle, .ready, .error:
            return nil
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .windowBackgroundColor
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.title = "Typist"
        p.isMovableByWindowBackground = true

        let hostingView = NSHostingView(rootView: ModelProgressContent(model: self))
        hostingView.frame = p.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hostingView)

        panel = p
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
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

enum ModelProgressPhase: Identifiable {
    case downloading(label: String, progress: Double)
    case loading(label: String)

    var id: String { label }

    var label: String {
        switch self {
        case .downloading(let label, _): return label
        case .loading(let label): return label
        }
    }
}

// MARK: - SwiftUI Content

private struct ModelProgressContent: View {
    var model: ModelProgressPanel

    var body: some View {
        VStack(spacing: 12) {
            ForEach(model.phases) { phase in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: phase))
                        .foregroundStyle(.secondary)
                    Text(title(for: phase))
                        .font(.headline)
                }

                switch phase {
                case .downloading(_, let progress):
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
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private func iconName(for phase: ModelProgressPhase) -> String {
        switch phase {
        case .downloading: return "arrow.down.circle"
        case .loading: return "cpu"
        }
    }

    private func title(for phase: ModelProgressPhase) -> String {
        switch phase {
        case .downloading(let label, _): return "\(label)モデルをダウンロード中..."
        case .loading(let label): return "\(label)モデルを読み込み中..."
        }
    }
}
