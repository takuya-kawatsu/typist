import SwiftUI

@main
struct TypistApp: App {
    @State private var appState = AppState()
    @State private var viewModel: TypistViewModel?

    var body: some Scene {
        MenuBarExtra {
            if let viewModel {
                MenuBarContent()
                    .environment(appState)
                    .environment(viewModel)
            }
        } label: {
            Image(systemName: menuBarIcon)
                .task {
                    if viewModel == nil {
                        viewModel = TypistViewModel(appState: appState)
                        appState.bootstrap()
                    }
                }
        }
    }

    private var menuBarIcon: String {
        guard let viewModel else { return "keyboard" }
        switch viewModel.state {
        case .idle:
            return "keyboard"
        case .recording:
            return "mic.fill"
        case .processing:
            return "brain"
        case .done:
            return "checkmark.circle.fill"
        }
    }
}

// MARK: - Menu Content

struct MenuBarContent: View {
    @Environment(AppState.self) var appState
    @Environment(TypistViewModel.self) var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Whisper STT Status
            whisperStatusView

            // LLM Status
            llmStatusView

            Divider()

            // Accessibility status
            if appState.textInsertion.isAccessibilityGranted {
                Label("Accessibility: Granted", systemImage: "lock.open")
            } else {
                Label("Accessibility: Not granted", systemImage: "lock")
                Button("Grant Accessibility...") {
                    appState.textInsertion.requestAccessibility()
                }
            }

            Divider()

            Text("Ctrl+Fn to dictate")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Built at: \(buildDateString)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }

    @ViewBuilder
    private var whisperStatusView: some View {
        switch appState.whisperModelManager.state {
        case .idle:
            Label("Whisper: Not loaded", systemImage: "circle")
        case .downloading(let progress):
            Label("Whisper: Downloading \(Int(progress * 100))%", systemImage: "arrow.down.circle")
        case .loading:
            Label("Whisper: Loading...", systemImage: "hourglass")
        case .ready:
            Label("Whisper: Ready", systemImage: "checkmark.circle.fill")
        case .error(let msg):
            Label("Whisper: Error - \(msg)", systemImage: "exclamation.triangle")
        }
    }

    private var buildDateString: String {
        guard let executablePath = Bundle.main.executablePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executablePath),
              let creationDate = attributes[.creationDate] as? Date else {
            return "Unknown"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: creationDate)
    }

    @ViewBuilder
    private var llmStatusView: some View {
        let currentLabel = LLMModelOption.find(byId: appState.llmService.currentModelId).label

        switch appState.llmService.state {
        case .idle:
            Label("LLM: Not loaded", systemImage: "circle")
        case .downloading(let progress):
            Label("LLM: Downloading \(currentLabel) \(Int(progress * 100))%", systemImage: "arrow.down.circle")
        case .loading:
            Label("LLM: Loading \(currentLabel)...", systemImage: "hourglass")
        case .ready:
            Label("LLM: \(currentLabel) Ready", systemImage: "checkmark.circle.fill")
        case .error(let msg):
            Label("LLM: Error - \(msg)", systemImage: "exclamation.triangle")
        }

        Toggle("LLM Correction", isOn: Binding(
            get: { appState.llmService.isEnabled },
            set: { appState.llmService.isEnabled = $0 }
        ))

        Menu("Model: \(currentLabel)") {
            ForEach(LLMModelOption.available) { option in
                Button {
                    Task { await appState.llmService.switchModel(to: option) }
                } label: {
                    if option.id == appState.llmService.currentModelId {
                        Text("\(option.label) \u{2714}")
                    } else {
                        Text(option.label)
                    }
                }
                .disabled(option.id == appState.llmService.currentModelId && appState.llmService.state == .ready)
            }
        }
        .disabled(!appState.llmService.isEnabled)
    }
}
