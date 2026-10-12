# ASR options ranked — August 2026

Follow-up to `asr-research-2026-08.md`, run after two constraints changed: the
transcribe.cpp/GGUF requirement was lifted, and the goal became quality-first
subject to ~4GB RAM (prefer ≤3GB) locally, or low cost in the cloud.

Five parallel researchers: Mac runtimes, previously arch-blocked models, the
leaderboard sweep, biasing routes, cloud pricing.

## Verdict

The best local move is not a new model. It is turning on the contextual-biasing
channel that your current 86% model already has and transcribe.cpp never exposed.
`mlx-community/Fun-ASR-MLT-Nano-2512-8bit` is 1.55GB, Apache-2.0, and `mlx-audio`
reproduces the upstream `热词列表` hotword prompt byte-identically — the form the
model was contextually SFT-trained on across >50K hours.

Two independent lines of evidence say biasing dominates model choice here.
ContextASR-Bench: fine-grained term lists cut entity-miss rate 59–66% relative.
The gap between the best and fifth-best model on any leaderboard is a fraction
of that.

The correction that matters most: **an LLM decoder is what buys entity accuracy,
not scale.** FireRedASR ships two models with the same encoder lineage and
different decoders — AED vs LLM. Entity failure rate goes 69.1% → 32.7%
([arXiv:2507.05727](https://arxiv.org/abs/2507.05727)). The 2026 leaderboard's
entire open top-25 is now LLM-decoder; the FastConformer/TDT family you measured
at 36–57% has been pushed out completely.

## Local top 5

Ranked on: published biasing gain > decoder architecture > punctuation/casing >
RAM. Leaderboard WER is used only to break ties, for reasons in *Why the numbers
lie* below.

### 1. Fun-ASR MLT Nano 2512 on MLX, hotwords on

Your incumbent, unblocked. 1.55GB at 8-bit (1.32GB at 4-bit, but that leaves the
SenseVoice encoder unquantized — prefer 8-bit). ~1.2GB peak RAM.

- Keeps every audited `CuratedVocabulary` alias and `LearnedVocabularyStore` rule
  valid. No other option on this list does.
- `mlx-audio` PR #855 (merged 2026-07-24) exposes `hotwords=[...]`, persisted
  across long-audio chunks, plus the `itn` toggle your benchmarks credit with
  moving collapse from 8/46 to 0/46.
- Side effect worth having: mlx-audio's default chunk duration is 1200s against
  the 60s split `Domain.swift:212` forces today, and the Qwen3-0.6B decoder's
  40960-token context makes ~40 hotwords cost ~200 tokens. The "hotwords eat your
  audio length" tradeoff that exists on transcribe.cpp does not exist here.
- **Verify first:** `mlx-audio`'s `fun_asr_nano` module has the true hotword slot
  but gates languages via a map named for the Nano checkpoint;
  `mlx-audio-plus` supports MLT but only offers a generic `initial_prompt`
  prefix — and it produced the `mlx-community` MLT quants. The checkpoints are
  documented as architecturally identical, so converting MLT with upstream's
  converter should work. That one check is the difference between the trained
  biasing channel and an untrained prefix.
- **Honest gap:** no English hotword gain has been published by anyone. The tech
  report's "recall 0.75 → 1.0" is a with-RL vs without-RL delta — both rows have
  hotwords on, and there is no unbiased baseline row. Chinese, unbaselined.
- **Cost:** Python. There is no Swift-native Fun-ASR, and FluidAudio ports
  SenseVoice and Paraformer but not this.

### 2. IBM Granite Speech 4.1 2B (base variant), keyword list on

~2.3GB at 8-bit, ~1.6GB at 4-bit. Apache-2.0. Runs under `mlx-audio`
(`granite_speech`, `_build_prompt(user_prompt=...)` takes arbitrary text) and
llama.cpp.

The only model in this landscape where the vendor publishes a before/after
biasing table:

- Earnings22 keyword F1 **68.8 → 81.5**
- Gigaspeech entity F1 **74.2 → 84.1**, LibriSpeech-clean **89.1 → 96.1**
- Cap-F1 89.7–98.5 across sets — the only vendor-published capitalization metric
  found anywhere

The card's own phrasing is your use case verbatim: keyword list biasing for
"names, acronyms and technical jargon."

**The catch:** you measured it at 57% unbiased. Biasing has to be worth 29 points
to reach parity. It probably isn't. But this is the cheapest *measurable* answer
to "how much is prompt biasing actually worth on my corpus", and that number
informs everything else.

**Correction to the prior doc:** it was rejected on "IBM's own card says no
punctuation or capitalization." That sentence is on the `-plus` and `-nar` cards.
The base model has native prompt-controlled truecasing, and your own
`benchmarks.md:47` records non-zero punct/caps for it (`.046/.083`) against
Granite NAR's `.000`.

### 3. Qwen3-ASR-1.7B + context

~2.0GB at 4-bit, ~2.6GB at 8-bit. Apache-2.0.

Measured at 57% on your corpus — but with the context channel off, since nothing
in the GGUF path could reach it. `Qwen/Qwen3-ASR-0.6B-hf` documents
`apply_transcription_request(prompt="Vocabulary: ...")` for biasing toward
"domain-specific vocabulary, names, or background information."

**This is the only candidate with a pure-Swift path.** `mlx-audio-swift` (MIT,
743 stars, swift-tools 6.2, macOS 14+) exposes `context:` as a public parameter
on `Qwen3ASR.generate`, spliced into the system turn — no Python anywhere. If the
biasing experiment succeeds on route 1 but you don't want to ship Python, this is
the architecture that proves the pattern in-process.

No published gain, and 29 points is a lot to make up.

### 4. MOSS-Transcribe-Diarize 0.9B

MLX 5-bit is **1.05GB total** — a third of your current footprint. Apache-2.0.

Best size-to-quality ratio on the board: entity-subset mean 6.35 at 0.91B params,
beating models three times its size. LLM-decoder. Punctuation and casing in
output, hotword prompting, 90-minute single-pass so no long-clip collapse risk.
Also has CoreML FP16/INT8, ONNX, GGUF, and a dedicated C++ port.

Untested on your corpus, no published biasing number. But it is the cheapest
model to try and the only one that would make the app smaller.

### 5. Higgs Audio v3 STT 2.68B

~2.9GB at 8-bit, ~1.6GB at 4-bit. Apache-2.0, English-only, Whisper-large-v3
encoder + Qwen3-1.7B decoder. Second on entity subsets.

**One blocking risk:** its default prompt is literally *"Transcribe the speech.
Output only the spoken words in lowercase with no punctuation."* A model whose
trained default is lowercase-unpunctuated is a poor bet against a metric that
scores `macOS` and `GitHub`. Overridable, but whether casing survives the
override is unverified. Check that before spending a bench run.

### Ruled out, with the reason

- **Voxtral Mini 3B + llama.cpp prompt slot** — the most interesting experiment
  available (your 81% model plus the lever it lacked), but ~4.8GB peak RAM.
  Over ceiling. `mtmd` also warns of breaking changes.
- **ARK-ASR-3B** — strong (avg 4.64) but no biasing support of any kind, 4B
  breaks 8-bit, MLX ports are one-user conversions.
- **MOSS-Transcribe-preview-2B** — best Earnings22 in class, but the card admits
  RL fine-tuning *on the Open ASR Leaderboard training splits*. Treat the rank as
  unearned. No biasing, no MLX module.
- **CrisperWhisper 2.0** — cc-by-nc-4.0. License-blocked for an MIT app.
- **Cohere Transcribe 03-2026** — conformer encoder-decoder, i.e. the 36–57%
  family, and `mlx-audio` has no cohere module despite the card's claim.
- **Phi-4-multimodal** — no Apple Silicon audio path at all (flash-attn/CUDA
  pinned, ONNX is CUDA+DirectML, the MLX conversion is vision-only).
- **The entire NeMo/FluidAudio/sherpa-onnx ContextGraph branch** — bounded below
  your incumbent. TurboBias measures unbiased Canary AED at 54.7 and RNN-T at
  56.0 rare-word F on Earnings21; you measured 54% and 56% on the same
  architectures. That agreement makes their *biased* ceilings load-bearing:
  66.2 and 74.0, both with GPU beam search. Neither reaches 86.
- **Whisper `initial_prompt`** — ProfASR-Bench, Whisper-small: no-prompt 9.98%,
  oracle prompt 9.92%. The oracle upper bound buys 0.06pp. Adversarial prompts
  don't reliably hurt either — the model simply ignores it.
- **sherpa-onnx** — ships Fun-ASR *Nano* (your 60%), not MLT, and is effectively
  CPU-only on Apple Silicon: on M2 Max, CoreML RTF 0.470 vs CPU 0.427.

## Cloud top 5

At 2h/month **every serious option is under $2** — the spread between cheapest
and most expensive credible provider is ~$1.30/month, and free credits alone
cover years (Deepgram's $200 signup ≈ 546 hours; AssemblyAI's free tier is 185
hours). Cost is not the deciding variable. Keyterm strength, formatted output,
and data retention are.

| # | Provider | 2h/mo | 10h/mo | Keyterms | Why this rank |
|---|---|---|---|---|---|
| 1 | AssemblyAI Sync (Universal-3.5 Pro) | $0.90 | $4.50 | 2048 chars, **free on sync** | Only provider publishing a *measured* biasing gain on names and identifiers (~21% relative WER reduction, "largest improvements on names and identifiers") and the only published short-clip latency: **134ms p50**. Punctuation and format default true. |
| 2 | Deepgram Nova-3 | $0.73 | $3.66 | 500 tokens (~100 words) | Only genuine per-request zero-retention switch in the field (`mip_opt_out=true`, any tier). Via Cloudflare Workers AI it's **$0/mo at 2h** with the full parameter set and no keyterm surcharge. |
| 3 | Azure Fast Transcription | $0.72 | $3.60 | 500 phrases, free | Only provider with contractual zero retention as the *default* — no flag, no tier gate. Display-form output, so casing and punctuation are unavoidable. |
| 4 | ElevenLabs Scribe v2 | $0.53 | $2.64 | **1000 terms** | Best measured accuracy among biasable models (2.2% AA-WER) and the largest keyterm budget. Ranked below its accuracy because ZDR is Enterprise-only and discretionary. |
| 5 | Speechmatics Enhanced | $1.50 | $7.50 | 1000 phrases + `sounds_like` | The only custom dictionary with **phonetic hints** — register "RunPod" as "run pod", "Kimi" as "kee-mee". That is precisely your failure mode. Held at #5 by price and no sync endpoint. |

Runner-up: **OpenAI `gpt-transcribe`** ($0.27/hr, 2h = $0.54) has a dedicated
`keywords` parameter with no documented cap and the cleanest privacy story in the
field — training No, abuse retention None, ZDR-eligible on any tier. Misses the
top five only because its billing increment is now completely undocumented.

**Keep any glossary at ≤100 keyterms on ElevenLabs** — above that a 20s minimum
billable duration per request kicks in, a 2.6x multiplier at your clip
distribution. Note also an unconditional 20% surcharge at *any* keyterm count,
which the prior doc missed.

### Do not use

- **AWS Transcribe** — 15s per-request minimum (2.06x your real audio) and trains
  by default with Organizations-policy-only opt-out.
- **Groq** — cheapest by far and the fatal flaw is exactly the axis you weight
  most: no vocabulary biasing, only Whisper's 224-token stylistic prompt. Plus a
  10s billing minimum.
- **Together AI, Fireworks** — no keyterm parameters; Fireworks has no STT
  product at all.
- **Gladia** — custom vocabulary is post-hoc phoneme matching (architecturally
  weaker at recovering a term the model never hypothesized), 12-month default
  retention, and the billing increment is undocumented.
- **Gemini free tier / Mistral free tier** — both train on input by default;
  Gemini's table says "Used to improve our products: Yes" with human reviewers.
- **Whisper-family anywhere** — documented hallucination on silence and short
  clips, exactly your 0.5s and 15s+ failure modes.

### Corrections to the prior doc's cloud section

- **Soniox 1.25%** — right about it being semantic WER (punctuation, casing,
  contractions, number formats all ignored), wrong about the model: it's
  attributed to `stt-rt-v4`, and **v5 has no published WER at all**. Also,
  Soniox bills context as input tokens — an 8,000-token context resent per clip
  is ~200x the audio cost.
- **Deepgram opt-out** — confirmed, plus a new wrinkle: a Deepgram collaborator
  states opting out forfeits a 50% discount, so the real opted-out rate could be
  ~$0.58/hr rather than $0.288. No opt-out rate card exists.
- **AssemblyAI ZDR** — confirmed absent on async (1-hour minimum TTL). New: Sync
  retention is undocumented anywhere, and Sync is the endpoint you'd use.

## Why the numbers lie

The Open ASR Leaderboard normalizer calls `s.lower()` as its literal first
operation, then strips punctuation. `macos`, `MacOS`, `Mac OS` and `macOS` all
score identically; a model emitting zero punctuation is not penalized one basis
point. `standardize_acronyms` plus a compound-word table can collapse `git hub`
into `github` — your exact failure mode, laundered.

Every cloud vendor number is normalized too. Speechmatics publishes a worked
example showing **41% WER before normalization vs 8% after** on the same audio.

So on the leaderboard, only the architecture and size columns are trustworthy.
And there is no public benchmark for developer dictation, code identifiers, or
software proper nouns — ProfASR-Bench's Technology domain is its *easiest*
(2.3% WER for Whisper-small) and evaluates only four obsolete systems. **Your
own 184-clip corpus is the best evidence that exists on this question.**

## What to actually do

**Local:** convert MLT with `mlx-audio`'s converter, run the 184-clip corpus
twice — bare, then with `hotwords=CuratedVocabulary` — and score both with
`PressayBench`. That resolves the single unmeasured variable in the top-ranked
route. If hotwords move 86% meaningfully you know what to build; if they don't,
the "should I change runtime" question is closed for a day's work.

**In parallel, needing no new model or dependency:** the `PromptPolisher.swift:75`
literal-substring gate. DeRAGEC (ACL 2025 Findings) gets 28% relative WER
reduction from phonetic retrieval + LLM filtering, training-free. A related
Interspeech 2025 result moves rare-word recall 80.5% → 94.2%, with the explicit
finding that phonetic context is what *prevents* over-correction. You already
ship `FoundationModels.SystemLanguageModel` and `PhoneticKey.swift`; they are
just not connected.

**Cloud:** if you want the comparison, 20 clips against AssemblyAI Sync,
Deepgram Nova-3, and ElevenLabs Scribe v2 with your glossary loaded costs nothing
against free credits. Score on *formatted* output — casing, punctuation, exact
match on the eight terms — since every published number is blind to two of those
three axes.

## Failure modes to design against

- **Prompt-term parroting.** ContextASR-Bench documents LLM-decoder ASR emitting
  entity-list terms never spoken; sherpa-onnx has an open issue where silent
  audio plus hotwords returns the hotwords as transcript. Your near-silent clips
  need a guard.
- **LLM over-correction.** Measured at 64% error rate before mitigation, 35%
  after (NVIDIA Voice Memory, July 2026 — note CC-BY-NC-SA, cite don't use).
  Phonetic grounding is the documented fix.
- **Short-term false triggers.** "Codex" ⊂ "code", "Kimi" ~ "kimchi". Measure
  false positives on clips containing *none* of your terms, not just recall on
  the eight.
