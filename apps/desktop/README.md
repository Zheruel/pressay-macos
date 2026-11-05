# Pressay cross-platform preview

This is the Tauri vertical slice for [#31](https://github.com/Zheruel/pressay-macos/issues/31).
It uses the shared Rust core and real native microphone/ASR/insertion paths.
**It is not yet the complete replacement for the Swift app.** See the
[architecture decision](../../docs/architecture/001-shared-rust-core.md) for the
support matrix and remaining parity requirements.

Requirements: stable Rust (1.90+ declared; CI uses current stable), Node.js 24,
Python 3.11+, CMake, and a native C++ toolchain. Linux also needs the dependencies
listed in `.github/workflows/ci.yml`. The packaged Mac preview targets Apple
Silicon/macOS 26; Windows packaging uses Visual Studio Build Tools/WebView2.

From the repository root:

```sh
cargo test --workspace --locked
python3 scripts/build-desktop.py
```

Installers land in `target/release/bundle`. These preview artifacts have separate
identity `dev.localflow.preview`, are not production updates, and do not claim
trusted signing. The manual `Desktop preview installers` workflow packages
macOS, Windows and Linux without publishing a release.

For development, first stage the runtime and worker with the build command,
then build a debug worker and run the shell:

```sh
cargo build -p pressay-asr
cd apps/desktop
npm ci
npm run dev
```

On Mac, development reuses `.build/Pressay.app`'s speech runtime if present.
`PRESSAY_WORKER_PATH` and `PRESSAY_RUNTIME_DIR` can select a different locally
built worker/runtime; they are development process environment overrides, never
renderer commands. Model weights download only when requested from setup.

Hold **Ctrl+Shift+Space** in a text field, speak, release. Setup requires actual
capture, recognition, insertion and matching text in its practice field. Model
preparation alone cannot complete onboarding. Cancel from the app during an
operation. Existing Mac users retain their configurable hold key and full
feature set in the original Swift app.

Export existing Mac data using **General → Export for cross-platform preview…**
in the updated native app, then import it under **General** in the preview.
The export contains private history/notes: keep it local. Credentials are not
exported. Existing source stores remain intact, and importing the same file
again is harmless. Imported unsupported model choices are retained, not replaced.

Wayland is detected and blocked with an explanation until its portal integration
is implemented. Use X11 for the current Linux vertical slice; this is a preview
limitation, not the intended final Linux support policy.
