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
# SwiftPM's artifact extraction mangles the framework differently depending
# on version: canonical symlinks intact, symlinks resolved into a real
# Versions/A tree, or fully flattened with the payload at the framework root.
# codesign rejects everything but the canonical layout — rebuild it from
# whichever payload location exists.
# SwiftPM copies the framework into the products directory on every build —
# the one location that is stable across SwiftPM artifact-extraction layouts.
# The raw artifacts path is only a fallback.
FRAMEWORK_SOURCE="$ROOT/.build/$CONFIGURATION/CTranscribe.framework"
if [[ ! -d "$FRAMEWORK_SOURCE" ]]; then
    FRAMEWORK_SOURCE="$ROOT/.build/artifacts/whisper/CTranscribe/TranscribeCpp.xcframework/macos-arm64_x86_64/CTranscribe.framework"
fi
FRAMEWORK="$CONTENTS/Frameworks/CTranscribe.framework"
if [[ -L "$FRAMEWORK_SOURCE/Versions/Current" ]]; then
    ditto "$FRAMEWORK_SOURCE" "$FRAMEWORK"
else
    PAYLOAD="$FRAMEWORK_SOURCE"
    [[ -d "$FRAMEWORK_SOURCE/Versions/A" ]] && PAYLOAD="$FRAMEWORK_SOURCE/Versions/A"
    mkdir -p "$FRAMEWORK/Versions/A"
    for item in CTranscribe Headers Modules Resources; do
        [[ -e "$PAYLOAD/$item" ]] && ditto "$PAYLOAD/$item" "$FRAMEWORK/Versions/A/$item"
    done
    if [[ ! -f "$FRAMEWORK/Versions/A/CTranscribe" ]]; then
        echo "error: no framework binary under $FRAMEWORK_SOURCE — layout:" >&2
        find "$FRAMEWORK_SOURCE" -maxdepth 2 >&2
        exit 1
    fi
    # A flat extraction can leave Info.plist at the root; codesign needs it
    # in Versions/A/Resources.
    if [[ ! -f "$FRAMEWORK/Versions/A/Resources/Info.plist" && -f "$PAYLOAD/Info.plist" ]]; then
        mkdir -p "$FRAMEWORK/Versions/A/Resources"
        cp "$PAYLOAD/Info.plist" "$FRAMEWORK/Versions/A/Resources/Info.plist"
    fi
    ln -sfn A "$FRAMEWORK/Versions/Current"
    ln -sfn Versions/Current/CTranscribe "$FRAMEWORK/CTranscribe"
    ln -sfn Versions/Current/Headers "$FRAMEWORK/Headers"
    ln -sfn Versions/Current/Modules "$FRAMEWORK/Modules"
    ln -sfn Versions/Current/Resources "$FRAMEWORK/Resources"
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
