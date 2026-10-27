#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/.build/Pressay.app"
OUTPUT="$ROOT/.build/updates"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
TOOLS="${SPARKLE_TOOLS_DIR:?Set SPARKLE_TOOLS_DIR to Sparkle's bin directory}"
KEY="${SPARKLE_KEY_FILE:?Set SPARKLE_KEY_FILE to the private update key file}"

mkdir -p "$OUTPUT"
rm -f "$OUTPUT/Pressay-macos-arm64.zip" "$OUTPUT/appcast.xml"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/Pressay-macos-arm64.zip"
"$TOOLS/generate_appcast" --ed-key-file "$KEY" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/Zheruel/pressay-macos/releases/download/v$VERSION/" \
    --link 'https://github.com/Zheruel/pressay-macos' \
    --full-release-notes-url "https://github.com/Zheruel/pressay-macos/releases/tag/v$VERSION" \
    "$OUTPUT"
xcrun swift "$ROOT/scripts/verify-update.swift" "$APP/Contents/Info.plist" \
    "$OUTPUT/appcast.xml" "$OUTPUT/Pressay-macos-arm64.zip"
(cd "$OUTPUT" && shasum -a 256 Pressay-macos-arm64.zip > SHA256SUMS)
echo "$OUTPUT"
