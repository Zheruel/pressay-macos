# Pressay

Pressay is a local-only, hold-to-talk macOS dictation app optimized for composing prompts for AI agents. Hold Right Option, say what you need, and release to insert a polished prompt at the cursor. It records only while the shortcut is held, transcribes on-device, and performs a guarded on-device polish pass when it improves the result.

## Current stack

- macOS 26+, Swift 6.2, SwiftUI/AppKit
- Whisper Large V3 Turbo through Argmax OSS/WhisperKit 1.0.0, with automatic language detection by default (English/Norsk/auto selectable in Settings)
- Strict greedy decoding without timestamps, fallback sampling, or prompt conditioning
- Deterministic vocabulary cleanup followed by guarded Apple Foundation Models polishing only for disfluent speech
- SwiftData for 30-day text history and 7-day audio history

No transcription, prompt, surrounding application text, or telemetry is sent to a server. The ASR packages download model assets from Hugging Face on initial setup; subsequent inference is local.

## Prerequisites

Install the full Xcode release whose toolchain matches your macOS 26 SDK. The Makefile and app build script automatically use `/Applications/Xcode.app`.

```sh
xcodebuild -version
```

## Build and run

```sh
make test
make app
open .build/Pressay.app
```

`make app` creates `.build/Pressay.app`. The build script uses a compatible signing identity when one is available, including the local Pressay development certificate. Otherwise it uses an ad-hoc signature and warns that macOS may ask for permissions again after a rebuild.

Create a drag-to-install disk image with:

```sh
make dmg
open .build/Pressay-*.dmg
```

For stable permissions while developing on one Mac, create the local code-signing identity once with `scripts/create-local-signing-certificate.sh`. It is trusted only on that Mac and cannot be notarized. To share the MVP privately without an Apple Developer membership, create an ad-hoc-signed disk image with `SIGNING_IDENTITY=- make dmg`; the recipient must explicitly approve the app in macOS on first launch.

On first launch, Pressay opens a setup assistant for Microphone, Accessibility, and Input Monitoring. Approval status refreshes automatically, including after returning from System Settings. The local model begins preparing immediately in parallel; its first preparation can take several minutes because assets are downloaded and Core ML specializes them for the machine.

## Vocabulary

Pressay learns how to spell the names and products you dictate. A background pass over your recent transcripts finds recurring mishearings and fixes them automatically — no manual entry needed. Learned rules appear in Settings → Vocabulary, where you can delete any of them; they expire with the 30-day transcript window. Adding a Kimi API key there lets Pressay periodically ask Kimi K3 to review new terms for even sharper fixes; everything works without a key, on-device.

You can also curate terms by hand, one per line:

```text
WhisperKit <= whisper kit
Core ML <= core ml, core em el
myRepository <= my repository
```

Preferred terms feed deterministic casing cleanup and polish-output validation. Vocabulary is deliberately applied after transcription because decoder-level conditioning was less reliable in the calibration corpus.

## Retention

- Ordinary transcript records: 30 days
- Ordinary audio: 7 days
- Corrected or pinned records and audio: retained until deleted
- Surrounding application context: never stored

The runtime intentionally contains one calibrated transcription configuration rather than alternate engines or experimental decoder settings.
