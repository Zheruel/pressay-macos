# Shared Rust core and Tauri migration

Status: **implemented preview; platform release acceptance remains open**.
Date: 2026-11-06. Tracking: [#31](https://github.com/Zheruel/pressay-macos/issues/31).

## Decision

Use a UI-independent Rust core and Tauri 2 desktop shell. Preserve the existing product behavior, speech models, graphite styling and native integrations while sharing persistence, transcription orchestration, cleanup, accounts and notes. Keep the Swift app available until release acceptance is demonstrated. A shell rewrite alone proves neither faster recognition nor lower memory use.

**Pressay** (Rust) uses `dev.localflow.app` and installs in place of the Swift app, with separate storage, credential entries and update channel. Implemented features now include dictation/history/audio, vocabulary, provider cleanup/accounts, voice notes and meetings, speaker separation, notes/write-ups/review/Ask Notes, action exports, call suggestions, configurable hold keys, launch at login, retention and signed-update integration. Both apps receive guided native permission setup; preview practice requires actual captured audio, recognition and matching inserted text.

## Adjustments to the issue proposal

- Use Tauri rather than maintaining two shells solely for a framework comparison. The pinned [Rune changelog](https://github.com/anomalyco/rune/blob/0f0a941ec18386d49beecc894600a93510b20265/CHANGELOG.md) recorded an unreleased framework; Tauri provides the chosen distribution/process model. This is a maintenance decision, not a performance claim.
- Preserve one active recording/ASR owner. Meetings exclude dictation; stopping devices runs independently of slow inference. Final speaker analysis starts after ASR closes. Optional text-only AI work can continue afterward without keeping the microphone open.
- Keep manual vocabulary and preserve unknown/legacy imported entries. Do not reintroduce automatic learning or stock substitutions.
- Support native Wayland portal integration as well as X11. Ubuntu/X11 is a test/build baseline, not the final definition of Linux support.
- Retain all nine catalog choices: five recommended models and four Other models, with fixed-language settings only for supported runtimes. Keep the optimized Mac Orukeet and Swift/MLX Mega-ASR workers; the other seven have portable adapters. Unavailable imported choices are never silently substituted.
- Bound each dictation to five minutes, with automatic stop/transcription at the limit. This is an explicit limit compared with the unbounded Swift capture; it prevents unlimited PCM retention without losing the captured tail. Meetings retain the eight-hour limit.
- Patch the pinned Sortformer frontend narrowly: upstream streams its speaker cache but materializes whole-clip mel features. Context-exact windowed mel avoids that recording-sized heap allocation. The build validates the patch hash, and the analysis worker requires its capability symbol. [Validation](../portable-meeting-validation.md) records exact comparisons and memory limits.

## Boundaries

`pressay-core` contains model catalogs/verified downloads, resident-worker lifecycle, deterministic vocabulary and text cleanup, provider/account protocols, versioned persistence/import, recordings/retention, notes/action items, segmentation, analysis clients, readiness and scheduling. It does not depend on Tauri or a platform UI framework. The host supplies OS credential storage.

`pressay-asr` adapts the pinned C/C++ engines in an isolated process. The existing ASR JSONL protocol uses bounded requests/replies, finite mono 16 kHz float32 audio, and explicit truncation recovery. Native diagnostics cannot corrupt protocol stdout. A separate `pressay-analysis-worker` owns independent per-track Silero state and final Sortformer analysis. Cancellation kills and reaps workers.

The desktop host owns CPAL capture/Rubato conversion, native meeting adapters, shortcut registration, permissions, focus/secure-field checks, insertion, overlays, windows, OS credentials, call detection, login integration and installers. Mac-specific helpers preserve existing optimized model and capture behavior. Blocking capture teardown is kept off the render thread; readiness requires real samples. History is saved before insertion so a refused or interrupted insertion does not discard the transcript.

Dictation streaming uses the existing eight-second minimum and half-second pause before background recognition, independent Silero state, one resident ASR worker, and whole-clip fallback when streaming is incomplete. The original energy trim/context rules, cue exclusion and sounds are preserved. Native overlays show real level/status updates; stopping the device does not wait for inference. Diagnostic audio is saved before ASR and expired after seven days if it has no history row. History deletion is transactional and only removes preview-owned audio, never imported source paths.

Speech recognition stays local. Optional cleanup, notes and Ask Notes send selected text to the configured provider. Credentials never enter renderer state or ordinary migration JSON. Claude subscription requests use the official Claude Code process with restricted text-only execution; ChatGPT sign-in uses a cancellable browser authorization flow and protected token storage.

## Platform matrix

| Target | Implemented native path | Constraints and acceptance still needed |
| --- | --- | --- |
| macOS 26+, Apple Silicon | Native key/permission/overlay/insertion adapters; CoreAudio process-tap meetings with mic voice processing; Orukeet/Metal, portable transcribe/Metal and Mega-ASR Swift/MLX; Keychain; Reminders | Real permission deny/revoke/regrant, microphone/routes, Right Option/Fn, IME, secure/custom editors, trusted signing/notarization and upgrade acceptance |
| Windows 11 x64 | Tauri/WebView2, CPAL/WASAPI microphone and output loopback, native shortcuts, Unicode insertion/focus checks, Credential Manager, portable CPU models, NSIS/MSI packaging | Physical audio and editor tests, integrity/elevation boundaries, signing, clean install/upgrade/uninstall; no microphone echo cancellation in this adapter |
| Linux Ubuntu 24.04 x64/ARM64, X11 | Tauri/WebKitGTK, CPAL microphone, PulseAudio/PipeWire-pulse monitor, X11 shortcuts/focus/insertion, Secret Service, portable CPU models, deb/AppImage packaging | Actual editor/audio and distro acceptance; `pulseaudio-utils` and a PulseAudio-compatible service for meetings; no echo cancellation; timestamp alignment is not hardware-clock validation |
| Linux Wayland | GlobalShortcuts press/release/cancel and RemoteDesktop keyboard consent; actual granted binding, revocation/session-loss recovery; explicit current-cursor insertion | Requires compatible compositor portals. No original-target identity is exposed. Current implementation uses portal keysyms, not EIS. Physical GNOME/KDE and keyboard-layout/IME acceptance remains open |
| Windows ARM64 / Intel Mac | Not an announced release target | Dedicated native builds and backend validation required |

The runtime base remains `41738b58b305c08bdecf5379dccdc19a0f7c3b05` plus the checked-in Sortformer patch. Portable CPU is the Windows/Linux baseline; CUDA/Vulkan acceleration is not claimed. Mac-only model metadata remains visible to migration without promising those models on other systems. Newer [portable Orukeet](https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/orukeet.md) uses a different artifact/API; changing defaults requires its own corpus comparison.

## Wayland and meeting semantics

Wayland uses the [GlobalShortcuts](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html) and [RemoteDesktop](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html) portals. The user explicitly enables insertion at the current cursor because the original application cannot be verified. Missing support, denial, revocation, lock/sleep and rejected control text stop the unsupported operation and retain History for manual copy. The app does not request root/raw-input privileges or run X11 automation on a Wayland session. Older desktops lacking these interfaces cannot provide this insertion mode.

Meeting capture uses [CoreAudio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps), [WASAPI loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording), and PulseAudio/PipeWire-pulse sink monitors. Tracks retain their common timeline across gaps, with bounded queues and explicit overflow/device errors. Duration limits clip final callbacks on the 16 kHz sample grid. Mic voice processing is available on Mac with a reported fallback; other adapters currently require acoustic separation such as headphones. Windows loopback includes Pressay's own output.

ASR consumes bounded utterances. Final speaker separation maps private, locked temporary remote PCM; eight hours can map 1.8432 GB, so bounded heap is not a constant-RSS claim. Orphan cleanup handles crash leftovers on the next startup. Microphone-only voice notes do not create a system-audio spool. Call suggestions use native capture-activity heuristics and can miss or misidentify calls. Bindings are scoped to the active meeting, including a manual start during a detected call; call end stops that meeting even if suggestions are disabled. Voice notes never bind. A two-minute duration warning precedes automatic stop. Quit drains pending speech before saving, cancels optional speaker work, and leaves eligible write-ups for startup recovery. Hand-edited, interrupted, completed and unmarked imported notes are not automatically rewritten.

## Migration, release and rollback

The native Mac exporter reads SwiftData through public read-only APIs and exports every history row, settings/manual and legacy vocabulary, and full notes. It does not instantiate stores that perform retention or migrations. Credentials are excluded; each snapshot has its own import identity.

The Rust importer validates before transactional writes, deduplicates records/exports, and preserves preview edits and unknown legacy fields. Malformed imports and newer schemas do not partially modify the database. It never interprets SwiftData's private SQLite schema. Separate user-initiated Mac actions can import original audio or copy existing API keys to preview entries; source data and credentials remain intact. Recording import has the preview's five-minute bound. Imported microphone UIDs resolve through native metadata and fail explicitly when the device is absent, rather than silently switching inputs.

Rollback is reinstalling the Swift app, whose store is unchanged. New preview records do not automatically synchronize back to SwiftData. Explicit JSON/Markdown/task export and transcript copy remain available.

Installer and updater code is implemented, including shutdown before executable replacement and signature verification. Trusted signing credentials, feed publication and clean upgrade tests are release configuration/acceptance work, not implied by a local build. See [release setup](../releases.md).

## Acceptance still open

The remaining gates are validation of the implemented surface, not the old list of unported notes/AI/Wayland/Mega features. Verify clean install → permissions → model → real inserted practice on supported physical systems, including denial/revocation, focus changes, IMEs, screen readers, Bluetooth/audio route changes, sustained meetings, lock/sleep, upgrade/uninstall and rollback. Provider/browser consent and native task-export acceptance also need real supported environments.

Measure first-audio and visible-insertion latency, startup, idle/peak RAM and sustained CPU/power on comparable hardware. Public model replays, mocked provider/portal fixtures and headless X11 tests establish specific contracts; they do not establish complete product or hardware QA. See the [validation record](../cross-platform-validation.md).
