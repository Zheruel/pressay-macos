<p align="center">
  <img src="Config/PressayIconSource.png" width="132" alt="Pressay app icon">
</p>

<h1 align="center">Pressay</h1>

<p align="center">
  <strong>Private, quality-first voice dictation and meeting notes for macOS.</strong><br>
  Hold. Speak. Release. Your words appear at the cursor.
</p>

<p align="center">
  <a href="https://github.com/Zheruel/pressay-macos/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Zheruel/pressay-macos/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-111827?logo=apple&logoColor=white">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-7C3AED"></a>
</p>

Pressay is a native hold-to-talk dictation app for people who write to coding agents, chats and docs all day. Speech is transcribed on your Mac. Optional AI Cleanup, on your own Claude key or ChatGPT plan, turns the transcript into clean text. Pressay also records meetings: a live on-device transcript of you and the call, then a written-up note.

No account, no telemetry, no subscription. Audio never leaves the Mac.

<p align="center">
  <img src="docs/assets/hero.jpg" width="100%" alt="Pressay's recording pill grows out of the MacBook notch while the dictated sentence appears at the cursor">
</p>

> [!IMPORTANT]
> Requires an Apple Silicon Mac on macOS 26 or newer. Builds are not notarized yet, so building from source is the most reliable install.

## Features

- **Dictation anywhere.** Hold Right Option (configurable), speak, release. The text lands in the field that was focused when you started, in native, web and Electron apps. The clipboard is preserved.
- **Accurate local speech recognition.** Qwen3-ASR 1.7B runs on Metal through `transcribe.cpp`. Voxtral Mini 3B, Whisper Large V3 Turbo (100 languages), Qwen3-ASR 0.6B and Fun-ASR MLT Nano are also available.
- **AI Cleanup (optional).** Fixes misheard words, removes fillers and false starts, and formats lists and paragraphs, without changing what you said. Runs on your Anthropic API key or your ChatGPT Plus/Pro plan. Only text is sent.
- **Notetaker.** Offers to take notes when a call starts. Records your mic as "You" and everything the Mac plays as "Others", so it works with Zoom, Meet, Teams or Slack and no bot joins the call. When the call ends you get a titled note with a summary, decisions, action items with owners, and open questions. Ask anything about one meeting or all of them.
- **A dictionary that learns.** Retype a word Pressay got wrong and it learns the spelling. Names that keep recurring are suggested. Both the on-device rules and AI Cleanup use the dictionary.
- **Fast start.** The mic stays warm for 45 s after a dictation, with a 0.5 s pre-roll, so your first word is never clipped. The start sound plays only once real audio arrives.

## How it works

<p align="center">
  <img src="docs/assets/architecture.svg" width="100%" alt="Pressay architecture: audio is recorded and transcribed on the Mac, cleaned by AI or on-device rules, and pasted at the cursor; only transcript text is sent to Claude or ChatGPT when AI Cleanup is on">
</p>

Without AI Cleanup, a deterministic on-device pipeline applies the dictionary, cleans up common speech artifacts and, for longer dictations, adds punctuation, paragraphs and bullet lists. With AI Cleanup on, the model does that job. Terminals and dictations of three words or fewer always skip the AI. On a timeout, error or usage limit, Pressay inserts the on-device result.

## Transcription

<p align="center">
  <img src="docs/assets/speech-models.svg" width="100%" alt="Judged accuracy on 24 real dictations: Wispr Flow cloud 9.05, Qwen3-ASR 1.7B on-device 9.00, Voxtral Mini 8.91, Whisper V3 Turbo 8.77, Qwen3-ASR 0.6B 7.32, Fun-ASR 6.95">
</p>

The default Qwen3-ASR 1.7B matches Wispr Flow's cloud transcript within judge noise, running entirely on your Mac. Pick another model in Settings for more languages or a smaller download. Details: [`docs/benchmarks.md`](docs/benchmarks.md).

## AI Cleanup

<p align="center">
  <img src="docs/assets/ai-cleanup.jpg" width="100%" alt="What you said: um so I think we should uh move the the standup to ten and also ping dana about the pricing doc. What Pressay types: I think we should move the standup to 10 and also ping Dana about the pricing doc.">
</p>

Choose a provider under **Settings › AI Cleanup**.

| Provider | Model | Quality | Added latency | Cost |
| --- | --- | ---: | ---: | --- |
| Anthropic API key | **Claude Haiku 5.5** (recommended) | 8.7 | ~1.0 s | under $1/month at 100 dictations/day |
| | Claude Sonnet 5.5 | 8.9 | ~1.3 s | ~$5/month |
| ChatGPT Plus or Pro | **GPT-6.1 Sol** (recommended) | best on plan | ~3.3 s | included in your plan's usage limits |
| | GPT-6 Luna | | ~2.5 s | included |
| None | On-device rules | 7.6 | none | free |

<p align="center">
  <img src="docs/assets/ai-cleanup-benchmark.svg" width="100%" alt="Cleanup quality out of 10: Claude Sonnet 5.5 8.9, Claude Haiku 5.5 8.7, Wispr Flow 7.7, on-device rules 7.6">
</p>

Scores are 0–10 from a blind, judged replay of 102 real dictations; Wispr Flow's own cleanup scored 7.7 on the same clips. In a separate replay of the ChatGPT options, Sol scored 7.96, Sonnet 7.85, Haiku 7.67 and Luna 7.42. Method and data: [`docs/claude-cleanup/`](docs/claude-cleanup/README.md).

ChatGPT sign-in runs in your browser (OAuth with PKCE). Pressay never sees your password. Your API key is stored in the macOS keychain.

