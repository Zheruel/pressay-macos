#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${PRESSAY_DMG_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Config/Info.plist")}"
APP="${PRESSAY_DMG_APP:-$ROOT/.build/Pressay.app}"
OUTPUT="${PRESSAY_DMG_OUTPUT:-$ROOT/.build/Pressay-$VERSION.dmg}"
ARTWORK="$ROOT/.build/dmg-artwork"
TOOLS="$ROOT/.build/dmg-tools"
NOTARIZE="${PRESSAY_NOTARIZE:-0}"

if [[ "$NOTARIZE" != 0 && "$NOTARIZE" != 1 ]]; then
    echo 'PRESSAY_NOTARIZE must be 0 or 1.' >&2
    exit 1
fi
if [[ "$NOTARIZE" == 1 && -z "${PRESSAY_NOTARY_PROFILE:-}" ]]; then
    echo 'Notarized packaging requires PRESSAY_NOTARY_PROFILE (notarytool keychain credentials).' >&2
    exit 1
fi

# Explicitly opt out only when repackaging an already built app, such as layout QA.
if [[ -n "${PRESSAY_DMG_APP:-}" && "${PRESSAY_SKIP_BUILD:-0}" != 1 ]]; then
    echo "A custom app requires PRESSAY_SKIP_BUILD=1." >&2
    exit 1
fi
if [[ "${PRESSAY_SKIP_BUILD:-0}" != 1 ]]; then
    "$ROOT/scripts/build-app.sh"
fi
[[ -d "$APP" ]] || { echo "Missing app: $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || { echo 'Built app version does not match the requested installer version.' >&2; exit 1; }

# Inspect the actual signature, including when build-app selected its own identity.
AUTHORITY="$(codesign --display --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -n 1)"
if [[ "$NOTARIZE" == 1 ]]; then
    [[ -n "$AUTHORITY" ]] || { echo 'Notarized releases require Developer ID Application signing.' >&2; exit 1; }
    # Staple the app before either the disk image or Sparkle ZIP copies it.
    "$ROOT/scripts/notarize-macos.sh" "$APP"
fi

mkdir -p "$ARTWORK" "${OUTPUT:h}"
xcrun clang -fobjc-arc -framework AppKit \
    "$ROOT/packaging/macos/dmg/render-background.m" -o "$ARTWORK/render-background"
"$ARTWORK/render-background" "$ARTWORK"
if [[ ! -x "$TOOLS/bin/python3" ]]; then
    python3 -m venv "$TOOLS"
fi
"$TOOLS/bin/python3" -m pip install --disable-pip-version-check --quiet \
    -r "$ROOT/packaging/macos/dmg/requirements.txt"
rm -f "$OUTPUT"
"$TOOLS/bin/dmgbuild" -s "$ROOT/packaging/macos/dmg/layout.py" \
    -D "app=$APP" -D "background=$ARTWORK/background.tiff" "Pressay" "$OUTPUT"

# A self-signed DMG does not help Gatekeeper. Developer ID does.
if [[ -n "$AUTHORITY" ]]; then
    codesign --force --sign "${SIGNING_IDENTITY:-$AUTHORITY}" --timestamp "$OUTPUT"
fi
if [[ "$NOTARIZE" == 1 ]]; then
    "$ROOT/scripts/notarize-macos.sh" "$OUTPUT"
fi
hdiutil verify "$OUTPUT" >/dev/null
"$TOOLS/bin/python3" "$ROOT/packaging/macos/dmg/verify.py" "$OUTPUT" "${APP:t}"
echo "$OUTPUT"
