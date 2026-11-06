#!/usr/bin/env python3
"""Build an isolated Pressay Preview installer. No release publication or signing credentials."""
from pathlib import Path
import argparse
import hashlib
import json
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

def run(*args, cwd=ROOT, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-bundle", action="store_true", help="Stage native resources and compile only")
    args = parser.parse_args()
    system = platform.system()
    metal = system == "Darwin" and platform.machine() == "arm64"
    if system == "Darwin":
        minimum = json.loads((NATIVE / "tauri.conf.json").read_text())["bundle"]["macOS"]["minimumSystemVersion"]
        os.environ["MACOSX_DEPLOYMENT_TARGET"] = minimum
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
    (NATIVE / "binaries").mkdir(exist_ok=True)
    for name in ["pressay-asr-worker", "pressay-analysis-worker"]:
        binary = name + (".exe" if system == "Windows" else "")
        shutil.copy2(ROOT / "target/release" / binary, NATIVE / "binaries" / binary)
    if system == "Darwin":
        arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        run("xcrun", "swift", "build", "--package-path", ROOT / "Runtime", "--build-system", "swiftbuild", "--disable-sandbox", "-c", "release")
        runtime_bin = Path(subprocess.check_output(["xcrun", "swift", "build", "--package-path", str(ROOT / "Runtime"), "--build-system", "swiftbuild", "-c", "release", "--show-bin-path"], text=True).strip())
        shutil.copy2(runtime_bin / "PressayASRWorker", NATIVE / "binaries/PressayASRWorker")
        metallib = runtime_bin / "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        if not metallib.is_file() or not metallib.stat().st_size:
            raise RuntimeError("Swift MLX build is missing its compiled Metal library")
        # Helpers launched from Resources/binaries resolve Bundle.main to that
        # directory. Keep SwiftPM resources beside them, as the pinned MLX loader
        # requires; include dependency resource bundles, not only MLX's shaders.
        for bundle in runtime_bin.glob("*.bundle"):
            shutil.copytree(bundle, NATIVE / "binaries" / bundle.name, dirs_exist_ok=True)
        run("codesign", "--force", "--sign", os.environ.get("APPLE_SIGNING_IDENTITY", "-"), "--options", "runtime", NATIVE / "binaries/PressayASRWorker")
        helper = NATIVE / "binaries/PressayMeetingCapture"
        run("xcrun", "swiftc", "-swift-version", "6", "-target", f"{arch}-apple-macos26.0", "-O", "-parse-as-library", NATIVE / "native/MeetingCapture.swift", "-o", helper)
        run("codesign", "--force", "--sign", os.environ.get("APPLE_SIGNING_IDENTITY", "-"), "--options", "runtime", helper)
    if system == "Darwin":
        run(sys.executable, ROOT / "scripts/verify-macos-deployment.py", NATIVE / "binaries", NATIVE / "runtime", ROOT / "target/release/pressay-desktop")
    if args.no_bundle:
        return
    npm = shutil.which("npm.cmd" if system == "Windows" else "npm")
    if not npm:
        raise RuntimeError("Node.js/npm is required to package the desktop installers")
    run(npm, "ci", cwd=DESKTOP)
    if system == "Darwin":
        # Tauri's default DMG can copy a bundle without a complete ad-hoc app
        # resource seal. Build only the app, seal it, then use our verified artwork.
        run(npm, "run", "build", "--", "--bundles", "app", cwd=DESKTOP)
        settings = json.loads((NATIVE / "tauri.conf.json").read_text())
        app = ROOT / "target/release/bundle/macos" / (settings["productName"] + ".app")
        run(sys.executable, ROOT / "scripts/sign-desktop-macos.py", app)
        dmg = ROOT / "target/release/bundle/dmg" / f"Pressay-Desktop-{settings['version']}-macos-{platform.machine()}.dmg"
        environment = os.environ | {"PRESSAY_SKIP_BUILD": "1", "PRESSAY_DMG_APP": str(app),
            "PRESSAY_DMG_VERSION": settings["version"], "PRESSAY_DMG_OUTPUT": str(dmg)}
        if os.environ.get("APPLE_SIGNING_IDENTITY"):
            environment["SIGNING_IDENTITY"] = os.environ["APPLE_SIGNING_IDENTITY"]
        run(ROOT / "scripts/package-dmg.sh", env=environment)
    else:
        run(npm, "run", "build", cwd=DESKTOP)

if __name__ == "__main__":
    main()