## Meeting notes

<p align="center">
  <img src="docs/assets/meeting-notes.jpg" width="100%" alt="The Notetaker showing a meeting note with a summary, decisions and action items with owners, and a live transcript of You and Others">
</p>

When Zoom, Teams, Meet, FaceTime, Slack or another call app starts using the microphone, Pressay offers to take notes. You can also click **Start Notetaker** in the menu bar or on the Notetaker page of the Pressay window.

- A small notepad floats above your apps with the timer, the live transcript and your own notes.
- Your mic is recorded with echo cancellation. Call audio comes from a Core Audio process tap; the first meeting asks for **System Audio Recording** permission.
- Each utterance is transcribed on the Mac as soon as the speaker pauses.
- When the call ends (or you click **Stop**), the AI writes the note. Each meeting has **Summary**, **Transcript** and **My Notes** tabs, and an **Ask anything** box. Past meetings are grouped by day and searchable, and you can ask questions across all of them.
- Pick the model under the gear on the Notetaker page: Claude Haiku 5.5 (recommended) or Sonnet 5.5 with an API key, GPT-6.1 Sol (recommended) or GPT-6 Luna with a ChatGPT plan. Only providers you have set up are listed.
- Audio is never saved. Only the transcript and your notes go to the AI provider, to write the note or answer a question.

The meeting prompt was tuned over six blind-judged rounds on 12 meetings: [`docs/notes/meetings/`](docs/notes/meetings/README.md).

## Pressay vs. Wispr Flow

| | Pressay | Wispr Flow |
| --- | --- | --- |
| Speech recognition | On your Mac | Cloud |
| Audio leaves your Mac | Never | Yes |
| Account required | No | Yes |
| Price | Free, MIT. AI Cleanup uses your own key or ChatGPT plan | Subscription |
| Cleanup quality (102 dictations, 0–10) | 8.7 Haiku · 8.9 Sonnet | 7.7 |
| Meeting notes without a bot | Yes, on-device transcript | Yes |
| Works offline | Yes, without AI Cleanup | No |
| Platforms | macOS 26+, Apple Silicon | macOS, Windows, iOS |

## Privacy

| Data | Where it goes | Retention |
| --- | --- | --- |
| Microphone and call audio | Processed on the Mac only | Dictation audio 7 days by default; meeting audio never stored |
| Dictation transcript | On the Mac. Sent to your AI provider only if AI Cleanup is on | 30 days by default |
| Meeting transcript and your notes | On the Mac. Sent to your AI provider when you stop, to write the note | Until you delete the note |
| Text around the cursor | Read briefly to find the insertion target | Never stored |
| Telemetry | None | — |

The speech model downloads once from Hugging Face. After that, dictation works offline.

**Keep the microphone ready** keeps the audio stream open for 45 s after a dictation, so macOS shows the orange mic indicator during that time. Only a half-second ring buffer is kept, and it is overwritten continuously. The mic closes on sleep and screen lock, yields when another app plays audio, and the feature can be turned off in Settings.

## Install from source

Requirements: Apple Silicon, macOS 26+, Xcode 26+ and about 3 GB of free space.

```bash
git clone https://github.com/Zheruel/pressay-macos.git
cd pressay-macos
make test
make install
```

`make app` builds `.build/Pressay.app` without installing; `make dmg` builds a disk image. On first launch Pressay asks for Microphone, Accessibility (to insert text) and Input Monitoring (for the hold key), then downloads and warms the speech model.

Without a paid Apple Developer account, builds are ad-hoc signed and macOS may ask for permissions again after each update. For stable permissions on one Mac, run once:

```bash
./scripts/create-local-signing-certificate.sh
```

## Dictionary

Add words under **Settings › Dictionary**, one per line. Optionally add what they get misheard as:

```text
Supabase
myRepository <= my repository
```

Learned words and suggestions appear in the same pane and can be removed at any time.

## Development

```bash
make build
make test
```

```text
Sources/
├── PressayApp/             SwiftUI/AppKit app: audio, overlay, insertion, notes
├── PressayCore/            Cleanup, AI providers, vocabulary, prompts, retention
├── PressayTranscription/   transcribe.cpp-backed ASR
├── PressayPostProcessing/  Experimental on-device benchmark module
├── PressayBench/           Corpus replay and tuning CLI
└── TranscribeCpp/          Vendored Swift wrapper for the native runtime
```

CI runs the tests and a full app build on every pull request. Pushing a `vX.Y.Z` tag that matches `Config/Info.plist` publishes a DMG release. The bundle identifier stays `dev.localflow.app` so permission grants from earlier builds carry over.

Benchmarks: [ASR](docs/benchmarks.md), [AI Cleanup](docs/claude-cleanup/README.md), [meeting notes](docs/notes/meetings/README.md). Keep audio, transcripts and API keys out of the repository. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Known limitations

- macOS 26+ and Apple Silicon only.
- Meeting transcripts label speakers only as You and Others; there is no diarization.
- Insertion relies on Accessibility; some custom editors behave differently.
- Accuracy varies with microphone, accent and noise. Review text before running destructive agent commands.
- No notarized binaries yet.

## Acknowledgements

- [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) for the ggml/Metal speech runtime.
- [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), [Fun-ASR MLT Nano](https://huggingface.co/FunAudioLLM/Fun-ASR-MLT-Nano-2512), [Whisper Large V3 Turbo](https://huggingface.co/openai/whisper-large-v3-turbo) and [Voxtral Mini 3B](https://huggingface.co/mistralai/Voxtral-Mini-3B-2507) for the speech models.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Source code is [MIT](LICENSE); model weights keep their own licenses.
