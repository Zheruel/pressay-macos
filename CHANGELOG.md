# Changelog

All notable changes to Pressay are documented here. The project follows [Semantic Versioning](https://semver.org/).

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
