# Portable meeting capture and analysis validation

The capture adapter streams distinct microphone and remote tracks as bounded mono 16 kHz chunks. It does not keep a recording-sized PCM vector. VAD uses two independent Silero sessions. Final Sortformer analysis runs in a separate, cancellable process after ASR stops; it reads temporary system audio through a read-only file mapping.

## Pinned provenance

- Runtime: [transcribe.cpp commit 41738b5](https://github.com/handy-computer/transcribe.cpp/tree/41738b58b305c08bdecf5379dccdc19a0f7c3b05), public VAD and diarization C APIs.
- Silero: [v6.2 F32 GGUF](https://huggingface.co/handy-computer/silero-vad-v6.2-gguf/tree/a9b2d61c20ae4ddf3644edb34969e8185a485448), 1,241,056 bytes; MIT. SHA-256 `0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6`.
- Sortformer: [4-speaker v2.1 F16 GGUF](https://huggingface.co/handy-computer/diar_streaming_sortformer_4spk-v2.1-gguf/tree/60ebab3ef7cae9869be0abcde13360347e96ba03), 236,606,560 bytes; NVIDIA Open Model License. SHA-256 `62faec7b99ad23e323087597604b50728abe85089b6364970b019a845547bf99`.
- Public fixtures: [JFK](https://github.com/handy-computer/transcribe.cpp/blob/41738b58b305c08bdecf5379dccdc19a0f7c3b05/samples/jfk.wav) and [two-speaker mix](https://github.com/handy-computer/transcribe.cpp/blob/41738b58b305c08bdecf5379dccdc19a0f7c3b05/samples/sortformer-2spk-mix.wav). No microphone recording or private corpus was used in these checks.

The separate analysis catalog pins revision, size and checksum. `build-portable-runtime.py` also verifies the exact checked-in `transcribe-sortformer-windowed.patch` SHA-256, rejects unexpected source changes, and bundles patch provenance. The worker requires the patch's capability symbol before loading Sortformer; an old unpatched runtime fails safely.

## Why the frontend patch is necessary

Upstream's speaker cache is bounded, but its public whole-clip path first builds whole-recording pre-emphasis, power spectrum and mel buffers. A three-hour quiet input exceeded 3,564,128 KiB RSS within 0.53 seconds; that unpatched test was stopped.

The patch computes only each existing streaming window's mel columns. Context extends beyond half the FFT window and includes the pre-emphasis predecessor; slice origins stay on the original hop grid. This preserves whole-clip boundary padding. It is restricted to Sortformer's `normalize=none` and constant padding; unsupported normalization fails. The existing model, operating preset, speaker cache and postprocessing remain unchanged. Explicit offline debug dumps retain the original whole-clip path.

Synthetic silence, tones and deterministic noise, lengths from 321 to 1,600,003 samples, and window sizes 1/17/3040 produced **15,096,960 exact mel comparisons, maximum difference zero** on Apple Silicon. The original whole-clip API and the patched API also produced identical speaker IDs and times on the public two-speaker fixture:

| Speaker | Intervals, seconds |
| --- | --- |
| 1 | 0.32–2.40; 7.36–9.36; 10.24–10.64 |
| 2 | 4.24–6.64; 9.76–12.00 |

Silero detected 234 of 344 JFK frames as speech. Results were exactly equal when feeding 160,000-sample versus 777-sample chunks. A separate silent track started at frame zero and remained below 0.1 speech probability. These are regression checks, not a general accuracy benchmark.

## Duration and memory measurements

Measured locally on Apple Silicon using the release native runtime with Metal and the debug Rust worker. Silent sparse files exercise the complete native analysis path. Time excludes model loading; RSS is sampled every 0.5 seconds.

| Recording | Analysis wall time | Peak RSS |
| --- | ---: | ---: |
| 3 hours | 37.20 s | 819,488 KiB |
| 8 hours | 99.95 s | 1,919,632 KiB |

Capture and analysis both cap meetings at eight hours. These are **not constant-RSS claims**: a three-hour mapping is 691.2 MB and an eight-hour mapping is 1.8432 GB. File-backed PCM pages can remain resident and are evictable by the OS. The frontend/model workspace is bounded; compact speaker probabilities and result segments grow with duration. The analysis worker caps returned segments at 100,000 and its host bounds reply size and inference time. Slow devices and complex real meetings may take longer than quiet fixtures.

Temporary PCM is owner-only and removed on completion/cancellation/drop. A separate owner-only sidecar holds its lifetime lock so Windows workers can read the audio through another handle. Startup cleanup takes that lock before deleting orphan spools, honors legacy PCM locks, skips active sessions and symlinks, and never matches unrelated filenames. Regression tests read live audio from another process, kill its owner to verify crash cleanup, and race concurrent cleaners against spool creation. A crash can leave audio until the next successful cleanup. Microphone-only voice notes do not create the system-audio spool.

## Reproduction

With the pinned model files available in `.build/analysis-models`:

```sh
python3 scripts/build-portable-runtime.py --metal
cargo build -p pressay-asr --bin pressay-analysis-worker
cargo test -p pressay-core analysis::tests
cargo test -p pressay-core --test analysis_lifecycle
python3 crates/pressay-asr/tests/analysis_smoke.py --runtime apps/desktop/src-tauri/runtime --models .build/analysis-models --samples .build/portable-asr/darwin-arm64/source/samples
python3 crates/pressay-asr/tests/analysis_memory.py --hours 8 --runtime apps/desktop/src-tauri/runtime --model .build/analysis-models/diar_streaming_sortformer_4spk-v2.1-F16.gguf
```

Frontend comparison on macOS:

```sh
c++ -std=c++17 -O2 -I .build/portable-asr/darwin-arm64/source/include -I .build/portable-asr/darwin-arm64/source/src scripts/tests/sortformer-window.cpp .build/portable-asr/darwin-arm64/source/src/transcribe-mel.cpp -framework Accelerate -o /tmp/pressay-sortformer-window-test
/tmp/pressay-sortformer-window-test
```

The same frontend test can compile on Linux without `-framework Accelerate`, using the runtime's scalar fallback. It has not been executed on Linux or Windows in this session.

## Capture checks and remaining hardware coverage

Six capture tests cover resampling at 8/44.1/48/96 kHz, synchronized track offsets, partial tails, overflow failure, protocol bounds, helper stop/drain and drop/reaping. The Swift helper compiles with Swift 6 warnings as errors at macOS 26 deployment. Windows capture compiles/clippy-checks for `x86_64-pc-windows-gnu`; Linux capture also typechecks. These checks do not establish microphone permission, actual audio routing or Bluetooth behavior on physical machines.

- macOS uses a real CoreAudio process tap excluding Pressay audio, with AVAudioEngine microphone voice processing and explicit fallback warnings. Helper packaging/signing and audio usage descriptions remain required.
- Windows uses CPAL's native WASAPI output-endpoint loopback. Echo cancellation is unavailable in this adapter, and loopback includes the application's own output.
- Linux uses the active PulseAudio/PipeWire-pulse sink monitor through `pactl`/`parec`, not a user-selected placeholder device. It requires `pulseaudio-utils`; timestamp alignment is monotonic/sample-count based with the requested capture latency, not hardware timestamp synchronization. Echo cancellation is unavailable.
- Device changes, missing input, queue overflow and helper failures surface explicitly. Capture receivers are bounded and stop/cancel/drop closes the devices and reaps helper processes. Physical-device QA across all three systems remains necessary.
