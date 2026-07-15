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
xcrun swift build --disable-sandbox -c "$CONFIGURATION" --product LocalFlow

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/$CONFIGURATION/LocalFlow" "$CONTENTS/MacOS/Pressay"
cp "$ROOT/Config/Info.plist" "$CONTENTS/Info.plist"
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
        --options runtime \
        "$TIMESTAMP_ARGUMENT" \
        --entitlements "$ROOT/Config/LocalFlow.entitlements" \
        "$APP"
    echo "Signed with $SIGNING_IDENTITY"
else
    codesign --force \
        --sign - \
        --entitlements "$ROOT/Config/LocalFlow.entitlements" \
        "$APP"
    echo "Warning: ad-hoc signed build; macOS permissions may reset after updates." >&2
fi

codesign --verify --deep --strict "$APP"
echo "$APP"
