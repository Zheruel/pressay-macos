# Third-party notices

Pressay source code is MIT-licensed. The following components and downloaded assets keep their own licenses.

## transcribe.cpp and Swift bindings

- Project: [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)
- Use: native ggml/Metal speech runtime and vendored Swift wrapper
- License: MIT
- Local license copy: [`Sources/TranscribeCpp/LICENSE`](Sources/TranscribeCpp/LICENSE)

The packaged application downloads the prebuilt `CTranscribe` XCFramework declared in `Package.swift`.

## Speech model weights

Model weights are not committed to or redistributed by this repository. Pressay downloads the selected model from Hugging Face on first use.

- [Whisper Large V3 Turbo](https://huggingface.co/openai/whisper-large-v3-turbo): base model released under the MIT License. Consult the downloaded GGUF repository's model card for conversion-specific notices.
- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): CC BY 4.0. Copyright and attribution remain with NVIDIA and the model authors. Consult the model card before redistribution.

The model-card terms are authoritative and may change independently of Pressay.

## Dictation earcons

The `Config/Sounds/*.wav` earcons are synthesized by Pressay's own `scripts/generate-earcons.py` and contain no third-party audio. Earlier releases derived the begin/release cues from CC0 recordings by AbdrTar on Freesound ([Recording Start](https://freesound.org/people/AbdrTar/sounds/519985/), [Recording End](https://freesound.org/people/AbdrTar/sounds/519986/)); thanks for those.

## Apple frameworks

Pressay uses system frameworks including SwiftUI, AppKit, AVFoundation, Accessibility, SwiftData, ServiceManagement, and Foundation Models. Their use is governed by the applicable Apple SDK and platform terms; these frameworks are not redistributed by this repository.
