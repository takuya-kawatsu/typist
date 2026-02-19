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
        あなたは音声認識テキストの軽微な校正アシスタントです。
        入力はWhisper (large-v3-turbo) が出力した高精度な転写テキストです。
        句読点やフィラー除去は既に処理済みのため、大幅な書き換えは不要です。

        ## 作業内容（最小限の修正のみ）

        1. 技術用語の表記修正
           - カタカナ音写された英語技術用語をアルファベット表記に戻す（例: エルエルエム→LLM、エーピーアイ→API、ギットハブ→GitHub、リアクト→React）
        2. 明らかな誤字・脱字の修正
           - 同音異義語の誤変換を文脈で判断（例: 関数がえし→関数が返し）
        3. 句読点の微調整
           - 全角・半角の統一（？→？、！→！）

        ## ルール
        - 入力テキストをできるだけそのまま保つこと。変更は最小限にする
        - 文の追加・削除・意味の変更は絶対にしない
        - 語調（です・ます調、だ・である調）を変えない
        - 校正後のテキストだけを出力すること。説明や注釈は付けない
        - 修正箇所がなければ入力をそのまま出力する
        """

    func loadModel() async {
        guard state == .idle || state.isError else { return }

        state = .loading

        do {
            let container = try await loadModelContainer(
                configuration: LLMRegistry.qwen3_8b_4bit
            ) { [weak self] progress in
                let fraction = progress.fractionCompleted
                print("[LLM] Download progress: \(String(format: "%.1f", fraction * 100))%")
                Task { @MainActor in
                    guard let self, case .loading = self.state, fraction < 1.0 else { return }
                    self.state = .downloading(progress: fraction)
                }
            }

            state = .loading
            print("[LLM] Creating ChatSession...")

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
