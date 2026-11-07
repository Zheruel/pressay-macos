# Third-party notices

Pressay source code is MIT-licensed. The following components and downloaded assets keep their own licenses.

## transcribe.cpp

- Project: [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)
- Use: native ggml speech runtime (Metal on Mac, CPU on Windows and Linux)
- License: MIT
- Local license copy: [`Runtime/Sources/CNativeASR/vendor/TRANSCRIBE_LICENSE`](Runtime/Sources/CNativeASR/vendor/TRANSCRIBE_LICENSE)

`scripts/build-portable-runtime.py` builds transcribe.cpp at commit `41738b58b305c08bdecf5379dccdc19a0f7c3b05`, applies the checked-in patch in `scripts/patches/`, and copies the transcribe.cpp and ggml license files into the bundled runtime.

## Sparkle

- Project: [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle), `2.10.1`, MIT

Sparkle is not bundled in the app. The release workflow runs its `generate_appcast` tool so that Pressay 1.x installs can update to the current release.

## Mac speech worker

- [Oruk-AI/orukeet](https://github.com/Oruk-AI/orukeet), optimized Metal runtime `0.1.1`: wraps NVIDIA NeMo-Speech.cpp (Apache-2.0), ggml (MIT) and SentencePiece (Apache-2.0). The build verifies the release archive SHA-256 and includes its license directory in the app.
- [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), commit `19f2296420c875b4f782825c5f5fcb554ed87e38`: MIT. Swift Qwen backbone and audio processing used by Mega-ASR.
- [Blaizzy/mlx-audio](https://github.com/Blaizzy/mlx-audio), `0.6.1`: MIT. Mega-ASR router and reversible LoRA application ported in `Runtime/Sources/PressayASRWorker/MegaASR.swift`.
- [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) and MLX: MIT. Hugging Face Swift tokenizers and Hub packages: Apache-2.0. Their resolved versions are pinned in `Runtime/Package.resolved`.

Executable runtimes ship inside the signed app; the running app downloads only model data.

## Speech model weights

Model weights are not committed to or redistributed by this repository. Pressay downloads the selected model from Hugging Face on first use.

The five recommended model sources are [Orukeet](https://huggingface.co/oruk/orukeet),
[MOSS Transcribe Diarize](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize),
[Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra),
[Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), and
[Mega-ASR](https://huggingface.co/mlx-community/Mega-ASR-bf16).
Model-card licenses and attribution requirements apply independently of Pressay's code license.

- [Whisper Large V3 Turbo](https://huggingface.co/openai/whisper-large-v3-turbo): base model released under the MIT License. Consult the downloaded GGUF repository's model card for conversion-specific notices.
- [Silero VAD v6.2 GGUF](https://huggingface.co/handy-computer/silero-vad-v6.2-gguf): MIT. Finds speech in meetings; downloaded on the first meeting.
- [Streaming Sortformer 4spk v2.1 GGUF](https://huggingface.co/handy-computer/diar_streaming_sortformer_4spk-v2.1-gguf): NVIDIA speaker diarization model, converted for transcribe.cpp. Tells speakers apart in meetings. Consult the model card for its license.
- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): CC BY 4.0. Copyright and attribution remain with NVIDIA and the model authors. Consult the model card before redistribution.

The model-card terms are authoritative and may change independently of Pressay.

## Dictation earcons

The `Config/Sounds/*.wav` earcons are synthesized by Pressay's own `scripts/generate-earcons.py` and contain no third-party audio. Earlier releases derived the begin/release cues from CC0 recordings by AbdrTar on Freesound ([Recording Start](https://freesound.org/people/AbdrTar/sounds/519985/), [Recording End](https://freesound.org/people/AbdrTar/sounds/519986/)); thanks for those.

## Platform frameworks

On macOS, Pressay uses system frameworks including AppKit, AVFoundation, Core Audio, Accessibility and EventKit. Windows and Linux builds use the system WebView (WebView2, WebKitGTK). These are governed by their platform terms and are not redistributed by this repository.

## Rust and Tauri dependencies

The app uses Tauri 2 and its plugins (MIT/Apache-2.0), CPAL (Apache-2.0), Rubato (MIT), Enigo (MIT) and Arboard (MIT/Apache-2.0). The Rust core uses Tokio, Reqwest, Rusqlite/SQLite, Serde, Regex, SHA-2, Tempfile and UUID under their upstream licenses. Exact versions and sources are recorded in `Cargo.lock` and `apps/desktop/package-lock.json`.

Model weights are downloaded separately and keep their own licenses.
