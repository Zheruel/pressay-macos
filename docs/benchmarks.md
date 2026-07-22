# Pressay 1.0 benchmark notes

Pressay's defaults came from replaying real voice prompts, not from synthetic one-line demos. This page records the evidence that can be published without exposing anyone's voice or prompt history.

The sanitized aggregate data behind the charts lives in [`docs/benchmarks/results.json`](benchmarks/results.json). Raw audio, transcripts, and per-clip output remain private and are intentionally ignored by Git.

## Test environment

| Item | Value |
| --- | --- |
| Machine | Apple Silicon M5 Pro development Mac |
| OS / toolchain | macOS 26, Swift 6.2 |
| Corpus | 184 real hold-to-talk dictations |
| Audio duration | 0.54–103.59 seconds; 36.33 minutes total |
| Content | AI-agent prompts, team messages, technical identifiers, names, numbers, and multi-part tasks |
| Timing | Warm model; wall-clock inference time; one engine at a time |

The corpus is representative of the app's intended use, but it is not a standardized public benchmark. Results should be treated as product calibration on one machine, not universal model rankings.

## ASR selection

The 1.0 investigation compared the former WhisperKit implementation, Whisper Large V3 Turbo and Parakeet TDT 0.6B v3 through `transcribe.cpp`, and language/worker settings. Candidate transcripts were reviewed for meaning, identifiers, numbers, negations, and obvious hallucinations.

### Shared-clip latency

The values below come from exactly the same two recordings for all three engines.

| Engine | 6.09 s clip | 35.89 s clip | Role in 1.0 |
| --- | ---: | ---: | --- |
| Parakeet TDT 0.6B v3 F16 | 0.057 s | 0.215 s | Optional fastest model |
| Whisper V3 Turbo Q8 via `transcribe.cpp` | 0.327 s | 0.765 s | Default |
| Whisper V3 Turbo via previous WhisperKit path | 0.566 s | 1.569 s | Retired implementation |

These samples show why the native GGUF path replaced WhisperKit for 1.0. Parakeet is dramatically faster, especially on long audio, but it was less reliable on very short fragments in the development corpus. Because transcript quality is the primary goal, Whisper V3 Turbo remains the default.

### Worker and language sweep

The previous WhisperKit implementation was replayed across the complete 184-clip corpus twice per worker setting:

| Configuration | Median inference time |
| --- | ---: |
| 1 worker | 0.564 s |
| 4 workers | 0.561 s |
| 16 workers | 0.561 s |
| 4 workers, automatic language detection | 0.600 s |

More workers did not materially improve the median. Automatic language detection added a small pass and could misclassify short clips, which is why Pressay keeps fixed-language selection available even though Automatic is the UI default.

## Post-processing selection

An on-device Foundation Models experiment replayed 31 dictations through four prompt variants. Every output then passed through the same protected-token validator used during development. An accepted output retained the required technical tokens, numbers, URLs, names, and negations.

| Variant | Accepted | Pass rate | Median latency |
| --- | ---: | ---: | ---: |
| Light + few-shot | 29 / 31 | 93.5% | 0.811 s |
| Light | 27 / 31 | 87.1% | 0.762 s |
| Shipping experiment | 21 / 31 | 67.7% | 0.813 s |
| Light, plain instructions | 8 / 31 | 25.8% | 0.824 s |

The validator is intentionally conservative. It does not measure whether prose sounds nicer; it answers the more important standard-dictation question: “Did the rewrite preserve protected meaning?” No tested generative variant was perfect, so Pressay 1.0 removed automatic LLM rewriting from its normal path.

The shipping design is:

1. Use deterministic cleanup for every standard dictation.
2. Apply curated and learned vocabulary rules without asking a model to reinterpret the sentence.
3. Keep the optional Structured Dictation pass deterministic too — punctuation, paragraphs, and lists, never a rewrite.

## Reproducing the harness

`PressayBench` is included in the Swift package. Create your own local manifest rather than committing recordings:

```bash
swift run PressayBench manifest-from-audio \
  --manifest /absolute/path/manifest.json

swift run PressayBench asr \
  --manifest /absolute/path/manifest.json

swift run PressayBench structure \
  --manifest /absolute/path/manifest.json
```

The manifest schema is represented by `ManifestEntry` in [`Sources/PressayBench/Bench.swift`](../Sources/PressayBench/Bench.swift). Keep paths absolute, use the same clips for every engine, warm each model before timing, and manually correct reference transcripts before calculating error rates.

## What the numbers do not prove

- The private corpus cannot provide independently reproducible WER.
- Two shared clips are enough to demonstrate relative latency on the development Mac, not quality across accents and environments.
- A validator pass is a safety check, not a blind preference score.
- Cloud-model latency and behavior vary over time, so the repository does not publish a permanent Kimi leaderboard.

If public contributors provide a consented, license-compatible prompt-dictation corpus, Pressay can add normalized WER and critical-token error rates without weakening the current privacy standard.
