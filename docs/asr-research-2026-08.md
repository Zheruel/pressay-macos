# Better transcription for Pressay

> Historical research: the Apple-native cleanup experiment and automatic vocabulary learning described below were removed on October 31, 2026. The dictionary now accepts only user-supplied entries.

## Verdict

The local model is already near the ceiling of what is available on-device, and the win is in biasing and post-correction, not a new model. Twelve model candidates and eight biasing mechanisms were checked against your stack; none survived. Fun-ASR MLT Nano stays the default, and the highest-value change is four lines in `CuratedVocabulary.swift` closing documented mishearings the alias map currently misses, followed by making that tier phonetic instead of literal. The only decode-time lever with real upside — Fun-ASR's native hotword prompt — exists upstream in the model but is not exposed by transcribe.cpp, and that is a patch to someone else's C++, not a config change.

## Do this first

### 1. Patch the documented-but-unaliased mishearings

`docs/benchmarks.md` records the observed wrong renderings for the eight scored terms: `Akimi`, `Kemi`, `kimimi`, `run pod`, `Rampod`, and (from `.build/bench/tune-compare.md`) `SonnerCloud`, `Markkamp`. `Sources/PressayCore/CuratedVocabulary.swift` covers `akimi`, `kimmy`, `rumpod`, `soonercloud`, `sooner cloud` — it does **not** cover `kemi`, `kimimi`, `run pod`, `rampod`, `sonnercloud`, `markkamp`.

- **Gain:** unquantified but strictly non-negative and it targets the exact eight terms the 86% metric scores. These are already-observed failures on your own corpus with no alias entry.
- **Effort:** six lines in one string literal. Zero download, zero latency, zero risk to the tuner.
- **Risk:** `run pod` as an alias is the only one worth thinking about — it is two ordinary English words and will rewrite "run pod" in any context. Scope it if you ever dictate about Kubernetes pods.
- **Verify:** `swift run PressayBench vocab` prints per-term fire counts and a `never fired` list over the corpus; re-run before and after.

### 2. Make the curated tier phonetic at apply time

`VocabularyParser.normalize` (Sources/PressayCore/TextProcessing.swift:50) is literal whole-word regex substitution over `aliases + [preferred]`. `PhoneticKey.swift` exists and already collapses exactly your failures — `kemi` and `kimi` both key to `KM`, `run pod` and `RunPod` both key to `RNPT`, `Rampod` keys to `RMPT` at distance 1 — but it is referenced **only** from `VocabularyTuner.swift`, the offline suggestion pipeline. The runtime path never calls it.

The same defect is in the LLM pass: `PromptPolisher.swift:75` filters the vocabulary with `raw.range(of: term, options: .caseInsensitive)`. That is a literal substring gate, so "Rampod" never surfaces "RunPod" as a candidate for the on-device model to fix. The correction layer can only fix casing on terms the ASR already spelled right.

- **Gain:** closes the whole mishearing class rather than one alias at a time, and survives any future model swap — which the literal aliases explicitly do not, since they were audited against Fun-ASR's specific error forms.
- **Effort:** moderate. Add a `PhoneticKey.distance(key, anchorKey) <= 1` fallback pass in `normalize` after the literal pass, and seed `PromptPolisher`'s filter from the same match. `VocabularyTuner`'s fixed matcher was measured at 100% precision over 997 candidates, so the distance check itself is already validated on your data.
- **Risk:** this is the real one. `PhoneticKey` is aggressive (vowel-drop, c/g→K, d→T, w/h drop), so short keys collide easily — a two-letter key like `KM` will match ordinary words. Gate it on: token count matching the anchor, candidate not in `EnglishWordList`, and minimum key length. Ship it behind the bench harness, not on vibes.
- **Verify:** `PressayBench tune-eval` against the 184-clip corpus, plus false-positive count on clips containing none of the eight terms.

### 3. Fun-ASR hotwords — file the upstream patch, do not wait for it

