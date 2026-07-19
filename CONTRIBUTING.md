# Contributing to Pressay

Thanks for helping make voice prompting better on macOS. Small, focused changes with evidence are easiest to review.

## Before opening an issue

- Search existing issues first.
- Use the bug or feature template where possible.
- Never attach private dictation audio, raw prompt history, API keys, crash logs containing prompt text, or screenshots with confidential application content.
- If an audio sample is necessary, record a new synthetic sentence and explicitly confirm that it may be published.
- Report security and privacy vulnerabilities through the process in [`SECURITY.md`](SECURITY.md), not a public issue.

## Development setup

Pressay requires an Apple Silicon Mac, macOS 26+, Xcode 26+, and Swift 6.2.

```bash
git clone https://github.com/Zheruel/pressay-macos.git
cd pressay-macos
make test
make app
```

The first Swift build downloads the pinned `CTranscribe` binary target. The first app run downloads the selected model into Application Support; models and user data must not be committed.

## Pull requests

1. Fork the repository and create a focused branch.
2. Add or update tests for deterministic behavior.
3. Run `make test` and `make app`.
4. Manually verify any recording or insertion change in more than one target app.
5. Explain the user-visible behavior and privacy impact in the pull request.

For ASR or post-processing changes, replay the same held-out clips before and after. Report transcript regressions, critical-token changes, warm latency, and the hardware used. A speed gain does not justify a quality regression in the default model.

## Design principles

- Microphone audio must never be sent to a server.
- Standard dictation must work fully offline after model download.
- Networked text processing must be explicit, labeled, and optional.
- Never add telemetry or analytics without an open design discussion and affirmative user consent.
- Preserve names, identifiers, numbers, URLs, negations, uncertainty, and spoken constraints.
- The recording overlay must not steal focus from the destination field.
- Prefer native macOS behavior and accessible controls.

## Benchmark data

The benchmark harness accepts local manifests, but raw manifests, audio, transcripts, and generated outputs belong outside the repository. Only publish consented samples or sanitized aggregates.

See [`docs/benchmarks.md`](docs/benchmarks.md) for the 1.0 methodology and limitations.

## Style

- Follow the existing Swift 6 concurrency model and actor boundaries.
- Keep AppKit work on the main actor and blocking inference off it.
- Prefer small deterministic helpers that can be unit tested.
- Preserve user-owned local changes and avoid broad mechanical rewrites in focused pull requests.

By participating, you agree to keep discussion respectful, specific, and welcoming. Harassment, personal attacks, and publication of another person's private data are not acceptable.
