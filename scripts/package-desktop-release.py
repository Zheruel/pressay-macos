#!/usr/bin/env python3
"""Prepare and verify signed desktop release artifacts. Never publishes a release."""
from __future__ import annotations
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
DESKTOP = ROOT / "apps/desktop"
NATIVE = DESKTOP / "src-tauri"
CLI = DESKTOP / "node_modules/@tauri-apps/cli/tauri.js"
REPOSITORY = "https://github.com/Zheruel/pressay-macos"
REQUIRED_TARGETS = {"darwin-aarch64", "windows-x86_64", "linux-x86_64", "linux-x86_64-deb"}

def run(*args, cwd=ROOT, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)

def require(condition, message):
    if not condition:
        raise ValueError(message)

def config():
    value = json.loads((NATIVE / "tauri.conf.json").read_text())
    version = value["version"]
    require(re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", version), "Invalid desktop version")
    cargo = tomllib.loads((ROOT / "Cargo.toml").read_text())["workspace"]["package"]["version"]
    npm = json.loads((DESKTOP / "package.json").read_text())["version"]
    require(version == cargo == npm, "Tauri, workspace Cargo, and desktop package versions must match")
    return value

def public_key():
    value = os.environ.get("PRESSAY_UPDATE_PUBLIC_KEY", "").strip()
    require(value, "Set PRESSAY_UPDATE_PUBLIC_KEY to the Tauri updater public key")
    lines = base64.b64decode(value, validate=True).decode("utf-8").splitlines()
    require(len(lines) == 2 and lines[0].startswith("untrusted comment:"), "Invalid Tauri public key encoding")
    packet = base64.b64decode(lines[1], validate=True)
    require(len(packet) == 42 and packet[:2] == b"Ed", "Invalid Minisign public key")
    return value, packet

def verify_signature(artifact: Path, signature: str, version: str):
    """Decode Minisign's envelope; libsodium verifies both Ed25519 signatures."""
    from nacl.signing import VerifyKey
    _, public = public_key()
    lines = base64.b64decode(signature.strip(), validate=True).decode("utf-8").splitlines()
    require(len(lines) == 4 and lines[0].startswith("untrusted comment:") and lines[2].startswith("trusted comment: "), "Invalid Tauri signature envelope")
    packet = base64.b64decode(lines[1], validate=True)
    global_signature = base64.b64decode(lines[3], validate=True)
    require(len(packet) == 74 and packet[:2] in (b"Ed", b"ED") and len(global_signature) == 64, "Invalid Minisign signature")
    require(packet[2:10] == public[2:10], "Updater signing key does not match the compiled public key")
    trusted = lines[2][17:]
    versions = [part.removeprefix("version:") for part in trusted.split("\t") if part.startswith("version:")]
    require(versions == [version], "Signature is not bound to the advertised app version")
    verifier = VerifyKey(public[10:])
    if packet[:2] == b"ED":
        with artifact.open("rb") as handle:
            payload = hashlib.file_digest(handle, "blake2b").digest()
    else:
        payload = artifact.read_bytes()
    verifier.verify(payload, packet[10:])
    verifier.verify(packet[10:] + trusted.encode("utf-8"), global_signature)

def sign(artifact: Path, version: str):
    require(os.environ.get("TAURI_SIGNING_PRIVATE_KEY") or os.environ.get("TAURI_SIGNING_PRIVATE_KEY_PATH"), "Set the Tauri updater signing key through the environment")
    subprocess.run(["node", str(CLI), "signer", "sign", "--app-version", version, str(artifact)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    signature = Path(str(artifact) + ".sig").read_text().strip()
    verify_signature(artifact, signature, version)
    return signature

def preflight(output: Path):
    value = config()
    key, _ = public_key()
    require(CLI.is_file(), "Run npm ci in apps/desktop first")
    # Catch a mismatched key before an expensive build, without printing secrets.
    with tempfile.TemporaryDirectory(prefix="pressay-signing-check-") as directory:
        sample = Path(directory) / "signing-check"
        sample.write_bytes(b"Pressay updater signing preflight\n")
        sign(sample, value["version"])
    overlay = json.loads((NATIVE / "tauri.bundle.json").read_text())
    overlay["bundle"]["createUpdaterArtifacts"] = False  # Sign only final OS-signed bytes.
    overlay["plugins"] = {"updater": {"pubkey": key, "requireSignedVersion": True}}
    # Sparkle in the retired Swift app compares CFBundleVersion numbers (it last shipped 26).
    major, minor, patch = (int(part) for part in value["version"].split("-")[0].split("."))
    overlay["bundle"]["macOS"] = {"bundleVersion": str(major * 10000 + minor * 100 + patch)}
    if platform.system() == "Windows" and not windows_unsigned():
        overlay["bundle"]["windows"] = {"bundleVCRuntime": True, "signCommand": {"cmd": "pwsh", "args": ["-NoProfile", "-File", str(ROOT / "packaging/desktop/sign-windows.ps1"), "%1"]}}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(overlay, indent=2) + "\n")
    print("Verified updater key pair and generated release configuration.")

def one(pattern: str):
    paths = list((ROOT / "target/release/bundle").glob(pattern))
    require(len(paths) == 1, f"Expected one built artifact matching {pattern}; found {len(paths)}")
    return paths[0]

def windows_catalog(output: Path):
    paths = [ROOT / "target/release/pressay-desktop.exe"]
    for directory in [NATIVE / "binaries", NATIVE / "runtime"]:
        paths.extend(p for p in directory.rglob("*") if p.is_file() and p.suffix.lower() in (".exe", ".dll"))
    require(all(p.is_file() for p in paths), "Build desktop executables before signing")
    require(any(p.name == "pressay-analysis-worker.exe" for p in paths), "Analysis worker is missing")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(os.path.relpath(p, output.parent) for p in sorted(set(paths))) + "\n")

def verify_windows(paths):
    # Windows checks chain trust and timestamps, independently of Tauri's update key.
    with tempfile.TemporaryDirectory(prefix="pressay-authenticode-") as directory:
        listing = Path(directory) / "files.json"
        listing.write_text(json.dumps([str(path.resolve()) for path in paths]))
        run("pwsh", "-NoProfile", "-File", ROOT / "packaging/desktop/verify-windows.ps1", "-FileList", listing)

def windows_unsigned():
    """Until Azure Artifact Signing is configured, Windows installers ship unsigned."""
    return os.environ.get("PRESSAY_WINDOWS_UNSIGNED") == "1"

def mac_package(output: Path, version: str):
    identity = os.environ.get("APPLE_SIGNING_IDENTITY", "")
    notarize = os.environ.get("PRESSAY_NOTARIZE", "1") == "1"
    if notarize:
        require(identity.startswith("Developer ID Application:"), "Notarized Mac artifacts require Developer ID Application signing")
        require(os.environ.get("PRESSAY_NOTARY_PROFILE"), "Notarized Mac artifacts require a notarytool keychain profile")
    else:
        # The stable self-signed release certificate keeps the Swift app's permissions and lets
        # its Sparkle updater install this app. Releases say they are not notarized.
        require(identity, "Set APPLE_SIGNING_IDENTITY to the release signing certificate")
    app = one("macos/*.app")
    # Installer tooling (pip, dmgbuild) has no need for the updater private key.
    base = {k: v for k, v in os.environ.items() if not k.startswith("TAURI_SIGNING_")}
    run(sys.executable, ROOT / "scripts/sign-desktop-macos.py", app, "--identity", identity, env=base)
    dmg = output / f"Pressay-{version}-macos-arm64.dmg"
    environment = base | {"PRESSAY_SKIP_BUILD": "1", "PRESSAY_NOTARIZE": "1" if notarize else "0", "PRESSAY_DMG_APP": str(app),
        "PRESSAY_DMG_VERSION": version, "PRESSAY_DMG_OUTPUT": str(dmg), "SIGNING_IDENTITY": identity}
    run(ROOT / "scripts/package-dmg.sh", env=environment)
    archive = output / f"Pressay-{version}-macos-arm64.app.tar.gz"
    # The app was stapled by package-dmg before this archive is created.
    run("tar", "-czf", archive, "-C", app.parent, app.name)
    # The same app, zipped for install.sh and the Swift app's Sparkle updater.
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, output / "Pressay-macos-arm64.zip")
    return [(archive, ["darwin-aarch64", "darwin-aarch64-app"])], [dmg]

