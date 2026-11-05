#!/usr/bin/env python3
"""Build an isolated Pressay Preview installer. No release publication or signing credentials."""
from pathlib import Path
import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
DESKTOP = ROOT / "apps/desktop"
NATIVE = DESKTOP / "src-tauri"

def run(*args, cwd=ROOT):
    subprocess.run([str(a) for a in args], cwd=cwd, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-bundle", action="store_true", help="Stage native resources and compile only")
    args = parser.parse_args()
    system = platform.system()
    metal = system == "Darwin" and platform.machine() == "arm64"
    run(sys.executable, ROOT / "scripts/build-portable-runtime.py", *(["--metal"] if metal else []))
    if metal:
        # Preserve the shipping Mac dictation engine; the portable CPU backend is
        # an explicit Windows/Linux choice, not an unannounced Mac model change.
        url = "https://github.com/Oruk-AI/orukeet/releases/download/v0.1.1/nemo-speech-orukeet-0.1.1-macos-arm64-metal.tar.gz"
        digest = "aaf30beadcdb6ac2b6004bbe20d4a7601aa640c3f67be0e4668370a76fddcbc1"
        cache = ROOT / ".build/asr-runtime/orukeet-0.1.1.tar.gz"
        cache.parent.mkdir(parents=True, exist_ok=True)
        if not cache.exists():
            with tempfile.NamedTemporaryFile(dir=cache.parent, delete=False) as download:
                temporary = Path(download.name)
                try:
                    with urllib.request.urlopen(url, timeout=60) as response:
                        shutil.copyfileobj(response, download)
                    download.flush()
                    with temporary.open("rb") as downloaded:
                        if hashlib.file_digest(downloaded, "sha256").hexdigest() != digest:
                            raise RuntimeError("Orukeet runtime checksum mismatch")
                    temporary.replace(cache)
                finally:
                    temporary.unlink(missing_ok=True)
        with cache.open("rb") as file:
            if hashlib.file_digest(file, "sha256").hexdigest() != digest:
                raise RuntimeError("Orukeet runtime checksum mismatch")
        destination = NATIVE / "runtime/orukeet"
        with tempfile.TemporaryDirectory(dir=cache.parent) as extracted:
            with tarfile.open(cache) as archive:
                archive.extractall(extracted, filter="data")
            roots = list(Path(extracted).iterdir())
            if len(roots) != 1 or not roots[0].is_dir():
                raise RuntimeError("Unexpected Orukeet archive layout")
            shutil.copytree(roots[0], destination, dirs_exist_ok=True)
    run("cargo", "build", "--locked", "--release", "-p", "pressay-asr", "-p", "pressay-desktop")
    binary = "pressay-asr-worker.exe" if system == "Windows" else "pressay-asr-worker"
    (NATIVE / "binaries").mkdir(exist_ok=True)
    shutil.copy2(ROOT / "target/release" / binary, NATIVE / "binaries" / binary)
    if args.no_bundle:
        return
    npm = shutil.which("npm.cmd" if system == "Windows" else "npm")
    if not npm:
        raise RuntimeError("Node.js/npm is required to package the desktop installers")
    run(npm, "ci", cwd=DESKTOP)
    run(npm, "run", "build", cwd=DESKTOP)

if __name__ == "__main__":
    main()
