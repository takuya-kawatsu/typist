# Typist

声でテキスト入力する macOS メニューバーアプリ。Ctrl+Fn を押しながら話すと、Whisper (large-v3-turbo) で高精度にテキスト化し、LLM (Qwen3) で校正したうえで、フォーカス中のアプリにテキストを自動挿入する。

全処理をオンデバイスで完結し、外部サーバーへの通信は一切発生しない（初回のモデルダウンロードを除く）。

## 主な機能

- **Ctrl+Fn 長押しでディクテーション** — キーを押している間だけ録音し、離すと即座にテキスト変換
- **Whisper STT** — whisper.cpp (large-v3-turbo, Q5_0) による高精度なオンデバイス音声認識。言語自動判別
- **LLM テキスト校正** — Qwen3 (0.6B / 1.7B / 4B / 8B、4bit量子化) による音声認識結果の軽微な校正。技術用語のアルファベット化、誤字修正、句読点調整
- **自動テキスト挿入** — Accessibility API で Cmd+V をシミュレーションし、フォーカス中のアプリに直接テキストを貼り付け。クリップボードの内容は自動復元
- **メニューバー常駐** — `LSUIElement` でDockに表示せず、メニューバーアイコンのみで動作。アイコンが状態 (idle / recording / processing / done) をリアルタイム表示
- **LLM モデル切替** — メニューからQwen3の4サイズを自由に切替可能。選択は `UserDefaults` で永続化

## 技術スタック

