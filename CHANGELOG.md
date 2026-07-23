# Changelog

All notable changes to Pressay are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-07-23

### Added

- Structured Dictation: deterministically adds punctuation, sentence capitalization, bullet lists for spoken enumerations, and paragraph breaks to longer dictations — on-device, with no LLM and no added latency. On by default (corpus-validated as word-preserving); switch it off in Settings.
- A vocabulary-tuner evaluation harness (`PressayBench tune-eval`) that replays the corpus through the legacy matcher, the fixed matcher, and the optional Kimi judge so their precision can be compared on real data.
- `PressayBench structure` and `manifest-from-audio` subcommands for replaying the audio corpus through the structuring candidates with a transcription cache.

### Changed

- The automatic vocabulary tuner is far more conservative: its English stop list grew from ~1,100 to ~13,800 words, fuzzy phonetic matches now require recurrence proportional to their distance, and the per-dictation learning path only accepts exact phonetic matches. This stops it from rewriting ordinary words (previously learned false positives like "mix → macOS" and "correction → Markdown" are purged by a one-time migration; correct Kimi-reviewed rules are kept).
- Learned words now persist while you keep using them: the daily pass refreshes a rule whenever its mishearing reappears, and only rules unused for ~3 months expire. Previously, deterministic rules silently vanished with the 30-day transcript window.
- The Kimi vocabulary judge only receives candidates within phonetic reach of a known term — a ~60% cut in judge tokens with no measured loss of true corrections.
- `CLAUDE.md` and `AGENTS.md` joined the curated vocabulary so mishearings like "CloudMD" resolve to the right term.

### Fixed

- Dictation history now actually persists across launches. The history database previously used SwiftData's shared `default.store` in Application Support, where a name collision with another app's store made every launch silently fall back to in-memory history — losing records, and with them the vocabulary tuner's learning window, on every restart. The store now lives at `Application Support/Pressay/History.store`.

### Removed

- Vibe Mode. The second hold key, the Kimi rewrite step, and the model picker are gone; dictated text is never sent to the cloud. The Kimi API key now powers only the optional vocabulary review.

## [1.1.0] - 2026-07-19

### Added

- Vibe Mode: a separate hold-to-talk workflow that turns natural dictation into a first-person work order for coding agents.
- A single Vibe Mode model picker with Kimi K3, K2.7, and K2.7 HighSpeed; K3 is the calibrated default.
- Amber-to-pink **Vibing…** feedback while the deliberate cloud rewrite runs.

### Changed

- Renamed every Swift package product, target, source module, and test target from LocalFlow to Pressay.
- Migrated models, audio, history, defaults, and keychain access without changing the bundle identity that anchors macOS permissions.
- Updated the Kimi instruction from generic prose cleanup to a calibrated agent-brief contract.

### Fixed

- Preserved existing model and audio data during the rename without triggering permission prompts.
- Addressed review findings across the rename, migration, model picker, and Vibe Mode paths.

## [1.0.0] - 2026-07-19

### Added

- Native SwiftUI/AppKit menu-bar and Dock app for macOS 26+.
- Hold-to-talk dictation with configurable global shortcuts and a nonactivating voice overlay.
- Whisper Large V3 Turbo and Parakeet TDT 0.6B v3 through `transcribe.cpp` and Metal.
- Deterministic cleanup, curated coding vocabulary, per-dictation phonetic learning, and optional Kimi vocabulary review.
- Separate prompt-polish shortcut using Kimi's coding model.
- Accessibility-first insertion with clipboard-preserving paste fallback.
- SwiftData history with local retention, correction, pinning, retry, and deletion.
- Calibration and replay tooling through `PressayBench`.
- Bluetooth and audio-device-change resilient segmented recording.

### Changed

- Replaced the previous WhisperKit transcription path with the faster GGUF runtime.
- Removed automatic on-device LLM rewriting from standard dictation after protected-token testing found meaning-changing edits.

[1.0.0]: https://github.com/Zheruel/pressay-macos/releases/tag/v1.0.0
[1.1.0]: https://github.com/Zheruel/pressay-macos/commit/caba3a9