Fun-ASR-MLT-Nano's upstream `get_prompt(hotwords=…)` injects a plain-text term list into the bundled Qwen3-0.6B decoder prompt before the audio embeddings, and the model was contextually SFT-trained to use it. This is the single highest-leverage decode-time lever available on the model that already scores 86%. It is blocked purely by a missing runtime parameter: `src/arch/funasr_nano/capabilities.cpp` on main sets only `CANCELLATION` and `ITN`, and `transcribe.h` documents `INITIAL_PROMPT` as "Today: whisper only". `Sources/TranscribeCpp/Family.swift:53` confirms `RunExtension` has exactly one case, `.whisper`.

- **Gain:** the closest published analogue is ContextASR-Bench, where fine-grained entity-list prompt injection into an LLM-decoder ASR cut named-entity misses ~2.4x on English. **Not deep-verified**, and not measured on Fun-ASR specifically.
- **Effort:** a string change in transcribe.cpp plus a capability bit plus a run-extension kind, then a `WhisperRunOptions`-equivalent in `Sources/TranscribeCpp/Family.swift`. Not your repo, so treat it as an issue/PR against handy-computer, not a sprint item.
- **Risk, and it is concrete:** `transcribe.h`'s `effective_max_audio_ms` contract makes `funasr_nano` a hard-context-cap family — the ceiling is decoder context minus the fixed prompt minus a generation reserve. Every hotword you add mechanically lowers max audio per run, meaning more chunks against `Domain.swift:212`'s 60s split, meaning more join seams. You would be paying in complaint #2 to buy complaint #1. Also: ContextASR-Bench documents models parroting prompt terms that were never spoken, so any implementation needs a guard.
- **Framing matters:** for LLM-decoder ASR, a bare space-joined list is close to useless and can leak into output; label it (`Technical terms: …`). Unverified, medium-confidence.

## Local models worth testing

| Model | GGUF | Size | English/entity evidence | Effort |
|---|---|---|---|---|
| Cohere Transcribe 03-2026 | yes, ungated, Apache-2.0 | 1.55 GB Q4_K_M / 1.97 GB Q6_K | LibriSpeech 1.25%; entity claim is unquantified chart images only | drop-in (arch is in your pinned v0.1.3) |
| canary-1b-v2 | yes, CC-BY-4.0 | 889 MB Q6_K | LibriSpeech 1.94% only; family measured 53-56% on your corpus | drop-in |
| parakeet-*-1.1b tier (tdt/ctc/rnnt/tdt_ctc) | yes | ~1.1B | none; 0.6B sibling measured 56% | drop-in |
| Granite Speech 4.1 2B **re-test with keyword biasing** | yes | 1.86 GB Q6_K | IBM publishes entity F1 74.2→84.1 Gigaspeech, 89.1→96.1 LibriSpeech-clean *with* keyword biasing | blocked — transcribe.cpp doc says verbatim "Keyword biasing: No (upstream supports via prompt; not exposed in v1)" |
| ARK-ASR-3B | GGUF exists (cstr), CrispASR-only | — | current Open ASR English short-form SOTA | large — no `arkasr` arch in transcribe.cpp |
| MOSS-Transcribe-preview-2B | GGUF exists, CrispASR-only | — | #3 leaderboard, 4.87% WER | large — transcribe.cpp's `moss` arch is the *Diarize* sibling, not this |
| Qwen3-ASR-0.6B | yes, Apache-2.0 | 690 MB Q6_K | 1.7B sibling measured 57% | drop-in, but no route to 86% |
| Moonshine tiny/base/streaming-medium | yes, MIT | 35-534 MB | LibriSpeech + edge-latency only | drop-in, 27-267M params, no biasing hooks |
| Distil-Whisper | **no credible GGUF exists** | — | — | n/a |
| Kyutai STT, GLM-ASR, Higgs-STT, Gemma-4 audio, Ultravox, Phi-4-multimodal, Step-Audio | **no transcribe.cpp arch** | — | — | requires a second runtime |