def package(output: Path, tag: str):
    validate_tag(tag)
    version = config()["version"]
    public_key()
    output.mkdir(parents=True, exist_ok=True)
    require(not any(output.iterdir()), "Release output must be empty; stale artifacts must not enter the feed")
    system = platform.system()
    extras = []
    if system == "Darwin":
        require(platform.machine() == "arm64", "The current Mac runtime supports Apple Silicon")
        artifacts, extras = mac_package(output, version)
    elif system == "Windows":
        require(platform.machine().lower() in ("amd64", "x86_64"), "The release matrix targets Windows x64")
        original = one("nsis/*-setup.exe")
        windows_catalog(output.parent / "windows-verify-files.txt")
        paths = [ROOT / "target/release/pressay-desktop.exe", original]
        paths.extend(p for directory in [NATIVE / "runtime", NATIVE / "binaries"] for p in directory.rglob("*") if p.is_file() and p.suffix.lower() in (".exe", ".dll"))
        if not windows_unsigned():
            verify_windows(paths)
        artifact = output / f"Pressay-{version}-windows-x86_64-setup.exe"
        shutil.copy2(original, artifact)
        artifacts = [(artifact, ["windows-x86_64", "windows-x86_64-nsis"])]
    elif system == "Linux":
        require(platform.machine().lower() in ("x86_64", "amd64"), "The release matrix targets Linux x64")
        artifacts = []
        for pattern, extension, targets in [("appimage/*.AppImage", "AppImage", ["linux-x86_64", "linux-x86_64-appimage"]), ("deb/*.deb", "deb", ["linux-x86_64-deb"])]:
            artifact = output / f"Pressay-{version}-linux-x86_64.{extension}"
            shutil.copy2(one(pattern), artifact)
            artifacts.append((artifact, targets))
    else:
        raise ValueError("Unsupported release platform")
    platforms = {}
    for artifact, targets in artifacts:
        signature = sign(artifact, version)
        for target in targets:
            platforms[target] = {"file": artifact.name, "signature": signature}
    for extra in extras:
        sign(extra, version)
    fragment = {"version": version, "tag": tag, "platforms": platforms}
    (output / f"desktop-{system.lower()}.json").write_text(json.dumps(fragment, indent=2) + "\n")
    print(f"Verified signed desktop artifacts in {output}")

