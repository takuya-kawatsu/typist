import Foundation
import MLX
import MLXLLM
import MLXLMCommon

enum LLMModelState: Equatable {
    case idle
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

@MainActor
final class LLMTextCleanupService: ObservableObject {
    @Published var state: LLMModelState = .idle

    var isReady: Bool { state == .ready }

    private var session: ChatSession?

    private static let systemPrompt = """
        You are a Japanese text cleanup assistant for a voice input app.
        The input is raw Japanese speech recognition output and may contain:
        - Misrecognized words or homophones
        - Filler words (えーと、あのー、まあ、etc.)
        - Incomplete sentences or repeated words
        - Missing or incorrect punctuation

        Your task:
        1. Correct obvious speech recognition errors based on context
        2. Remove filler words and verbal tics
        3. Fix punctuation and sentence structure
        4. Keep the original meaning and intent intact

        Rules:
        - Output ONLY the cleaned-up Japanese text, nothing else
        - Do not add explanations, notes, or alternatives
        - Do not translate — keep everything in Japanese
        - Preserve the speaker's tone and formality level
        """

    func loadModel() async {
        guard state == .idle || state.isError else { return }

        state = .loading

        do {
            let container = try await loadModelContainer(
                configuration: LLMRegistry.qwen3_4b_4bit
            ) { progress in
                Task { @MainActor in
                    let fraction = progress.fractionCompleted
                    // Only show download progress when an actual download is happening
                    // (fraction < 1.0 means files are still being fetched)
                    if fraction < 1.0 {
                        self.state = .downloading(progress: fraction)
                    }
                }
            }

            state = .loading

            session = ChatSession(
                container,
                instructions: Self.systemPrompt,
                generateParameters: GenerateParameters(
                    maxTokens: 512,
                    temperature: 0
                )
            )

            state = .ready
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func cleanupText(_ text: String) async throws -> String {
        guard let session else {
            throw LLMCleanupError.modelNotReady
        }

        await session.clear()

        let prompt = "/no_think\n\(text)"
        let response = try await session.respond(to: prompt)

        return stripThinkingBlock(response).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripThinkingBlock(_ text: String) -> String {
        // Remove <think>...</think> blocks (including multiline)
        let pattern = #"<think>[\s\S]*?</think>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}

private extension LLMModelState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

enum LLMCleanupError: LocalizedError {
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "LLM model is not loaded yet."
        }
    }
}
