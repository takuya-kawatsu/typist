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
        あなたは音声入力テキストの校正アシスタントです。
        入力はmacOSの音声認識が出力した生テキストです。

        ## 作業内容

        1. 誤認識の修正
           - カタカナ英語や技術用語の誤認識を正しい表記に復元する（例: エルエルエム→LLM、ローゼット→Ready、エーピーアイ→API、ギットハブ→GitHub）
           - 同音異義語の誤変換を文脈から判断して修正する（例: 体顔→体や顔、関数がえし→関数返し→関数が返し）
           - 誤って結合・分離された単語を修正する
        2. 不要語の除去
           - フィラー（えーと、あのー、まあ、なんか、えっと）を除去
           - 言い直しや繰り返しを整理する
        3. 句読点・構造の整理
           - 適切な位置に句読点（、。）を補う
           - 文の切れ目で改行を入れる
        4. 自然な書き言葉への変換
           - 過度な口語表現を自然な書き言葉に整える
           - ただし、話者の語調（です・ます調、だ・である調）は維持する

        ## 例

        入力: えーとですねエルエムのロードの表示がですねエムが初回に使われるまでローゼットにならないと言う不具合があります
        出力: LLMのロード表示が、初回に使われるまでReadyにならないという不具合があります。

        入力: あのこの関数なんですけどまあ引数がストリングでリターンがインドでなんかオプショナルなんですよね
        出力: この関数は引数がStringで、戻り値がIntのOptionalです。

        入力: 吾輩は猫であるまあ名前はまだないと思ってるんだけどそもそも私は犬かもしれないしなんだろう自分の体顔を見たことがないのでわから
        出力: 吾輩は猫である。名前はまだないと思っているが、そもそも犬かもしれない。自分の体や顔を見たことがないのでわからない。

        ## ルール
        - 校正後のテキストだけを出力すること
        - 説明・注釈・代替案は一切付けない
        - 意味を変えたり情報を追加・削除しない
        """

    func loadModel() async {
        guard state == .idle || state.isError else { return }

        state = .loading

        do {
            let container = try await loadModelContainer(
                configuration: LLMRegistry.qwen3_8b_4bit
            ) { progress in
                let fraction = progress.fractionCompleted
                print("[LLM] Download progress: \(String(format: "%.1f", fraction * 100))%")
                DispatchQueue.main.async {
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
