#!/usr/bin/env python3
"""Seal a desktop .app before creating installers; ad-hoc by default."""
from pathlib import Path
import argparse
import os
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}

def run(*args):
    subprocess.run([str(value) for value in args], check=True)

def seal(app: Path, identity: str):
    app = app.resolve()
    if app.suffix != ".app" or not (app / "Contents/Info.plist").is_file():
        raise ValueError("Expected a built macOS .app bundle")
    run(sys.executable, ROOT / "scripts/verify-macos-deployment.py", app)
    with (app / "Contents/Info.plist").open("rb") as handle:
        executable = plistlib.load(handle)["CFBundleExecutable"]
    entitlements = ROOT / "packaging/desktop/entitlements.plist"
    # Ad-hoc signatures provide local integrity, not Gatekeeper trust. They have
    # no Team ID for hardened library validation; reserve that policy for a real
    # Developer ID identity, which signs every library with the same team.
    trusted = identity.startswith("Developer ID Application:")
    arguments = ["codesign", "--force", "--sign", identity, "--options", "runtime" if trusted else "0"]
    if trusted:
        arguments += ["--timestamp"]
    for path in sorted(app.rglob("*"), key=lambda path: len(path.parts), reverse=True):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as handle:
            if handle.read(4) not in MAGIC:
                continue
        options = ["--entitlements", entitlements] if path.name in (executable, "PressayMeetingCapture") else []
        run(*arguments, *options, path)
    for framework in sorted(app.rglob("*.framework"), key=lambda path: len(path.parts), reverse=True):
        if not framework.is_symlink():
            run(*arguments, framework)
    # Never use --deep to sign. The outer seal is written only after nested code.
    run(*arguments, "--entitlements", entitlements, app)
    run("codesign", "--verify", "--deep", "--strict", app)
    if not (app / "Contents/_CodeSignature/CodeResources").is_file():
        raise ValueError("Signed app is missing its resource seal")
    print(f"Verified {'Developer ID' if trusted else 'local'} signature and resource seal: {app}")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity", default=os.environ.get("APPLE_SIGNING_IDENTITY") or "-")
    args = parser.parse_args()
    seal(args.app, args.identity)

if __name__ == "__main__":
    main()
