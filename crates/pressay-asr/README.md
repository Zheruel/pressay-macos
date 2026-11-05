# Pressay speech worker

`pressay-asr-worker <model-id> <model-path> <runtime-directory>` is a blocking,
single-model subprocess. It uses the same C++ adapter, pinned headers and JSONL
protocol as `Runtime/Sources/PressayASRWorker/Worker.swift`. It does not link a
recognition library into the UI process or require Python.

The parent must serialize requests, impose deadlines, kill the child when a job
is cancelled, and reap it before replacing a model. The worker validates the
request envelope, 16 kHz mono little-endian PCM, finite samples, and a 60-second
maximum. A `truncated: true` reply requires splitting/retrying; it is not success
with a shorter transcript. Model preparation reports `ready` only after loading
and a one-second silent warm-up have succeeded. Native diagnostics go to stderr.

| Model | Runtime location below the supplied directory | Platforms |
| --- | --- | --- |
| `moss`, `parakeetUltra`, `qwen3ASR17` | `transcribe/libtranscribe.dylib`, `transcribe/transcribe.dll`, or `transcribe/libtranscribe.so` | macOS, Windows, Linux |
| `orukeet` | `orukeet/lib/libnemo_speech_asr_c.dylib` | Apple Silicon macOS |
| `megaASR` | Use the existing Swift worker | Apple Silicon macOS |

Build the native runtime from the same commit used by
`scripts/build-asr-runtime.sh`, `41738b58b305c08bdecf5379dccdc19a0f7c3b05`. The
vendored C API is **0.4.0**, independently of the older Swift package dependency.
The adapter rejects a different `transcribe_version()` rather than loading it
against incompatible structs. Ship every required ggml library beside
`libtranscribe`/`transcribe.dll`. `LoadLibraryExW` restricts Windows dependency
lookup to that directory and the system directory.

For a portable CPU runtime, configure the upstream source with
`TRANSCRIBE_BUILD_SHARED=ON`, `TRANSCRIBE_METAL=OFF`,
`TRANSCRIBE_USE_OPENMP=OFF`, `TRANSCRIBE_USE_SYSTEM_BLAS=OFF`, and
`TRANSCRIBE_X86_CONSERVATIVE=ON`; disable tools, examples and tests for packaging.
Use `$ORIGIN` as Linux install RPATH. Package-specific Vulkan/CUDA builds can
replace the runtime without changing this process protocol, but require separate
driver, CPU-feature and accuracy validation. This crate does not claim that the
optimized Mac Orukeet/MLX implementations are portable.

`python3 scripts/build-portable-runtime.py` builds that CPU configuration and
stages it under `apps/desktop/src-tauri/runtime/transcribe`. On Apple Silicon,
pass `--metal` to keep GPU acceleration. The script fetches the exact source
commit, stages required libraries and licenses, and preserves the previous
runtime if staging fails. Quit development workers before replacing a runtime.

`cargo test -p pressay-asr` exercises malformed/oversized requests, PCM bit
patterns and bounds, truncation, Unicode, consecutive jobs, failed startup and
reply bounds without downloading speech models. These protocol tests do not
measure speech accuracy, GPU performance or clean-machine native integration.

References: [upstream build documentation](https://github.com/handy-computer/transcribe.cpp/blob/41738b58b305c08bdecf5379dccdc19a0f7c3b05/README.md),
[pinned CMake options](https://github.com/handy-computer/transcribe.cpp/blob/41738b58b305c08bdecf5379dccdc19a0f7c3b05/CMakeLists.txt).
