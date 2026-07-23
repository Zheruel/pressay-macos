<p align="center">
  <img src="Config/PressayIconSource.png" width="132" alt="Pressay app icon">
</p>

<h1 align="center">Pressay</h1>

<p align="center">
  <strong>Quality-first voice dictation for AI prompts on macOS.</strong><br>
  Hold. Speak. Release. Your words appear at the cursor.
</p>

<p align="center">
  <a href="https://github.com/Zheruel/pressay-macos/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Zheruel/pressay-macos/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-111827?logo=apple&logoColor=white">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-7C3AED"></a>
</p>

Pressay is a native, hold-to-talk dictation app built for people who communicate with coding agents all day. Standard dictation records only while a shortcut is held, transcribes locally on Apple Silicon, cleans up predictable speech artifacts, and inserts the result into the field that was focused when recording began.

It is deliberately not an always-listening assistant. There is no account, telemetry, subscription, or cloud transcription.

> [!IMPORTANT]
> Pressay 1.1 targets Apple Silicon Macs running macOS 26 or newer. Shared builds are not notarized yet, so building from source is the most reliable installation path.

## Why Pressay

- **Quality first.** Whisper Large V3 Turbo is the calibrated default; language can be fixed for more reliable short clips.
- **Fast local inference.** `transcribe.cpp` runs GGUF models through ggml and Metal, with the model and Metal pipeline warmed before the first dictation.
- **Optional structure.** A Structured Dictation toggle adds punctuation, paragraphs, and bullet lists to longer dictations — deterministically, on-device.
- **Cursor-first UX.** A clipboard-preserving synthetic paste handles native, web, and Electron editors; direct Accessibility replacement is the fallback.
- **Learns your vocabulary.** A curated coding glossary, user rules, and local phonetic learning preserve repository names, products, acronyms, and casing.
- **Private by default.** Microphone audio never leaves the Mac. Standard dictation text stays local. No captured application context is retained.

## How it works

<p align="center">
  <img src="docs/assets/architecture.svg" width="100%" alt="Pressay architecture: audio is recorded, transcribed, cleaned and inserted locally; an optional prompt shortcut sends only cleaned text to Kimi">
</p>

| Shortcut | Default | Result | Network |
| --- | --- | --- | --- |
| Dictate | Right Option | Faithful transcript with deterministic cleanup | None after model download |
| Escape | Escape while recording | Cancels without inserting | None |

The hold key is configurable. Pressay captures the destination before its nonactivating overlay appears, so the result returns to the right app and selection.

## Structured Dictation

Longer dictations read better with sentences, paragraphs, and lists. The **Structured dictation** toggle in Settings applies a deterministic structuring pass after the normal cleanup:

- Repairs missing terminal punctuation on near-punctuationless transcripts.
- Splits sentences with abbreviation and identifier guards (`e.g.`, `node.js`, `3.5` never split).
- Turns spoken enumerations ("first… second… finally…") into `-` bullet lists.
- Breaks paragraphs at discourse markers ("also", "by the way", "moving on") and caps paragraph length.

It never reorders, adds, or removes the words you spoke — the spoken ordinal markers of a list are the only thing it drops — and it never touches short dictations or terminal apps. Everything runs on-device with zero added latency; the toggle is off by default.

## The configuration we ship

Pressay has one quality-first default instead of exposing a wall of decoder knobs:

| Layer | Shipping choice | Why |
| --- | --- | --- |
| Audio | Segmented `AVAudioEngine` capture, 16 kHz mono resampling, conservative edge trimming | Handles Bluetooth/device changes without clipping first or last words |
| ASR | Whisper Large V3 Turbo Q8 GGUF via `transcribe.cpp` | Best transcript quality on the development corpus with much lower latency than the previous WhisperKit path |
| Language | Automatic by default; fixed language available | Automatic is flexible; fixing a language skips detection and helps short clips |
| Cleanup | Deterministic text and vocabulary pipeline | Predictable, quick, and preserves protected tokens |
| Structure | Optional deterministic structuring pass | Readability without an LLM rewriting what was said |
| Fast alternative | Parakeet TDT 0.6B v3 F16 | Near-instant on long clips; weaker on very short fragments in our testing |

### ASR latency

The chart below replays the same two real recordings through every engine shown. Lower is better.

<p align="center">
  <img src="docs/assets/asr-latency.svg" width="100%" alt="ASR latency comparison on shared 6.09 and 35.89 second recordings">
</p>

On the 35.89-second shared clip, Whisper V3 Turbo through `transcribe.cpp` finished in **0.765 s**, versus **1.569 s** for the previous WhisperKit path. Parakeet v3 finished in **0.215 s**, but speed alone does not make it the default.

### Why normal dictation does not use an LLM

We replayed 31 real dictations through four guarded on-device language-model prompt variants. Even the best variant changed a protected token on 2 of 31 clips. For standard dictation, that is the wrong failure mode.

<p align="center">
  <img src="docs/assets/polish-safety.svg" width="100%" alt="Protected-token validator pass rate for four on-device language model cleanup variants">
</p>

