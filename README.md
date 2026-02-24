# Typist

**Voice-to-text for macOS, powered entirely by on-device AI.**

> **Your data stays on your device. Always.**
>
> Zero network calls. Your voice and text never leave your Mac.
> All speech recognition and text correction run locally on Apple Silicon.
>
> **あなたのデータは、あなたのデバイスの中だけに。**
>
> 外部サーバーへの通信ゼロ。音声もテキストも Mac から一切外に出ません。
> すべての音声認識・テキスト校正は Apple Silicon 上でローカル実行されます。

Hold **Ctrl+Fn**, speak, release — Typist transcribes your speech with [Whisper](https://github.com/ggerganov/whisper.cpp) (large-v3-turbo), refines it with an LLM ([Qwen3](https://github.com/ml-explore/mlx-swift-lm)), and pastes the result into the focused app. All in real time, all on your machine.

## Features

- **Hold-to-dictate (Ctrl+Fn)** — Records while held, transcribes on release
- **Whisper STT** — whisper.cpp (large-v3-turbo, Q5_0) with Metal GPU acceleration and automatic language detection
- **LLM text correction** — Qwen3 (0.6B / 1.7B / 4B / 8B, 4-bit quantized) fixes technical terms, typos, and punctuation
- **Auto text insertion** — Pastes directly into the focused app via Accessibility API; clipboard is auto-restored
- **Menu bar resident** — Runs as a lightweight menu bar app with real-time status icon (idle → recording → processing → done)
- **Switchable LLM models** — Choose from 4 Qwen3 sizes via the menu; selection persists across launches

## How It Works

```
  Hold Ctrl+Fn        Release Ctrl+Fn
       │                     │
       ▼                     ▼
   ┌────────┐  3s partial  ┌──────────┐    ┌──────────┐    ┌──────────┐
   │ Record │─────────────▶│ Whisper  │───▶│ LLM      │───▶│ Paste    │
   │ Audio  │  inference   │ Final    │    │ Correct  │    │ to App   │
   └────────┘              │ STT      │    │ (Qwen3)  │    └──────────┘
                           └──────────┘    └──────────┘
                                 ▲               │
                                 │   skip if     │
                                 └── not ready ──┘
```

All processing stays within the dotted line of your Mac — no cloud, no API keys, no data exfiltration.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  TypistApp (MenuBarExtra)                                │
│  ├─ MenuBarContent           Menu UI & status display    │
│  ├─ OverlayPanel             Floating status overlay     │
│  └─ ModelProgressPanel       Model DL/load progress      │
├──────────────────────────────────────────────────────────┤
│  ViewModel                                               │
│  └─ TypistViewModel          Record → STT → LLM → Paste │
├──────────────────────────────────────────────────────────┤
│  Services                                                │
│  ├─ WhisperService           Whisper recording & inference│
│  │   ├─ WhisperContext       whisper.cpp C API wrapper   │
│  │   ├─ WhisperModelManager  Model DL & cache management │
│  │   └─ AudioSampleBuffer    16kHz resampling buffer     │
│  ├─ LLMTextCleanupService    MLX Qwen3 text correction   │
│  ├─ TextInsertionService     Accessibility text insertion │
│  └─ AudioSessionCoordinator  AVAudioEngine exclusion     │
├──────────────────────────────────────────────────────────┤
│  Utilities                                               │
│  ├─ AppState                 DI container & permissions  │
│  └─ KeyMonitor               Ctrl+Fn global key monitor  │
└──────────────────────────────────────────────────────────┘
```

## Tech Stack

| Area | Technology |
|---|---|
| UI | SwiftUI menu bar app (macOS 15+, `MenuBarExtra`) |
| Speech-to-Text | [whisper.cpp](https://github.com/ggerganov/whisper.cpp) via local SPM package (Metal GPU inference) |
| Text Correction | Qwen3 4-bit (0.6B–8B) via [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) |
| Audio Capture | AVAudioEngine + AVAudioConverter (16kHz mono Float32 resampling) |
| Text Insertion | Accessibility API (CGEvent Cmd+V) + NSPasteboard |
| Global Hotkey | NSEvent (local + global monitor) |
| Build | XcodeGen + Xcode 16 |

## Deep Dive

### Whisper STT Engine

#### Native whisper.cpp Integration

- Local SPM package (`packages/whisper.spm`) builds whisper.cpp C/C++ sources directly
- Metal GPU inference enabled (`GGML_USE_METAL`) with Accelerate framework
- `WhisperContext` wraps the C API (`whisper_full()`) for Swift interop

#### Model Management

- **Model**: `ggml-large-v3-turbo-q5_0.bin` (downloaded from Hugging Face)
- **Cache**: stored in `~/Library/Caches/models/whisper/`; reused from second launch onward
- **Progress**: real-time download tracking via `URLSessionDownloadDelegate`, displayed in `ModelProgressPanel`

#### Audio Preprocessing (AudioSampleBuffer)

- Resamples AVAudioEngine output to **16kHz / mono / Float32** via `AVAudioConverter`
- Bypasses conversion when format already matches (zero-copy)
- Thread-safe accumulation with `NSLock`; `snapshot()` returns a copy for inference

#### Inference Parameter Optimization

```swift
// audio_ctx: limit encoder scope to actual audio length
melColumns = samples.count / 160  // hop_size = 160
alignedCtx = ((melColumns + 100 + 63) / 64) * 64  // Metal alignment (multiple of 64)
audio_ctx  = min(alignedCtx, 1500)  // max 30 seconds
```

- Avoids processing a full 30-second window for short utterances, reducing latency
- `WHISPER_SAMPLING_GREEDY` for deterministic decoding
- Thread count: `activeProcessorCount - 2` (reserves UI and audio threads)

#### Periodic Inference (3-second interval)

During recording, inference runs every 3 seconds on the full sample buffer, updating `partialResult`. Skipped until at least 1 second (16,000 samples) is accumulated. Runs asynchronously via `Task`, with guard against double execution.

### LLM Text Correction Engine

#### Model & Runtime

- **Qwen3** 4-bit quantized models (0.6B / 1.7B / 4B / 8B) via [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) on Apple Silicon
- Switchable from the menu bar; selection persisted in `UserDefaults`
- `ChatSession` for stateful management (cleared per correction)
- `maxTokens: 512`, `temperature: 0` for deterministic output

#### Correction Scope

Whisper output is already high-quality, so the LLM applies **minimal corrections** only:

1. **Technical term restoration** — Converts phonetic katakana back to original alphabet form (e.g. エルエルエム → LLM)
2. **Typo & misrecognition fixes** — Context-aware correction of homophone errors
3. **Punctuation normalization** — Full-width / half-width consistency

No additions, deletions, meaning changes, or tone changes allowed. If no correction is needed, the input is returned as-is.

#### Prompt Design

```
/no_think
{recognized text}
```

- `/no_think` prefix suppresses Qwen3's thinking mode for low-latency response
- Fallback regex removal of `<think>...</think>` blocks if they appear

#### Fallback Strategy

When the LLM is not loaded or encounters an error, Whisper's raw output is used directly (correction skipped).

### Text Insertion Mechanism

#### Accessibility API Route (preferred)

1. Set recognized text on `NSPasteboard`
2. Simulate Cmd+V via `CGEvent` (keyDown + keyUp)
3. Restore original clipboard contents after 0.5 seconds

#### Fallback

Without Accessibility permission, text is copied to clipboard only — user pastes manually with Cmd+V.

## Project Structure

```
Typist/                    (15 files, ~1,540 lines)
├── App/
│   ├── TypistApp.swift             Entry point (MenuBarExtra)
│   └── AppState.swift              DI container & permissions
├── ViewModels/
│   └── TypistViewModel.swift       State machine: Record → STT → LLM → Paste
├── Views/
│   ├── OverlayPanel.swift          Floating status overlay
│   └── ModelProgressPanel.swift    Model DL/load progress panel
├── Services/
│   ├── Whisper/
│   │   ├── WhisperService.swift        Recording & periodic/final inference
│   │   ├── WhisperContext.swift         whisper.cpp C API wrapper
│   │   ├── WhisperModelManager.swift   Model DL & cache management
│   │   └── AudioSampleBuffer.swift     16kHz resampling buffer
│   ├── LLMTextCleanupService.swift     MLX Qwen3 text correction
│   ├── TextInsertionService.swift      Accessibility text insertion
│   └── AudioSessionCoordinator.swift   AVAudioEngine exclusion control
├── Utilities/
│   └── KeyMonitor.swift            Ctrl+Fn global key monitor
├── Resources/
│   ├── Info.plist
│   └── Typist.entitlements
└── packages/
    └── whisper.spm/                whisper.cpp local SPM package
```

## Getting Started

### Requirements

- macOS 15.0+
- Xcode 16+
- XcodeGen 2.38+
- Apple Silicon Mac (required for Metal Whisper inference + MLX LLM inference)

### Build & Run

```sh
# Generate Xcode project, build, and launch
make run

# Release build → install to /Applications
make install
```

### Permissions

| Permission | Purpose | Required |
|---|---|---|
| Microphone | Audio capture | Yes |
| Accessibility | Text insertion via Cmd+V simulation | Recommended (clipboard-only fallback without it) |

## License

[MIT](LICENSE)