Cohere is the only row I would spend a benchmark run on, and only for the data point. Expect ~55-70% on terms: it is a FastConformer/Transformer-decoder — the same family as every model you measured at 36-57% — while both your 80%+ scorers are LLM-decoder. Its decoder prompt is a hard-coded token vector containing `<|noitn|>` with no params path, so ITN is off with no toggle, against a stack where `docs/benchmarks.md` records ITN-on as what moved long-clip collapse from 8/46 to 0/46. Latency is a genuine wash (150ms vs 156ms on jfk, Q8_0, same M4 Max, same doc set). It exposes no beam, temperature, hotwords, or prompt, so there is no recovery if it lands short — and swapping models invalidates every audited alias in `CuratedVocabulary` plus every accumulated `LearnedVocabularyStore` rule.

**Do not chase leaderboards.** The Open ASR normalizer (`normalizer/data_utils.py`) lowercases, strips punctuation, and merges compound words: `GitHub`→`github`, `macOS`→`macos`, and `run pod` vs `RunPod` scores as **zero errors**. Every failure mode you care about except outright wrong words is invisible in every number on that board. Your own data already shows the correlation is negative — canary-qwen-2.5b (5.63 avg WER) scored 53%, Qwen3-ASR-1.7B (5.76) scored 57%, and your 691 MB 86% winner is not on the leaderboard at all.

## Not worth it

- **Whisper `initial_prompt`** — already swept on your corpus and recorded as a net negative (`docs/benchmarks.md:200`); reachable only on Whisper Turbo, 11 points behind the incumbent. ProfASR-Bench independently finds encoder-decoder Whisper is "nominally promptable" but essentially ignores context.
- **Voxtral prompt path** — `accepts_ext_kind = nullptr` at both v0.1.3 and main. The capability bit is an upstream bug; the path is unreachable, not merely risky.
- **MOSS-Transcribe-Diarize** — 1.96% LibriSpeech is *worse* than the incumbent's 1.69%, 2.5x slower (388ms vs 156ms), Chinese-optimized, and crashed on Apple Silicon Metal until a fix merged to main today. No release contains it; v0.1.3 is still latest.
- **Granite Speech 4.1 2B Plus** — IBM's own card: "doesn't provide punctuation and capitalization." Returns `macos`, `github`, `sonarcloud` by design. Disqualified, do not test.
- **Apple SpeechAnalyzer `contextualStrings`** — A/B'd on 60 of your clips: **0 of 60 transcripts changed**, both wirings, including a 50x term-repetition run. Fixed 0 of 3 real mis-renderings ("Claude Code"→"blood code", "SonarCloud"→"sooner cloud"). Harness kept at `/private/tmp/claude-501/-Users-tinzeljar-Documents-whisper/a5ab04f6-4552-487f-99d6-899ab72311a8/scratchpad/abtest/`.
- **Apple `SFCustomLanguageModelData`** — inert at every safe weight (byte-identical output), destructive at weight 1.0 (58/60 clips regressed; "This model is a joke"→"Metal"). Baseline is already worse than yours and 3x slower. Gotcha worth recording: Float32 input causes an uncatchable SIGTRAP inside `SpeechRecognizerWorker.preRunRecognition()`; it needs Int16.
- **FluidAudio CTC vocabulary boosting** — +365ms flat per 15s window on a 0.14s median, and its payoff needs word timestamps that `GGMLTranscriber.swift:193` disables (`options.timestamps = .none`). Its own docs publish the adverse case for short acronyms — your exact vocabulary.
- **sherpa-onnx** — ships Fun-ASR-**Nano**-2512 (your 60% measurement), not MLT (86%). Hotwords would need to recover 26 points to break even. 948 MB, onnxruntime dependency, no Metal backend.
- **Argmax Pro SDK** — capability is real, pricing floor is a non-starter for an indie app. Ruled out on cost, not capability.
- **WhisperKit (OSS)** — Whisper-only, no model you lack, no biasing beyond the initial prompt you already have.
- **CrisperWhisper 2.0** — the only model publishing a rare-word recall number (96.1%), but the license blocks an MIT app and the architecture is deliberately incompatible with standard Whisper GGUF loaders.
- **SenseVoice** (non-OSS FunASR model license, 30s cap), **MedASR** (17.88% LibriSpeech, gated), **Voxtral Small 24B** (14.30 GB Q4_K_M), **cohere-transcribe-arabic**, **Breeze-ASR-25** (Taiwanese Mandarin), **nemotron-3.5-asr-streaming-0.6b** (0.6B FastConformer, same family as your 56%).

