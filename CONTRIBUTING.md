# Contributing to Pressay

Thanks for helping make voice prompting better on macOS, Windows and Linux. Small, focused changes with evidence are easiest to review.

## Before opening an issue

- Search existing issues first.
- Use the bug or feature template where possible.
- Never attach private dictation audio, raw prompt history, API keys, crash logs containing prompt text, or screenshots with confidential application content.
- If an audio sample is necessary, record a new synthetic sentence and explicitly confirm that it may be published.
- Report security and privacy vulnerabilities through the process in [`SECURITY.md`](SECURITY.md), not a public issue.

## Development setup

You need stable Rust, Node.js 24, Python 3.11+ and CMake. On a Mac you also need Apple Silicon, macOS 26+, Xcode 26+ and the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`). Windows and Linux requirements are in [`apps/desktop/README.md`](apps/desktop/README.md#build).

```bash
git clone https://github.com/Zheruel/pressay-macos.git
cd pressay-macos
make test
make app
```

The first `make app` fetches and builds the pinned transcribe.cpp runtime. The first app run downloads the selected model into the app's data folder; models and user data must not be committed. Use `make run` for a development build.

## Pull requests

1. Fork the repository and create a focused branch.
2. Add or update tests for deterministic behavior.
3. Run `make test` and `make app`.
4. Manually verify any recording or insertion change in more than one target app, and say which platforms you tested.
5. Explain the user-visible behavior and privacy impact in the pull request.

For ASR or post-processing changes, replay the same held-out clips before and after. Report transcript regressions, critical-token changes, warm latency, and the hardware used. A speed gain does not justify a quality regression in the default model.

## Design principles

- Microphone audio must never be sent to a server.
- Standard dictation must work fully offline after model download.
- Networked text processing must be explicit, labeled, and optional.
- Never add telemetry or analytics without an open design discussion and affirmative user consent.
- Preserve names, identifiers, numbers, URLs, negations, uncertainty, and spoken constraints.
- The recording overlay must not steal focus from the destination field.
- Prefer native platform behavior and accessible controls.

## Benchmark data

The benchmark harness accepts local manifests, but raw manifests, audio, transcripts, and generated outputs belong outside the repository. Only publish consented samples or sanitized aggregates.

See [`docs/benchmarks.md`](docs/benchmarks.md) for the 1.0 methodology and limitations.

## Style

- Rust: run `cargo fmt --all` and keep `cargo clippy --workspace --all-targets -- -D warnings` clean.
- Web UI: format `apps/desktop/ui` with Prettier 3.9.10 (`npx prettier@3.9.10 --write "apps/desktop/ui/**/*.{js,css,html}"`).
- Keep blocking work, such as inference and file I/O, off the UI thread and the async runtime.
- Prefer small deterministic helpers that can be unit tested.
- Preserve user-owned local changes and avoid broad mechanical rewrites in focused pull requests.

By participating, you agree to keep discussion respectful, specific, and welcoming. Harassment, personal attacks, and publication of another person's private data are not acceptable.
