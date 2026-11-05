# Shared Rust core and Tauri migration

Status: **accepted direction; experimental implementation, not a replacement release**.
Date: 2026-11-06. Tracking: [#31](https://github.com/Zheruel/pressay-macos/issues/31).

## Decision

Use a UI-independent Rust core and Tauri 2 as the cross-platform desktop shell.
Keep the existing Swift app shipping until actual feature parity and native
integration are demonstrated. Preserve its graphite palette, navigation, speech
models, native permission behavior and data. A shell rewrite is not evidence of
faster recognition, smaller memory use, or improved recognition accuracy.

The first implementation is an explicitly named **Pressay Preview**, with bundle
ID `dev.localflow.preview`, separate storage, and no automatic replacement of
`dev.localflow.app`. It implements real model preparation, native microphone
capture, the existing JSONL ASR worker protocol, insertion, history, vocabulary,
and practice dictation. It also improves onboarding/installation in the current
Swift app immediately. The preview must not be promoted as the finished port.

## Changes to the tracking issue's proposal

- Do not build the same shell twice merely to compare frameworks. Rune's pinned
  [changelog](https://github.com/anomalyco/rune/blob/0f0a941ec18386d49beecc894600a93510b20265/CHANGELOG.md)
  says it has no releases; its AccessKit integration landed on November 4.
  Tauri has documented process boundaries and distribution tooling. This is a
  maintenance decision, not a benchmark result. Reconsider Rune only for a
  demonstrated product requirement Tauri cannot satisfy.
- Keep the shipping one-worker policy. Concurrent dictation/meeting scheduling
  is a separate product change, not a prerequisite for portability.
- Public Mac releases already use a stable self-signed release certificate.
  Preserve that path; make Developer ID notarization explicit and fail closed
  when requested. Switching certificate identity may require reapproval.
- Current vocabulary is manual-only. Preserve existing raw entries and legacy
  learned data in migration, but never reintroduce automatic learning or stock
  substitutions as part of the port.
- Plan for Wayland as well as X11. Do not select Ubuntu 24.04/X11 as the final
  definition of Linux support. A running WebView is not working dictation.

## Boundaries

`pressay-core` owns the pinned model catalog, verified downloads, cancellation,
one resident ASR subprocess, audio chunking/truncation recovery, vocabulary,
versioned persistence/import, readiness, and bounded scheduling contracts.
It imports neither Tauri nor a platform UI framework.

`pressay-asr` wraps the existing C/C++ engines. It retains the worker protocol:
`<model-id> <model-path> <runtime-directory>`; one ready response; base64
little-endian float32 mono 16 kHz audio; text and explicit truncation responses.
It bounds requests/replies, rejects nonfinite audio, and redirects native
stdout diagnostics to stderr. Runtime versions are checked before use.

The desktop host owns native capture (CPAL), anti-aliased conversion (Rubato),
shortcut registration, permission UI, focus checks, insertion and windows.
Capture and blocking native work are off the WebView/render thread. The
microphone is opened on hold and closed on release/cancel; readiness follows
actual samples, never a timer. Speech stays local.

The preview uses Unicode event insertion to preserve all clipboard formats.
This still requires testing with IMEs and custom editors; it is not established
parity with the Swift Accessibility/paste strategy. Currently the preview's
shortcut is Ctrl+Shift+Space. Shipping Mac users retain their existing configurable
hold key in the Swift app.

## OS, CPU and backend matrix

| Target | Current complete app | Preview implementation | Release requirement |
| --- | --- | --- | --- |
| macOS 26+, Apple Silicon | Existing Swift app | Tauri, CoreAudio capture through CPAL, permission checks, native key registration and Unicode insertion; Orukeet/Metal and transcribe/Metal | Native end-to-end practice, overlay/focus, accessibility and IME verification; full feature parity |
| Windows 11 x64 | None | Tauri/WebView2, WASAPI microphone through CPAL, native shortcut, Unicode insertion; transcribe CPU; NSIS/MSI packaging | Real clean-machine capture/insertion, loopback meetings, signing, upgrades/uninstall and full feature parity |
| Linux Ubuntu 24.04 x64/arm64, X11 | None | Tauri/WebKitGTK, ALSA/PipeWire compatibility capture through CPAL, X11 shortcuts/focus/insertion; transcribe CPU; deb/AppImage packaging | Physical audio/input verification, monitor-stream meetings, distro upgrades/uninstall and full feature parity |
| Linux Wayland | None | Detected and explicitly blocked from the unsupported insertion path | GlobalShortcuts and RemoteDesktop/EIS integration plus per-compositor testing |
| Windows ARM64 / Intel Mac | None | Not an announced target | Dedicated native builds and backend validation before support is claimed |

The pinned transcribe runtime is `41738b58b305c08bdecf5379dccdc19a0f7c3b05`.
Its portable CPU build is a conservative baseline. Vulkan/CUDA acceleration
needs separate driver and latency validation. Mega-ASR uses Apple's MLX stack
and is deliberately absent from the preview picker; it remains available in
the original app. No unavailable model is silently replaced on import.

Newer transcribe.cpp [documents portable Orukeet](https://github.com/handy-computer/transcribe.cpp/blob/v0.4.1/docs/models/orukeet.md).
Its artifact/API differ from the optimized shipping Orukeet path. Evaluate it
against fixed human-referenced corpora before changing a model default. The
preview asks non-Mac users to prepare an available model explicitly; that does
not establish model-quality parity.

## Linux path

Tauri's [global-hotkey](https://github.com/tauri-apps/global-hotkey) supports X11,
not general Wayland shortcut capture. Wayland integration should use the
[GlobalShortcuts portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)
for hold press/release and display the actual granted binding. For insertion,
request keyboard control through the
[RemoteDesktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html),
preferably its recommended EIS/libei route. Denial/revocation must return to
setup; do not require root or raw input-device privileges as a fallback.

GNOME added global-shortcut portals in [version 48](https://release.gnome.org/48/developers/).
Older desktops need an explicitly supported desktop-keybinding/toggle route.
Runtime capability discovery and compositor-specific acceptance tests are
required. The current preview reports Wayland unavailable rather than running
X11 automation against the wrong desktop.

Meeting capture is another native adapter, independent of the shell:
[Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps),
[WASAPI loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording),
and [PipeWire monitor streams](https://docs.pipewire.org/page_module_loopback.html).
Mic and remote tracks must remain distinct, synchronized and echo-controlled.
Windows insertion must respect [SendInput integrity restrictions](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).

## Migration and rollback

The native Mac app exports through SwiftData's public API, including every
history row (not only the 500 displayed records), raw model/settings values,
manual and legacy vocabulary fields, and full notes. No keychain material or
API tokens are exported. Each export has a stable ID within that file.

The Rust importer validates the schema before writes, imports transactionally,
preserves existing preview edits and unknown legacy fields, and deduplicates
records/exports. It never opens or interprets SwiftData's private SQLite schema.
A malformed record rolls back the whole import. A newer Rust schema is rejected
without changing the database. Original Mac settings, History.store, notes,
and recordings are never deleted or converted in place.

Rollback is quitting the preview and using the unchanged Swift app. New preview
dictations are not automatically copied back to SwiftData. Clipboard copies and
explicit exports must be used if those records are needed in the original app.
Do not change the production bundle identity or updater until this limitation
is resolved and upgrade tests pass.

## Release gates still open

The preview is not a parity claim. It does not yet port AI provider accounts and
cleanup, live meeting capture/diarization/notes/action items, call detection,
Reminders, configurable hold keys, launch-at-login, retention settings, signed
updates, or native Wayland integration. Imported meeting notes are readable;
recording meetings still belongs to the complete Swift app. The Rust scheduler
is a tested core contract, not a claim that a meeting recorder exists in the new
shell.

Do not close #31 until those features are integrated and clean-machine
install → permissions → model readiness → real inserted practice is verified
on every supported platform, including deny/revoke/regrant and upgrade rollback.
Benchmark key-down-to-first-sample and key-up-to-visible-text, cold/warm startup,
idle/peak RAM, sustained CPU/power, and real screen-reader/IME/reduced-motion
behavior. Replay fixed human-referenced corpora with names, pauses, mixed
languages, corrections, long meetings and cancellation. Public JFK smoke tests
prove adapter operation only; they do not establish recognition accuracy or
end-to-end dictation latency.

See [validation evidence](../cross-platform-validation.md).