## Cloud fallback

Not recommended — all of these break "microphone audio never leaves the Mac," and none has a published entity-accuracy number. At ~2 h/month, cost is not the deciding axis for any of them; retention is.

| Provider | Keyterms | $/mo at 2h | Retention against your promise |
|---|---|---|---|
| Soniox v5 | −50..+50 per-phrase boost | ~$0.20 | headline 1.25% is *semantic* WER — ignores casing and punctuation, so non-comparable |
| Mistral Voxtral Transcribe 2 | 100 terms, "optimized for English" | ~$0.36 | Premier API-only, no weights; ~4% FLEURS is read speech, no biasing gain published |
| AssemblyAI U3.5 Pro (async) | 1,000 terms, +$0.05/hr | ~$0.52 | **no ZDR on async at all**; untied retention is indefinite. Un-prompted MER: Organization 18.99%, Name 24.08% — worse than your 14% miss rate |
| Deepgram Nova-3 | 500 tokens (~35 terms fits) | ~$0.52 | pay-as-you-go is enrolled in model training **by default**; needs `mip_opt_out=true` on every request |
| ElevenLabs Scribe v2 | 1,000 terms × 50 chars, +$0.05/hr | ~$0.54 | cleanest of the four (ZDR mode + EU residency). The 20s minimum billable unit only triggers above 100 keyterms, so your 35-term list avoids it |

The one thing worth an hour: push the existing 184-clip corpus through Deepgram or Scribe v2 with `CuratedVocabulary` as keyterms and score it with `PressayBench`. Deepgram's free credit covers it at ~$0.16 for the full 36.33 minutes. If it does not come back at 95%+ raw on the eight tracked terms, the cloud question is settled and nothing got built.

## Sources

**Runtime and models**
- https://github.com/handy-computer/transcribe.cpp — MIT, 1677 stars, pushed 2026-08-03; v0.1.3 (2026-07-12) still latest
- `src/arch/funasr_nano/capabilities.cpp` — CANCELLATION + ITN only, no INITIAL_PROMPT
- `src/arch/voxtral/model.cpp:1466` (v0.1.3), `:1599` (main) — `accepts_ext_kind = nullptr`
- `src/arch/cohere/model.cpp` ~845-858 — hard-coded decoder prompt incl. `<|noitn|>`; `docs/models/cohere-transcribe-03-2026.md`
- https://github.com/QwenAudio/Fun-ASR and `funasr/models/fun_asr_nano/model.py` — upstream `get_prompt(hotwords=…)`
- https://huggingface.co/ibm-granite/granite-speech-4.1-2b — keyword biasing, entity F1 74.2→84.1

**Benchmark methodology**
- https://raw.githubusercontent.com/huggingface/open_asr_leaderboard/main/normalizer/data_utils.py — the normalizer that erases your failure modes
- https://arxiv.org/abs/2507.05727 — ContextASR-Bench, NE-WER/NE-FNR, 2.4x entity-miss reduction and the hallucination caveat
- https://arxiv.org/abs/2512.23686 — ProfASR-Bench, Whisper prompt biasing near-zero effect
- https://arxiv.org/abs/2508.20700 — phonetic-edit-distance vs generative NEC headroom

**This repo**
- `Sources/PressayCore/CuratedVocabulary.swift`, `TextProcessing.swift:50` (literal `normalize`), `PhoneticKey.swift`, `VocabularyTuner.swift`
- `Sources/PressayPostProcessing/PromptPolisher.swift:75` — literal substring vocabulary gate
- `Sources/PressayTranscription/GGMLTranscriber.swift:193` — `timestamps = .none`
- `Sources/TranscribeCpp/Family.swift:53` — single `.whisper` RunExtension
- `Sources/PressayBench/Bench.swift:605` (`vocab` audit), `AsrTune.swift:69` (`--prompt`)
- `docs/benchmarks.md:200`, `.build/bench/tune-compare.md` (the `whi-prompt` arm)