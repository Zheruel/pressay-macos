#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Config/Info.plist")"
STAGING="$ROOT/.build/dmg-root"
OUTPUT="$ROOT/.build/Pressay-$VERSION.dmg"

"$ROOT/scripts/build-app.sh"
rm -rf "$STAGING" "$OUTPUT"
mkdir -p "$STAGING"
ditto "$ROOT/.build/Pressay.app" "$STAGING/Pressay.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
    -volname "Pressay" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$OUTPUT" \
    >/dev/null

# Only a Developer ID signature helps Gatekeeper; a self-signed one on the DMG
# adds nothing, since permissions follow the app inside it.
if [[ "${SIGNING_IDENTITY:-}" == Developer\ ID\ Application:* ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$OUTPUT"
fi

echo "$OUTPUT"