| 領域 | 技術 |
|---|---|
| UI | SwiftUI メニューバー (macOS 15+, `MenuBarExtra`) |
| 音声認識 (STT) | [whisper.cpp](https://github.com/ggerganov/whisper.cpp) via ローカル SPM パッケージ (Metal GPU推論) |
| テキスト校正 (LLM) | Qwen3 4bit (0.6B〜8B) via [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) v2.29+ |
| 音声キャプチャ | AVAudioEngine + AVAudioConverter (16kHz mono Float32 リサンプリング) |
| テキスト挿入 | Accessibility API (CGEvent Cmd+V) + NSPasteboard |
| グローバルキー監視 | NSEvent (local + global monitor) |
| ビルド | XcodeGen + Xcode 16 |

## アーキテクチャ

```
┌──────────────────────────────────────────────────────────┐
│  TypistApp (MenuBarExtra)                                │
│  ├─ MenuBarContent           メニュー UI・状態表示         │
│  ├─ OverlayPanel             フローティング状態オーバーレイ  │
│  └─ ModelProgressPanel       モデルDL/ロード進捗パネル      │
├──────────────────────────────────────────────────────────┤
│  ViewModel                                               │
│  └─ TypistViewModel          状態遷移・録音→認識→校正→挿入  │
├──────────────────────────────────────────────────────────┤
│  Services                                                │
│  ├─ WhisperService           Whisper 録音・推論制御         │
│  │   ├─ WhisperContext       whisper.cpp C API ラッパー    │
│  │   ├─ WhisperModelManager  モデル DL・キャッシュ管理       │
│  │   └─ AudioSampleBuffer    16kHz リサンプリングバッファ    │
│  ├─ LLMTextCleanupService    MLX Qwen3 テキスト校正        │
│  ├─ TextInsertionService     Accessibility テキスト挿入    │
│  └─ AudioSessionCoordinator  AVAudioEngine 排他制御        │
├──────────────────────────────────────────────────────────┤
│  Utilities                                               │
│  ├─ AppState                 DI コンテナ・権限管理          │
│  └─ KeyMonitor               Ctrl+Fn グローバルキー監視    │
└──────────────────────────────────────────────────────────┘
```

## データ処理パイプライン

```
Ctrl+Fn 長押し
  │
  ▼
KeyMonitor (NSEvent global/local monitor)
  │  isHolding = true
  │
  ▼
TypistViewModel.startRecording()
  │  OverlayPanel 表示 (状態: recording)
  │
  ▼
AudioSessionCoordinator.installTap()
  │  AVAudioEngine → inputNode tap (1024 frames)
  │
  ▼
AudioSampleBuffer.append()
  │  AVAudioConverter で 16kHz mono Float32 にリサンプリング
  │  NSLock で排他制御してサンプル配列に蓄積
  │
  ├──── 3 秒ごとの定期推論 (Timer) ─────┐
  │                                     ▼
  │                          WhisperContext.infer()
  │                            │  専用 serial DispatchQueue で排他実行
  │                            │  audio_ctx を実音声長に最適化
  │                            │  (Metal F16/F32 アライメント考慮)
  │                            ▼
  │                          partialResult → OverlayPanel に表示
  │
  ▼
Ctrl+Fn リリース
  │  isHolding = false
  │
  ▼
TypistViewModel.stopRecordingAndProcess()
  │  OverlayPanel 更新 (状態: processing)
  │
  ▼
WhisperService.stopRecording()
  │  Timer 停止 → inflight 推論を await
  │  tap 除去 → engine 停止
  │  全サンプルで最終推論実行
  │
  ▼
┌─────────────────────────────────────────┐
│  LLM テキスト校正                        │
│  ├─ LLM Ready?                          │
│  │   YES → LLMTextCleanupService        │
│  │         /no_think + 認識テキスト       │
│  │         技術用語補正・誤字修正          │
│  │   NO  → 認識テキストをそのまま使用      │
│  └──────────────────────────────────────┘
  │
  ▼
TextInsertionService.insertText()
  │  ├─ Accessibility あり → クリップボード + Cmd+V シミュレーション
  │  │   └─ 0.5 秒後にクリップボード内容を復元
  │  └─ Accessibility なし → クリップボードにコピーのみ
  │
  ▼
OverlayPanel 更新 (状態: done) → 1.5 秒後に自動消去
```

## Whisper STT エンジン設計

### whisper.cpp ネイティブ統合

- ローカル SPM パッケージ (`packages/whisper.spm`) で whisper.cpp の C/C++ ソースを直接ビルド
- Metal GPU 推論を有効化 (`GGML_USE_METAL`)、Accelerate フレームワーク併用
- `WhisperContext` が C API (`whisper_full()`) を Swift から呼び出すラッパーを提供

### モデル管理

- **モデル**: `ggml-large-v3-turbo-q5_0.bin` (Hugging Face からダウンロード)
- **キャッシュ**: `~/Library/Caches/models/whisper/` に保存、2回目以降はローカルキャッシュを使用
- **ダウンロード進捗**: `URLSessionDownloadDelegate` でリアルタイム追跡、`ModelProgressPanel` に表示

### 音声前処理 (AudioSampleBuffer)

- AVAudioEngine の出力をシステムフォーマットから **16kHz / mono / Float32** に `AVAudioConverter` でリサンプリング
- フォーマットが既に一致する場合はバイパス（ゼロコピー）
- `NSLock` によるスレッドセーフな蓄積。`snapshot()` でコピーを取得

### 推論パラメータ最適化

```swift
// audio_ctx: 実音声長に合わせてエンコーダ処理範囲を制限
melColumns = samples.count / 160  // hop_size = 160
alignedCtx = ((melColumns + 100 + 63) / 64) * 64  // Metal アライメント (64の倍数)
audio_ctx  = min(alignedCtx, 1500)  // 最大 30 秒
```

- 短い音声でも 30 秒分のエンコーダ処理を回避し、レイテンシを削減
- `WHISPER_SAMPLING_GREEDY` で決定論的デコード
- スレッド数: `activeProcessorCount - 2` (UIスレッドとオーディオスレッドを確保)

### 定期推論 (3 秒間隔)

録音中に 3 秒ごとに蓄積サンプル全体で推論を実行し、`partialResult` を更新。最低 1 秒 (16,000 サンプル) 以上蓄積されるまでスキップ。推論は `Task` で非同期実行し、前回の推論が完了するまで次をスキップ（二重実行防止）。

## LLM テキスト校正エンジン

### モデルとランタイム

- **Qwen3** の 4bit 量子化モデル (0.6B / 1.7B / 4B / 8B) を [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) で Apple Silicon 上にローカル推論
- メニューからモデルを自由に切替可能、選択は `UserDefaults` で永続化
- `ChatSession` によるステートフルセッション管理（校正ごとにセッションクリア）
- `maxTokens: 512`, `temperature: 0` で決定論的な校正結果を生成

### 校正タスク設計

Whisper の出力は既に高精度なため、LLM には**最小限の校正**のみを指示：

1. **技術用語のアルファベット化** — カタカナ音写された英語技術用語を元表記に復元（例: エルエルエム→LLM）
2. **誤字・脱字の修正** — 同音異義語の誤変換を文脈判断で修正
3. **句読点の微調整** — 全角・半角の統一

文の追加・削除・意味変更・語調変更は禁止。修正不要なら入力をそのまま出力。

### プロンプト設計

```
/no_think
{認識テキスト}
```

- `/no_think` プレフィックスで Qwen3 の思考モードを抑制し、低レイテンシ応答を実現
- `<think>...</think>` ブロックが出力された場合は正規表現で除去するフォールバック処理

### フォールバック戦略

LLM 未ロード時やエラー時は Whisper の認識テキストをそのまま使用（校正をスキップ）。

## テキスト挿入メカニズム

### Accessibility API ルート（推奨）

1. `NSPasteboard` に認識テキストを設定
2. `CGEvent` で Cmd+V をシミュレーション（keyDown + keyUp）
3. 0.5 秒後に元のクリップボード内容を復元

### フォールバック

Accessibility 権限がない場合はクリップボードにコピーのみ。ユーザーが手動で Cmd+V を実行。

## プロジェクト構成

```
Typist/                    (15 ファイル, ~1,540 行)
├── App/
│   ├── TypistApp.swift             エントリポイント (MenuBarExtra)
│   └── AppState.swift              DI コンテナ・権限管理
├── ViewModels/
│   └── TypistViewModel.swift       状態遷移・録音→認識→校正→挿入
├── Views/
│   ├── OverlayPanel.swift          フローティング状態オーバーレイ
│   └── ModelProgressPanel.swift    モデル DL/ロード進捗パネル
├── Services/
│   ├── Whisper/
│   │   ├── WhisperService.swift        録音・定期推論・最終推論
│   │   ├── WhisperContext.swift         whisper.cpp C API ラッパー
│   │   ├── WhisperModelManager.swift   モデル DL・キャッシュ管理
│   │   └── AudioSampleBuffer.swift     16kHz リサンプリングバッファ
│   ├── LLMTextCleanupService.swift     MLX Qwen3 テキスト校正
│   ├── TextInsertionService.swift      Accessibility テキスト挿入
│   └── AudioSessionCoordinator.swift   AVAudioEngine 排他制御
├── Utilities/
│   └── KeyMonitor.swift            Ctrl+Fn グローバルキー監視
├── Resources/
│   ├── Info.plist
│   └── Typist.entitlements
└── packages/
    └── whisper.spm/                whisper.cpp ローカル SPM パッケージ
```

## 動作要件

- macOS 15.0+
- Xcode 16+
- XcodeGen 2.38+
- Apple Silicon (Whisper Metal 推論 + MLX LLM 推論に必要)

## ビルド・実行

```sh
# XcodeGen でプロジェクト生成 → ビルド → 起動
make run

# Release ビルド → /Applications にインストール
make install
```

## 権限

| 権限 | 用途 | 必須 |
|---|---|---|
| マイクアクセス | 音声キャプチャ | 必須 |
| アクセシビリティ | Cmd+V シミュレーションによるテキスト挿入 | 推奨（なくてもクリップボードコピーで動作） |
