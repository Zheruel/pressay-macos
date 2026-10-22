# Third-party notices

Pressay source code is MIT-licensed. The following components and downloaded assets keep their own licenses.

## transcribe.cpp and Swift bindings

- Project: [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)
- Use: native ggml/Metal speech runtime and vendored Swift wrapper
- License: MIT
- Local license copy: [`Sources/TranscribeCpp/LICENSE`](Sources/TranscribeCpp/LICENSE)

The packaged application downloads the prebuilt `CTranscribe` XCFramework declared in `Package.swift`.

The local worker additionally builds transcribe.cpp at commit `41738b58b305c08bdecf5379dccdc19a0f7c3b05`
with its matching vendored C header. This pinned development runtime is separate from the legacy framework.

## Bundled local speech worker

- [Oruk-AI/orukeet](https://github.com/Oruk-AI/orukeet), optimized Metal runtime `0.1.1`: wraps NVIDIA NeMo-Speech.cpp (Apache-2.0), ggml (MIT) and SentencePiece (Apache-2.0). The build verifies the release archive SHA-256 and includes its license directory in the app.
- [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), commit `19f2296420c875b4f782825c5f5fcb554ed87e38`: MIT. Swift Qwen backbone and audio processing used by Mega-ASR.
- [Blaizzy/mlx-audio](https://github.com/Blaizzy/mlx-audio), `0.6.1`: MIT. Mega-ASR router and reversible LoRA application ported in `Runtime/Sources/PressayASRWorker/MegaASR.swift`.
- [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) and MLX: MIT. Hugging Face Swift tokenizers and Hub packages: Apache-2.0. Their resolved versions are pinned in `Runtime/Package.resolved`.

The app bundles dependency license files under `Contents/Resources/ASRRuntime/licenses` and the Orukeet runtime's own `share/licenses`. Executable runtimes ship inside the signed app; the running app downloads only model data.

## FluidAudio

- Project: [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)
- Use: on-device speaker diarization (LS-EEND) and voice activity detection (Silero) for meetings
- License: Apache-2.0

## Speech model weights

Model weights are not committed to or redistributed by this repository. Pressay downloads the selected model from Hugging Face on first use.

The five recommended model sources are [Orukeet](https://huggingface.co/oruk/orukeet),
[MOSS Transcribe Diarize](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize),
[Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra),
[Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), and
[Mega-ASR](https://huggingface.co/mlx-community/Mega-ASR-bf16).
Model-card licenses and attribution requirements apply independently of Pressay's code license.

- [Whisper Large V3 Turbo](https://huggingface.co/openai/whisper-large-v3-turbo): base model released under the MIT License. Consult the downloaded GGUF repository's model card for conversion-specific notices.
- [Silero VAD Core ML](https://huggingface.co/FluidInference/silero-vad-coreml): MIT. Downloaded on the first meeting.
- [LS-EEND Core ML (AMI)](https://huggingface.co/FluidInference/ls-eend-coreml): MIT. Downloaded on the first meeting that records the call's audio.
- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): CC BY 4.0. Copyright and attribution remain with NVIDIA and the model authors. Consult the model card before redistribution.

The model-card terms are authoritative and may change independently of Pressay.

## Dictation earcons

The `Config/Sounds/*.wav` earcons are synthesized by Pressay's own `scripts/generate-earcons.py` and contain no third-party audio. Earlier releases derived the begin/release cues from CC0 recordings by AbdrTar on Freesound ([Recording Start](https://freesound.org/people/AbdrTar/sounds/519985/), [Recording End](https://freesound.org/people/AbdrTar/sounds/519986/)); thanks for those.

## Apple frameworks

Pressay uses system frameworks including SwiftUI, AppKit, AVFoundation, Accessibility, SwiftData, ServiceManagement, and Foundation Models. Their use is governed by the applicable Apple SDK and platform terms; these frameworks are not redistributed by this repository.
