#!/usr/bin/env python3
"""Publish this release to Macs still running the retired Swift app.

That app updates through Sparkle from releases/latest/download/appcast.xml and trusts
only the EdDSA key below. This writes a one-item feed for Pressay-macos-arm64.zip,
signed with that key, and checks the signature before anything is published.
"""
from __future__ import annotations
import argparse
import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

# SUPublicEDKey compiled into every Swift release (1.11.0 through 1.14.2).
SWIFT_APP_PUBLIC_KEY = "dRS1x+MqR+iIG7NAi+tLCOUerzo0eJbw6BUt0bs7xm0="
REPOSITORY = "https://github.com/Zheruel/pressay-macos"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def verify(feed: Path, archive: Path, build: str):
    from nacl.signing import VerifyKey
    enclosures = ET.parse(feed).getroot().findall("./channel/item/enclosure")
    if len(enclosures) != 1:
        raise SystemExit("The Sparkle feed must contain exactly one update")
    enclosure = enclosures[0]
    version = enclosure.get(f"{SPARKLE}version") or ET.parse(feed).getroot().findtext(f"./channel/item/{SPARKLE}version")
    if version != build:
        raise SystemExit(f"The Sparkle feed advertises build {version}, expected {build}")
    signature = base64.b64decode(enclosure.get(f"{SPARKLE}edSignature", ""))
    VerifyKey(base64.b64decode(SWIFT_APP_PUBLIC_KEY)).verify(archive.read_bytes(), signature)
    print("Verified the Sparkle update against the Swift app's public key.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Release folder containing Pressay-macos-arm64.zip")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--build", required=True, help="CFBundleVersion of the packaged app")
    args = parser.parse_args()
    tools = Path(os.environ["SPARKLE_TOOLS_DIR"])
    key = os.environ["SPARKLE_KEY_FILE"]
    archive = args.directory / "Pressay-macos-arm64.zip"
    with tempfile.TemporaryDirectory(prefix="pressay-sparkle-") as scratch:
        # generate_appcast reads every archive in its folder; give it only this one.
        shutil.copy2(archive, scratch)
        subprocess.run([
            tools / "generate_appcast", "--ed-key-file", key, "--maximum-deltas", "0",
            "--download-url-prefix", f"{REPOSITORY}/releases/download/{args.tag}/",
            "--link", REPOSITORY,
            "--full-release-notes-url", f"{REPOSITORY}/releases/tag/{args.tag}",
            scratch,
        ], check=True)
        shutil.copy2(Path(scratch) / "appcast.xml", args.directory / "appcast.xml")
    verify(args.directory / "appcast.xml", archive, args.build)


if __name__ == "__main__":
    main()
