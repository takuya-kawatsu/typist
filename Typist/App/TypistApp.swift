import SwiftUI

@main
struct TypistApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var viewModel = TypistViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
                .environmentObject(viewModel)
        } label: {
            Image(systemName: menuBarIcon)
                .onAppear {
                    // Runs once when the menu bar icon first appears (app launch).
                    // LLM loading and permission requests start in parallel.
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
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: TypistViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // LLM Status
            switch appState.llmService.state {
            case .idle:
                Label("LLM: Not loaded", systemImage: "circle")
            case .downloading(let progress):
                Label("LLM: Downloading \(Int(progress * 100))%", systemImage: "arrow.down.circle")
            case .loading:
                Label("LLM: Loading...", systemImage: "hourglass")
            case .ready:
                Label("LLM: Ready", systemImage: "checkmark.circle.fill")
            case .error(let msg):
                Label("LLM: Error - \(msg)", systemImage: "exclamation.triangle")
            }

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
}
