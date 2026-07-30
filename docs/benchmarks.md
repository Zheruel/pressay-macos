# Pressay benchmark notes

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

## Pressay 1.4 — ten-engine sweep

For 1.4 every engine in `transcribe.cpp` that plausibly beat Whisper was replayed through the same
184-clip corpus. Three passes were needed, because two of the candidates are misleading at their
defaults:

1. **Defaults.** Fun-ASR and Granite emit no punctuation at all — they ship PNC/ITN off and Pressay
   never asked for them. Fun-ASR scored 8/46 collapsed long clips this way.
2. **PNC/ITN requested** where the model advertises the toggle. Fun-ASR went to 0/46.
3. **English-locked** for the Fun-ASR variants, which removed the foreign-language hallucinations
   auto-detect produced on near-silent clips.

Final numbers, best configuration per engine:

| Engine | Q6/Q8 size | Collapse | punct/caps | Vocab ✓/✗ | Foreign | Dropped | Median | p95 |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| **Fun-ASR MLT Nano** | 691 MB | **0/47** | .049/**.090** | **33/26** | 0 | 0 | **0.14 s** | 0.76 |
| Qwen3-ASR 1.7B | 2.19 GB | **0/47** | **.063/.102** | 23/36 | 0 | 0 | 0.44 s | 2.21 |
| Voxtral Mini 3B | 2.98 GB | 0/47 | .069/.099 | 34/25 | 0 | 0 | 1.16 s | 3.47 |
| Whisper V3 Turbo | 886 MB | 3/47 | .056/.080 | 30/29 | 0 | 0 | 0.39 s | 0.78 |
| Fun-ASR Nano | 850 MB | 1/47 | .049/.088 | 23/36 | 1 | 0 | 0.15 s | 0.76 |
| Canary Qwen 2.5B | 2.80 GB | 0/47 | .037/.082 | 16/34 | 0 | 0 | 0.30 s | 1.69 |
| Whisper Large V3 (full) | 1.67 GB | 3/47 | .055/.085 | 28/27 | 0 | 1 | 0.60 s | 1.81 |
| Canary 1B Flash | 1.05 GB | 0/46 | .046/.080 | 16/36 | 0 | **4** | 0.10 s | 0.47 |
| Parakeet Unified EN | 731 MB | 0/47 | .037/.085 | 13/47 | 0 | 1 | 0.06 s | 0.30 |
| Granite Speech 4.1 NAR | 2.50 GB | 0/46 | .056/**.000** | 22/31 | 0 | 1 | 0.18 s | 0.85 |

Metric definitions:

- **Collapse** — dictations over 15 s that came back with *exactly* zero terminal punctuation and
  zero capitals across 25+ words. The corpus breaks cleanly here: the affected clips sit at
  0.000/0.000 and the next-worst is 0.013/0.065.
- **punct/caps** — median per-word density of `.!?` and of capitalized words, on clips over 15 s.
- **Vocab ✓/✗** — canonical spellings against known mishearings for the terms in
  `CuratedVocabulary` (`Claude Code`, `CLAUDE.md`, `Kimi`, `SonarCloud`, …).
- **Foreign** — short clips answered with a predominantly non-Latin script.
- **Dropped** — real dictations (not near-silent clips) lost to an error.

### What decided it

Whisper Large V3 full was tested to check whether the collapse came from Turbo's shallower decoder
(4 blocks against 32). **It did not** — full V3 collapsed on 3/47 as well, on different clips, while
running 1.7× slower. That hypothesis is dead, and the collapse is not a decoder-depth artifact.

The NVIDIA family (Parakeet, Canary) is fast and never collapses but is markedly worse at technical
vocabulary — 13/47 for Parakeet Unified EN — which matches the 1.3 rejection of Parakeet TDT and the
public AA-WER ordering. Canary 1B Flash additionally dropped four genuine dictations between 7 and
16 seconds. Granite NAR emits no capital letters even with PNC requested.

An "error" is not automatically a defect. On near-silent 1.2 s clips Whisper returns `"you"`,
`"Thank you."` or `"."`, while Qwen3 and (now) Fun-ASR return nothing. Inserting nothing is the
correct behaviour; those rows are counted as empties, not failures.

### Limitations

- The manifest's `rawTranscript` is the **production Whisper output, not a reference**, so there is
  no hand-corrected ground truth here and **no true WER is reported**. Vocabulary is a substring
  proxy, not a critical-token error rate.
- The collapse definition is stricter than the 1.3 note's "7 of 47"; it reads Whisper Turbo at 3/47.
  The same detector is applied to every engine, so the comparison holds even though the absolute
  number differs from the earlier note.
- One repetition, one machine, one speaker, English. Latency figures are wall-clock on a warm model.

## Pressay 1.3 — Voxtral evaluation

For 1.3 we evaluated **Voxtral Mini 3B (Q4_K_M)** — an LLM-style multilingual audio model — against the shipping Whisper V3 Turbo, replaying the same 184-clip corpus through the `transcribe.cpp` engine. Parakeet was dropped in this release (quality not comparable to Whisper), so the shipped choice is Whisper (default) with Voxtral as an opt-in.

### Latency and memory

<p align="center">
  <img src="assets/asr-latency.svg" width="100%" alt="ASR latency comparison on shared 6.09 and 35.89 second recordings">
</p>

| Engine | 6.09 s clip | 35.89 s clip | Corpus median | Peak RAM |
| --- | ---: | ---: | ---: | ---: |
| Whisper V3 Turbo Q8 | 0.41 s | 0.90 s | 0.42 s | ~1.15 GB |
| Voxtral Mini 3B Q4_K_M | 0.75 s | 2.41 s | 0.75 s | ~4.8 GB |

Voxtral is roughly 2× slower and needs about 4× the memory (and a ~3 GB download vs ~0.9 GB). Both stay well under a second on typical clips. Higher-precision Voxtral quants (Q8 ≈ 7 GB RAM, BF16 ≈ 10 GB) were not pursued: the extra memory is unreasonable for a background dictation utility, and the failure modes below are behavioral, not precision-related.

### Quality

The corpus splits cleanly by clip length. Short clips (≤ 15 s) are **44% of clips but only ~34% of dictated words**; long clips (> 15 s) are 26% of clips but **~66% of dictated words**.

- **Short clips (≤ 15 s): effectively tied.** Both engines produce good output. Voxtral is slightly *worse* on the very shortest (≤ 2 s): 7 clips returned empty and 1 emitted an assistant-style refusal. Whisper handled those.
- **Long clips (> 15 s): Voxtral clearly better.** It keeps punctuation, capitalization, and completeness where Whisper intermittently collapses into an unpunctuated lowercase block — Whisper fully collapsed on **7 of 47** clips over 15 s (near-zero capitals and punctuation); Voxtral collapsed on **0**. Voxtral also handled proper nouns better (e.g. "Kimi" vs "Kimmy").

Raw word-for-word accuracy is close on both; the difference is formatting, completeness, and worst-case robustness on long-form dictation.

### Tuning

Voxtral runs greedy decoding and exposes only a `language` lever through the engine (its `pnc`/`itn` toggles are not controllable, and it has no initial-prompt path here). **Automatic language detection is safer than forcing English**: a near-silent clip that fabricated a full sentence under forced-English produced nothing under autodetect, and the 7 short-clip hard-errors became clean empties. Automatic is the app default. Whisper's own knobs were also swept (condition-on-previous-tokens, no-speech threshold, and a vocabulary initial-prompt) — none improved its long-clip collapse, and the prompt was a net negative — so Whisper ships at its defaults.

### Decision

Whisper V3 Turbo remains the default (light, safe on short clips, works on 8 GB Macs). Voxtral Mini is an opt-in for long-form dictation, downloaded on demand with a progress bar; only the selected model is held in memory. The rare Voxtral assistant-refusal on unintelligible short audio is filtered to insert nothing.

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

## Structuring bake-off

Before Structured Dictation shipped, `PressayBench structure` replayed a 438-clip private corpus through two candidates: the deterministic `TranscriptStructurer` rules and a formatting-only on-device Foundation Models prompt (words must be preserved verbatim; only punctuation, paragraphs, and bullets may change).

| Candidate | Clips changed | Fabricated words | Dropped words | Errors | Median latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rules | 93 / 438 | 0 | 0 | 0 | 0 ms |
| On-device LLM | 26 / 438 | 7 clips | 9 clips | 7 (guardrail/decoding) | 582 ms |

Even under a strictly formatting-scoped prompt, the language model completed a truncated dictation with invented words ("Maybe we could also talk about the" → "…the response in the next meeting."), silently dropped words on nine clips, and refused seven benign clips outright — while structuring fewer clips than the rules. That settled the choice: Structured Dictation is rule-based, and a fine-tuned local model was not pursued because it would have to beat a zero-defect, zero-latency baseline at its own game.

## Vocabulary tuner precision

`PressayBench tune-eval` replayed 680 transcripts (997 candidate terms) through the legacy and fixed deterministic matchers, with hand labels over every proposed rule:

| Variant | Proposed rules | Precision |
| --- | ---: | ---: |
| Legacy matcher | 20 | 94% (learned `codebase → Codex`) |
| Fixed matcher | 15 | 100% |

The fixed matcher (larger English stop list, minimum phonetic key length 4, recurrence scaled to phonetic distance) kept every genuinely useful rule — including `CloudMD → CLAUDE.md` and `codecs → Codex` — while rejecting the ordinary-word rewrites the legacy matcher had learned on real machines (`mix → macOS`, `correction → Markdown`, `colleagues → Codex`).

A frontier-LLM replay of the judge prompt over the same 997 candidates confirmed the two-tier design: the LLM contributed real rules the deterministic tier structurally cannot act on — ambiguity ties (`CloudCode` is phonetic distance 1 to both `Claude Code` and `CLAUDE.md`), too-short keys (`TLDA → TL;DR`), and distance-2 variants (`Sona Cloud`, `SornCloud`, `Sunr cloud → SonarCloud`) — while the anchor filter discarded 149 of its 184 raw findings as junk. The judgment tier earns its keep, but only behind that filter.

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