Pressay therefore keeps the whole dictation path deterministic — including the optional structuring pass, which only adds punctuation, paragraph breaks, and bullets. Read the [benchmark notes](docs/benchmarks.md) for the corpus, method, limitations, and sanitized data.

## Privacy model

| Data | Standard dictation | Optional Kimi features | Retention |
| --- | --- | --- | --- |
| Microphone audio | Processed locally | Never sent | 7 days by default |
| Transcript | Stored locally | Never sent | 30 days by default |
| Vocabulary candidates | Learned locally | Periodic review may send candidate terms and short transcript excerpts | Local learned rules follow history retention |
| Text around the cursor | Read transiently during Accessibility target capture | Never sent | Never stored |
| Telemetry or analytics | None | None | Never collected |

The first model download comes from Hugging Face. A Kimi API key is optional, stored in the macOS login keychain, and only enables the explicitly labeled cloud features. Pressay remains fully useful without it.

Pinned or corrected history records are retained until you delete them. Delete history from the full app window at any time.

## Install from source

### Requirements

- Apple Silicon Mac
- macOS 26+
- Xcode 26+ with the macOS 26 SDK
- Around 2 GB of free space for the default model and build artifacts

```bash
git clone https://github.com/Zheruel/pressay-macos.git
cd pressay-macos
make test
make app
open .build/Pressay.app
```

On first launch, the setup assistant requests:

1. Microphone access — record while a hold key is pressed.
2. Accessibility — insert the finished text into the focused field.
3. Input Monitoring — observe the global hold shortcut.

The first launch also downloads and warms the selected speech model. Later transcription is offline.

To install the current build in `/Applications`:

```bash
make install
```

To create a drag-to-install disk image:

```bash
make dmg
open .build/Pressay-*.dmg
```

### Signing without a paid Apple Developer account

The build script uses a compatible signing identity when one is present and otherwise applies an ad-hoc signature. Ad-hoc builds work for local development, but macOS may ask for permissions again after the app changes.

For stable permissions on one development Mac, create the local certificate once:

```bash
./scripts/create-local-signing-certificate.sh
make install
```

That certificate is trusted only on that Mac and cannot produce a notarized public release. Friends testing an ad-hoc build must explicitly approve it in Privacy & Security on first launch.

## Vocabulary

Pressay ships with a curated vocabulary for coding agents and team communication. It also learns phonetic corrections from recent dictations and applies them deterministically after ASR.

Add custom entries in **Settings → Dictionary**, one per line:

```text
WhisperKit <= whisper kit
Core ML <= core ml, core em el
myRepository <= my repository
```

The preferred spelling appears on the left; comma-separated forms on the right are corrected to it. Learned rules are visible and removable. Optional Kimi review only accepts corrections that map back to trusted vocabulary anchors.

## Project layout

```text
Sources/
├── PressayApp/             SwiftUI/AppKit app, permissions, audio, insertion
├── PressayCore/            Domain types, cleanup, vocabulary, retention
├── PressayTranscription/   transcribe.cpp-backed ASR
├── PressayPostProcessing/  Experimental on-device benchmark module
├── PressayBench/           Corpus replay and tuning CLI
└── TranscribeCpp/            Vendored Swift wrapper for the native runtime
Tests/PressayCoreTests/      Deterministic pipeline tests
Config/                       App metadata, icons, entitlements, and earcons
scripts/                      Build, install, signing, and DMG tooling
```

All modules and targets use the `Pressay` name. The bundle identifier and keychain service intentionally remain `dev.localflow.app` — they anchor macOS permission grants and stored data from earlier builds.

## Development

```bash
make build
make test
make app
```

CI runs the test suite and a full bundle build (assembly, ad-hoc signing, `codesign --verify`) on every pull request. Pushing a `vX.Y.Z` tag that matches the `Config/Info.plist` version triggers the release workflow, which publishes the DMG as a GitHub release.

`PressayBench` can replay a private calibration manifest without checking audio or transcripts into Git:

```bash
swift run PressayBench manifest-from-audio --manifest /path/to/manifest.json
swift run PressayBench asr --manifest /path/to/manifest.json
swift run PressayBench structure --manifest /path/to/manifest.json
swift run PressayBench tune-eval --timeline /path/to/timeline.json
```

Keep benchmark audio, transcripts, API keys, and generated results outside the repository. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Known limitations

- macOS 26+ and Apple Silicon only.
- Meeting transcription, diarization, always-listening mode, mobile, Windows, and cloud ASR are out of scope.
- Insertion depends on Accessibility behavior in the target app. Pressay preserves the clipboard and falls back cleanly, but custom editors can still behave differently.
- Accuracy varies with microphones, accents, background noise, and domain vocabulary. Review critical text before executing destructive agent actions.
- Public notarized binaries are not available yet.

## Acknowledgements

- [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) for a unified ggml/Metal speech runtime.
- [OpenAI Whisper Large V3 Turbo](https://huggingface.co/openai/whisper-large-v3-turbo) and [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) for the speech models.
- [Freesound](https://freesound.org/) contributor AbdrTar for the CC0 recording cues from which Pressay's earcons are derived.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for licensing details.

## License

Pressay source code is released under the [MIT License](LICENSE). Downloaded model weights and third-party components remain subject to their own licenses.
