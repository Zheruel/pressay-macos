# Pressay cross-platform preview

Pressay Preview is the shared Rust core and Tauri implementation for [#31](https://github.com/Zheruel/pressay-macos/issues/31). Its implemented surface includes local dictation, history with audio playback and corrections, manual vocabulary, optional AI cleanup, voice notes, live meetings, speaker separation, editable notes, action items and Ask Notes. Guided setup requires real capture, recognition and insertion before practice completes.

The app retains the separate identity `dev.localflow.preview` and an independent store. It does not replace the native Mac release. Platform integrations and release acceptance are tracked in the [architecture decision](../../docs/architecture/001-shared-rust-core.md) and [validation record](../../docs/cross-platform-validation.md).

## Build

Requirements: Rust 1.90+ (CI uses current stable), Node.js 24, Python 3.11+, CMake, and a native C++ toolchain. macOS builds target Apple Silicon/macOS 26 and need Xcode/Swift plus the Metal toolchain for the existing MLX worker. Windows packaging needs Visual Studio Build Tools and WebView2. Linux needs the development packages listed in `.github/workflows/ci.yml`; meeting capture also needs `pulseaudio-utils` and PulseAudio or PipeWire's PulseAudio compatibility service.

From the repository root:

```sh
cargo test --workspace --locked
python3 scripts/build-desktop.py
```

Installers land in `target/release/bundle`. The build stages the pinned native runtime, Rust ASR and analysis workers, and the Mac Swift/MLX and meeting-capture helpers. It includes the checksum-verified Sortformer frontend patch needed for long meetings. Model weights are downloaded when their feature/model is prepared, not bundled in the installer.

The manual `Desktop preview installers` workflow builds macOS, Windows and Linux artifacts without publishing a release. Signing, notarization and the signed desktop update channel need explicit release configuration; see [release setup](../../docs/releases.md). A local preview build does not imply trusted signing or an active update feed.

On macOS, rebuilding an ad-hoc preview changes its signature. If System Settings shows access enabled but Preview still reports it missing, remove Preview's stale entry and add the current built app again under Accessibility (called Device Control and Data Access on newer macOS) and Input Monitoring, then quit and reopen Preview if prompted. Keep the original Pressay app's entries unchanged. This was reproduced during local permission testing; a stable Developer ID signature is part of release validation.

For development on macOS/Linux, use the staged workers explicitly so meeting analysis and Mac MLX resources resolve beside the selected ASR worker:

```sh
python3 scripts/build-desktop.py --no-bundle
npm --prefix apps/desktop ci
PRESSAY_RUNTIME_DIR="$PWD/apps/desktop/src-tauri/runtime" \
PRESSAY_WORKER_PATH="$PWD/apps/desktop/src-tauri/binaries/pressay-asr-worker" \
npm --prefix apps/desktop run dev
```

On Windows, set those environment variables in your shell and use `pressay-asr-worker.exe`. Without overrides, debug builds select `target/debug/pressay-asr-worker` and may reuse an existing `.build/Pressay.app` runtime on Mac; that older runtime may lack the required analysis patch. Environment overrides are native development settings, never renderer commands.

## Use and platform differences

- The default hold key is **Ctrl+Shift+Space**. General settings can change the chord; Mac also supports physical modifier/Fn keys. Setup displays the registered or portal-granted binding. Escape cancels active dictation, and overlays avoid taking text focus.
- Dictation recognizes completed speech in the background after eight seconds and a half-second pause, then processes the remaining tail on release. Original trim rules, begin/release/cancel/error sounds and live level/status overlays are retained. A five-minute capture limit stops and transcribes automatically; it does not discard the recording.
- The catalog retains five recommended models (Orukeet, MOSS, Parakeet Ultra, Qwen3-ASR 1.7B, Mega-ASR) and four Other models (Fun-ASR MLT Nano, Whisper V3 Turbo, Voxtral Mini 3B, Qwen3-ASR 0.6B). Fixed-language choices appear only where supported. Orukeet and the existing Mega-ASR Swift/MLX worker remain Mac-only; Windows/Linux have the seven portable choices. Unavailable imported choices are preserved and require explicit selection.
- Meetings keep microphone and remote tracks separate: CoreAudio process taps on Mac, WASAPI loopback on Windows, and the active PulseAudio/PipeWire monitor on Linux. Capture and optional final speaker separation support up to eight hours. Device/queue failures are reported. Mac voice processing has an explicit fallback; Windows/Linux currently have no echo cancellation in these adapters, so headphones matter.
- Wayland uses GlobalShortcuts and RemoteDesktop keyboard portals with denial, revocation and session-loss handling. Enable **Insert at the current cursor using the desktop portal** to opt in: Wayland does not reveal the original target application. Keep the intended cursor focused until insertion finishes. Unsupported portals or rejected text leave the transcript available for manual copy. X11 uses its native focus/insertion path; Wayland never silently falls back to X11 automation.
- Optional Claude/OpenAI API connections keep keys in the OS credential store. ChatGPT browser sign-in and Claude subscription access through the official Claude Code tool are implemented. AI sends text to the chosen provider; recognition remains local. Linux requires an available Secret Service for credential storage.
- Notes support write-ups, transcript review, named speakers, action-item toggles, Markdown export, calendar-task export and grounded Ask Notes. macOS additionally supports native Reminders export. Call suggestions use native capture-stream heuristics, not guaranteed identification of every call. A meeting bound to a detected call stops when that call ends, including when suggestions are disabled. A two-minute warning precedes the duration limit. Quitting drains the transcript tail and defers optional write-up work; startup resumes eligible pending write-ups when AI and a provider are available.
- Launch at login, retention and updater integration are implemented. Unpinned dictations retain 30 days of history and seven days of audio; pinned/corrected entries are preserved. History includes Paste Again, and Clear History explicitly confirms removal of all entries, including pins/corrections, and owned audio. Failed-recognition diagnostic audio expires after seven days. Silent completed recordings without personal notes and explicitly discarded recordings are removed; interrupted recordings retain saved transcript segments. Updates require a configured signing key/feed and wait for active work to finish.

Physical-device, compositor, editor/IME and permission testing remains necessary across supported systems. [Meeting validation](../../docs/portable-meeting-validation.md) records the actual worker checks and memory bounds; it does not claim complete hardware QA.

## Migration and rollback

In the updated native Mac app, choose **General → Export for cross-platform preview…**, then import that JSON under **General** in the preview. The export includes all history rows, raw settings/vocabulary and notes, but no credentials. Import validates transactionally, deduplicates records and preserves preview edits and unknown legacy fields. Keep the private export local.

Separate explicit Mac actions can copy existing API keys into preview credential entries or import original dictation recordings. They do not delete or rewrite the original app's data. Audio import accepts recordings up to five minutes; longer originals remain untouched. Imported microphone UIDs resolve to the matching Mac device; an unavailable device requires choosing a microphone explicitly. Meeting analysis uses private temporary system-audio files, removed on completion/cancel and recovered by locked orphan cleanup after a crash; see the validation notes for details.

Rollback is quitting the preview and using the original Swift app and its unchanged store. New preview records are not automatically synchronized back to SwiftData; use explicit export/copy when needed.
