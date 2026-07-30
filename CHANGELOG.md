# Changelog

All notable changes to Pressay are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [1.4.0] - 2026-07-30

### Added

- Fun-ASR MLT Nano 2512 (Q6_K) as the new default transcription model, replacing Whisper V3 Turbo in that role. Thirteen engines were replayed through the 184-clip corpus and it led on the measurement that matters most for dictating prompts — correctly transcribed technical terms (86%, against Whisper's 75%) — while also never collapsing a long dictation into an unpunctuated lowercase block (0 of 47, against Whisper's 3), running 2.5× faster, and shipping 195 MB smaller. It runs English-locked with inverse text normalization on; both settings are load-bearing, see below.
- In-app splitting for long dictations, which is both a correctness fix and a speed one. The context-bound engines previously lost a 100-second dictation outright. Pressay now splits audio over 60 seconds at the quietest point and runs the same engine on each part. Because those engines decode token by token, one long pass costs more than two shorter ones: the worst-case wait fell from 4.71 s to 2.07 s on the default and from 13.27 s to 6.34 s on Voxtral, with transcripts 99.3% identical. 60 s is a measured optimum — below about 40 s the per-call overhead makes long dictations slower again. Falling back to Whisper was rejected deliberately: Whisper is the engine that collapses long clips, so it is the wrong repair for exactly this case.
- Automatic removal of model files Pressay no longer ships, reclaiming the space used by retired engines on first launch.

### Changed

- The language picker now offers only the languages the selected model can actually decode, and explains why when there is no choice: Fun-ASR is English-only, Voxtral covers eight languages plus detection, Whisper keeps all 19. Switching to a model that cannot decode the current language moves the setting to that model's default rather than failing at dictation time.
- Fun-ASR is asked for punctuation and inverse text normalization explicitly. It ships with those off and emits verbatim lowercase otherwise; turning ITN on is what took it from 8 collapsed long clips to none. Whisper and Voxtral expose no such toggle and are untouched, keeping the defaults their earlier calibration was measured against.
- Voxtral Mini 3B is now positioned as the quality-first option rather than the long-form one, and defaults to automatic language detection. On the corpus it matches the new default on technical terms (81% against 86% — two term occurrences) and punctuates more densely than anything else that is also accurate. It costs 9× the latency and 4× the size, which is the only reason it is not the default.
- Short bursts of a non-Latin script are now discarded for engines that only ever run in English, covering the last case where Fun-ASR invented a foreign sentence for a near-silent clip. Engines that legitimately transcribe those scripts are unaffected.

### Removed

- Whisper V3 Turbo as the *default* (it remains selectable, and is still the only engine covering 100 languages). It has the only long-clip collapse left in the lineup, and it was also measured silently omitting content on 4 of 47 long clips — in one case rendering "That seems like a creative idea that nobody's done before" as "but it's done before".

## [1.3.0] - 2026-07-24

### Added

- Voxtral Mini 3B as an optional transcription model, selectable in Settings. It is an LLM-style multilingual audio model that is stronger than Whisper on long dictations — noticeably better punctuation, capitalization, and completeness, and it never collapses long passages into an unpunctuated block the way Whisper occasionally does. It downloads on demand (~3 GB) and uses more memory (~5 GB) than Whisper, so Whisper V3 Turbo remains the default; long-form users can opt in. Chosen over Voxtral Small (too large) and cloud APIs (would leave the device) after a corpus evaluation.
- A download progress bar for models in Settings and onboarding, so the larger Voxtral download shows live percentage instead of an indeterminate spinner. Only the currently selected model is held in memory; switching models frees the previous one.

### Changed

- Voxtral runs with automatic language detection (the app default), which — for an instruct-tuned audio model — is safer than forcing a language: near-silent clips now produce nothing instead of a fabricated sentence. Assistant-style refusals ("I'm sorry, I didn't understand") on unintelligible short audio are treated as empty and never inserted.

### Removed

- Parakeet TDT 0.6B v3 as a selectable model. Despite being the fastest engine, its transcript quality (disfluencies, occasional inserted phrases) was not comparable to Whisper on the development corpus. Anyone who had it selected falls back to Whisper V3 Turbo automatically.

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

[1.3.0]: https://github.com/Zheruel/pressay-macos/releases/tag/v1.3.0
[1.2.0]: https://github.com/Zheruel/pressay-macos/releases/tag/v1.2.0
[1.0.0]: https://github.com/Zheruel/pressay-macos/releases/tag/v1.0.0
[1.1.0]: https://github.com/Zheruel/pressay-macos/commit/caba3a9
