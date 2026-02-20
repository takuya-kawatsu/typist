import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

private let logger = Logger(subsystem: "com.takuya.Typist", category: "LLM")

enum LLMModelState: Equatable {
    case idle
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

struct LLMModelOption: Identifiable, Hashable {
    let id: String
    let label: String
    let configuration: ModelConfiguration

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: LLMModelOption, rhs: LLMModelOption) -> Bool { lhs.id == rhs.id }

    static let available: [LLMModelOption] = [
        LLMModelOption(id: "qwen3-0.6b", label: "Qwen3-0.6B", configuration: LLMRegistry.qwen3_0_6b_4bit),
        LLMModelOption(id: "qwen3-1.7b", label: "Qwen3-1.7B", configuration: LLMRegistry.qwen3_1_7b_4bit),
        LLMModelOption(id: "qwen3-4b",   label: "Qwen3-4B",   configuration: LLMRegistry.qwen3_4b_4bit),
        LLMModelOption(id: "qwen3-8b",   label: "Qwen3-8B",   configuration: LLMRegistry.qwen3_8b_4bit),
    ]

    static let defaultOption = available.last!

    static func find(byId id: String) -> LLMModelOption {
        available.first { $0.id == id } ?? defaultOption
    }
}

@Observable @MainActor
final class LLMTextCleanupService {
    var state: LLMModelState = .idle
    private(set) var currentModelId: String

    var isReady: Bool { state == .ready }

    private var session: ChatSession?

    private static let userDefaultsKey = "selectedLLMModelId"

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

    init() {
        let savedId = UserDefaults.standard.string(forKey: Self.userDefaultsKey)
        self.currentModelId = savedId ?? LLMModelOption.defaultOption.id
    }

    func loadModel() async {
        guard state == .idle || state.isError else { return }
        await loadConfiguration(LLMModelOption.find(byId: currentModelId).configuration)
    }

    func switchModel(to option: LLMModelOption) async {
        guard option.id != currentModelId || state != .ready else { return }
        currentModelId = option.id
        UserDefaults.standard.set(option.id, forKey: Self.userDefaultsKey)
        session = nil
        state = .idle
        await loadConfiguration(option.configuration)
    }

    private func loadConfiguration(_ configuration: ModelConfiguration) async {
        state = .loading

        do {
            let container = try await loadModelContainer(
                configuration: configuration
            ) { [weak self] progress in
                let fraction = progress.fractionCompleted
                logger.info("Download progress: \(String(format: "%.1f", fraction * 100))%")
                Task { @MainActor in
                    guard let self, fraction < 1.0 else { return }
                    switch self.state {
                    case .loading, .downloading:
                        self.state = .downloading(progress: fraction)
                    default:
                        break
                    }
                }
            }

            state = .loading
            logger.info("Creating ChatSession for \(configuration.name)...")

            session = ChatSession(
                container,
                instructions: Self.systemPrompt,
                generateParameters: GenerateParameters(
                    maxTokens: 512,
                    temperature: 0
                )
            )

            state = .ready
            logger.info("Model ready: \(configuration.name)")
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
