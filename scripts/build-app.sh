#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/.build/Pressay.app"
CONTENTS="$APP/Contents"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

cd "$ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/ModuleCache}"
xcrun swift build --disable-sandbox -c "$CONFIGURATION" --product Pressay

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$ROOT/.build/$CONFIGURATION/Pressay" "$CONTENTS/MacOS/Pressay"
cp "$ROOT/Config/Info.plist" "$CONTENTS/Info.plist"

# transcribe.cpp ships as a dynamic framework; the binary references it via
# @rpath, so it must be embedded and reachable from Contents/Frameworks.
# Depending on the SwiftPM version that extracted the artifact, the framework
# arrives either with its canonical Versions/Current symlink layout intact
# (fresh CI checkouts) or with symlinks resolved into real directories, which
# codesign rejects as ambiguous — rebuild the canonical layout in that case.
FRAMEWORK_SOURCE="$ROOT/.build/artifacts/whisper/CTranscribe/TranscribeCpp.xcframework/macos-arm64_x86_64/CTranscribe.framework"
FRAMEWORK="$CONTENTS/Frameworks/CTranscribe.framework"
if [[ -L "$FRAMEWORK_SOURCE/Versions/Current" ]]; then
    ditto "$FRAMEWORK_SOURCE" "$FRAMEWORK"
elif [[ -d "$FRAMEWORK_SOURCE/Versions/A" ]]; then
    mkdir -p "$FRAMEWORK/Versions"
    ditto "$FRAMEWORK_SOURCE/Versions/A" "$FRAMEWORK/Versions/A"
    ln -sfn A "$FRAMEWORK/Versions/Current"
    ln -sfn Versions/Current/CTranscribe "$FRAMEWORK/CTranscribe"
    ln -sfn Versions/Current/Headers "$FRAMEWORK/Headers"
    ln -sfn Versions/Current/Modules "$FRAMEWORK/Modules"
    ln -sfn Versions/Current/Resources "$FRAMEWORK/Resources"
else
    echo "error: $FRAMEWORK_SOURCE has no Versions payload — was the artifact extracted?" >&2
    exit 1
fi
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/Pressay" 2>/dev/null || true
if [[ -d "$ROOT/Config/Sounds" ]]; then
    mkdir -p "$CONTENTS/Resources/Sounds"
    cp "$ROOT"/Config/Sounds/*.wav "$CONTENTS/Resources/Sounds/"
fi
xcrun actool "$ROOT/Config/Assets.xcassets" \
    --compile "$CONTENTS/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ROOT/.build/asset-info.plist" \
    >/dev/null
plutil -lint "$CONTENTS/Info.plist" >/dev/null

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Pressay Local Signing\)"/\1/p' | head -n 1)"
    fi
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
    fi
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    TIMESTAMP_ARGUMENT="--timestamp=none"
    if [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]]; then
        TIMESTAMP_ARGUMENT="--timestamp"
    fi
    codesign --force \
        --sign "$SIGNING_IDENTITY" \
        "$TIMESTAMP_ARGUMENT" \
        "$CONTENTS/Frameworks/CTranscribe.framework"
    codesign --force \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        "$TIMESTAMP_ARGUMENT" \
        --entitlements "$ROOT/Config/Pressay.entitlements" \
        "$APP"
    echo "Signed with $SIGNING_IDENTITY"
else
    codesign --force --sign - "$CONTENTS/Frameworks/CTranscribe.framework"
    codesign --force \
        --sign - \
        --entitlements "$ROOT/Config/Pressay.entitlements" \
        "$APP"
    echo "Warning: ad-hoc signed build; macOS permissions may reset after updates." >&2
fi

codesign --verify --deep --strict "$APP"
echo "$APP"
