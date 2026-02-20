import SwiftUI

@main
struct TypistApp: App {
    @State private var appState = AppState()
    @State private var viewModel = TypistViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
                .environment(viewModel)
        } label: {
            Image(systemName: menuBarIcon)
                .onAppear {
                    // Runs once when the menu bar icon first appears (app launch).
                    // LLM + Whisper loading and permission requests start in parallel.
                    viewModel.bind(appState: appState)
                    appState.bootstrap()
                }
        }
    }

    private var menuBarIcon: String {
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
    }
}