def validate_tag(tag: str):
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", tag), "Invalid release tag")

def manifest(directory: Path, tag: str):
    validate_tag(tag)
    version = config()["version"]
    platforms = {}
    fragments = sorted(directory.glob("desktop-*.json"))
    require(len(fragments) == 3, "Expected exactly three OS release fragments")
    for path in fragments:
        fragment = json.loads(path.read_text())
        require(fragment["version"] == version and fragment["tag"] == tag, "Release fragments disagree on version or destination")
        for target, entry in fragment["platforms"].items():
            require(target not in platforms, f"Duplicate updater target {target}")
            name = entry["file"]
            require(Path(name).name == name and not (directory / name).is_symlink(), "Invalid artifact filename")
            artifact = directory / name
            require(artifact.is_file(), f"Missing {name}")
            verify_signature(artifact, entry["signature"], version)
            require(Path(str(artifact) + ".sig").read_text().strip() == entry["signature"], "Detached signature differs from release fragment")
            platforms[target] = {"url": f"{REPOSITORY}/releases/download/{urllib.parse.quote(tag, safe='')}/{urllib.parse.quote(name, safe='')}", "signature": entry["signature"]}
    require(REQUIRED_TARGETS <= platforms.keys(), "The updater feed must include macOS, Windows, AppImage and Debian")
    value = {"version": version, "notes": "Pressay desktop update", "pub_date": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"), "platforms": platforms}
    # Verify every detached signature, including the manually installed Mac DMG.
    for signature in directory.glob("*.sig"):
        verify_signature(Path(str(signature)[:-4]), signature.read_text(), version)
    (directory / "desktop-latest.json").write_text(json.dumps(value, indent=2) + "\n")
    checksums = []
    for artifact in sorted(directory.iterdir()):
        if artifact.is_file() and artifact.name not in {p.name for p in fragments} | {"DESKTOP-SHA256SUMS"}:
            with artifact.open("rb") as handle:
                digest = hashlib.file_digest(handle, "sha256").hexdigest()
            checksums.append(f"{digest}  {artifact.name}")
    (directory / "DESKTOP-SHA256SUMS").write_text("\n".join(checksums) + "\n")
    print("Verified all release signatures and generated desktop-latest.json.")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["preflight", "windows-catalog", "package", "manifest"])
    parser.add_argument("--output", type=Path, required=True, help="Output config/catalog path or release artifact directory")
    parser.add_argument("--tag", help="Existing GitHub release tag; URLs are bound to this tag")
    args = parser.parse_args()
    output = args.output.resolve()
    if args.command == "preflight": preflight(output)
    elif args.command == "windows-catalog": windows_catalog(output)
    else:
        require(args.tag, "--tag is required")
        if args.command == "package": package(output, args.tag)
        else: manifest(output, args.tag)

if __name__ == "__main__":
    main()
