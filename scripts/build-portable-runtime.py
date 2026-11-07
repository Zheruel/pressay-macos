#!/usr/bin/env python3
"""Build the pinned transcribe.cpp runtime for the experimental desktop shell.

Requires Python 3.10+, Git, CMake, and a C++17 compiler (Visual Studio on Windows).
This builds native code only. It never downloads speech model weights.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

REVISION = "41738b58b305c08bdecf5379dccdc19a0f7c3b05"
REPOSITORY = "https://github.com/handy-computer/transcribe.cpp.git"
ROOT = Path(__file__).resolve().parent.parent
PATCH = ROOT / "scripts/patches/transcribe-sortformer-windowed.patch"
PATCH_SHA256 = "b96f342f86a7a72987700f818ee1f221867b73065d60ff2fcdcf939c15ee0be3"


def run(*args: str | Path) -> None:
    subprocess.run([str(arg) for arg in args], check=True)


def build(output: Path, jobs: int, metal: bool) -> None:
    system = platform.system()
    if system not in {"Darwin", "Windows", "Linux"}:
        raise SystemExit(f"Unsupported build platform: {system}")
    if metal and (system != "Darwin" or platform.machine() not in {"arm64", "aarch64"}):
        raise SystemExit("--metal requires an Apple Silicon Mac")
    for command in ("git", "cmake"):
        if not shutil.which(command):
            raise SystemExit(f"Missing build dependency: {command}")
    stage = ROOT / ".build" / "portable-asr" / f"{system.lower()}-{platform.machine()}"
    source, binary, install = stage / "source", stage / "build", stage / "install"
    source.mkdir(parents=True, exist_ok=True)
    if not (source / ".git").exists():
        run("git", "init", "--quiet", source)
        run("git", "-C", source, "remote", "add", "origin", REPOSITORY)
    exists = subprocess.run(
        ["git", "-C", str(source), "cat-file", "-e", f"{REVISION}^{{commit}}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0
    if not exists:
        run("git", "-C", source, "fetch", "--depth", "1", "origin", REVISION)
    run("git", "-C", source, "checkout", "--detach", REVISION)
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != REVISION:
        raise SystemExit("Native runtime revision mismatch")
    patch = PATCH.read_bytes()
    if hashlib.sha256(patch).hexdigest() != PATCH_SHA256:
        raise SystemExit("Sortformer runtime patch checksum mismatch")
    changes = subprocess.check_output(["git", "-C", str(source), "diff", "--binary", "HEAD", "--"])
    if changes and changes != patch:
        raise SystemExit(f"Native runtime checkout contains unexpected changes; inspect it before rebuilding: {source}")
    if not changes:
        run("git", "-C", source, "apply", "--check", PATCH)
        run("git", "-C", source, "apply", PATCH)
    if subprocess.check_output(["git", "-C", str(source), "diff", "--binary", "HEAD", "--"]) != patch:
        raise SystemExit("Native runtime patch did not apply exactly")
    options = [
        "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={install}",
        "-DTRANSCRIBE_BUILD_SHARED=ON", "-DTRANSCRIBE_BUILD_TESTS=OFF",
        "-DTRANSCRIBE_BUILD_EXAMPLES=OFF", "-DTRANSCRIBE_BUILD_TOOLS=OFF",
        f"-DTRANSCRIBE_METAL={'ON' if metal else 'OFF'}", "-DTRANSCRIBE_VULKAN=OFF",
        "-DTRANSCRIBE_CUDA=OFF", "-DTRANSCRIBE_USE_OPENMP=OFF",
        "-DTRANSCRIBE_USE_SYSTEM_BLAS=OFF", "-DTRANSCRIBE_X86_CONSERVATIVE=ON",
        "-DTRANSCRIBE_GGML_BACKEND_DL=OFF", "-DGGML_NATIVE=OFF",
    ]
    if system == "Linux":
        options += ["-DCMAKE_INSTALL_RPATH=$ORIGIN", "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"]
    elif system == "Darwin":
        minimum = json.loads((ROOT / "apps/desktop/src-tauri/tauri.conf.json").read_text())["bundle"]["macOS"]["minimumSystemVersion"]
        options += ["-DCMAKE_INSTALL_RPATH=@loader_path", "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON",
                    f"-DCMAKE_OSX_DEPLOYMENT_TARGET={minimum}", f"-DGGML_METAL_MACOSX_VERSION_MIN={minimum}"]
        if metal:
            options += ["-DGGML_METAL_EMBED_LIBRARY=ON"]
    run("cmake", "-S", source, "-B", binary, *options)
    run("cmake", "--build", binary, "--config", "Release", "--target", "transcribe", "--parallel", str(jobs))
    if install.exists():
        shutil.rmtree(install)
    run("cmake", "--install", binary, "--config", "Release")

    pattern = "*.dll" if system == "Windows" else "*.dylib" if system == "Darwin" else "*.so*"
    libraries = sorted(path for path in install.rglob(pattern) if path.is_file())
    expected = "transcribe.dll" if system == "Windows" else "libtranscribe.dylib" if system == "Darwin" else "libtranscribe.so"
    if not any(path.name == expected for path in libraries):
        raise SystemExit(f"Build did not install {expected}; refusing to stage an incomplete runtime")
    if system == "Darwin":
        run(sys.executable, ROOT / "scripts/verify-macos-deployment.py", install)
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Build all files first. An interrupted compile leaves the last working
    # runtime intact; replacing individual libraries while a worker runs is unsafe.
    with tempfile.TemporaryDirectory(prefix="pressay-runtime-", dir=output.parent) as temporary:
        staging = Path(temporary)
        for library in libraries:
            shutil.copy2(library, staging / library.name, follow_symlinks=True)
        shutil.copy2(source / "LICENSE", staging / "transcribe.LICENSE")
        shutil.copy2(source / "ggml" / "LICENSE", staging / "ggml.LICENSE")
        if (install / "share/licenses").exists():
            shutil.copytree(install / "share/licenses", staging / "licenses")
        (staging / "revision.txt").write_text(REVISION + "\n", encoding="utf-8")
        (staging / "pressay-patches.sha256").write_text(PATCH_SHA256 + "  " + PATCH.name + "\n", encoding="utf-8")
        shutil.copy2(PATCH, staging / PATCH.name)
        previous = output.with_name(output.name + ".previous")
        if previous.exists():
            raise SystemExit(f"Previous runtime backup exists; inspect and remove it before rebuilding: {previous}")
        if output.exists():
            output.rename(previous)
        try:
            shutil.copytree(staging, output)
        except BaseException:
            if output.exists():
                shutil.rmtree(output)
            if previous.exists():
                previous.rename(output)
            raise
        if previous.exists():
            shutil.rmtree(previous)
    print(f"Built pinned native runtime: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "apps/desktop/src-tauri/runtime/transcribe")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 2, 8))
    parser.add_argument("--metal", action="store_true", help="Build Metal on Apple Silicon; otherwise use portable CPU")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    build(args.output, args.jobs, args.metal)


if __name__ == "__main__":
    main()
