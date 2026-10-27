#!/bin/bash
# Download a prebuilt release. Later updates run inside Pressay through Sparkle.
set -euo pipefail

fail() { printf 'Pressay: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'Requires an Apple Silicon Mac.'
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]] || fail 'Requires macOS 26 or newer.'
if pgrep -x Pressay >/dev/null; then
    fail 'Quit Pressay before installing. Finish any dictation or meeting first.'
fi

INSTALL_DIR="${PRESSAY_INSTALL_DIR:-$HOME/Applications}"
if [[ -z "${PRESSAY_INSTALL_DIR:-}" && -d /Applications/Pressay.app ]]; then
    INSTALL_DIR=/Applications
fi
DESTINATION="$INSTALL_DIR/Pressay.app"
DOWNLOAD="$(mktemp -d "${TMPDIR:-/tmp}/pressay-download.XXXXXX")"
STAGING=''
cleanup() {
    if [[ -n "$STAGING" && -d "$STAGING/Previous.app" && ! -e "$DESTINATION" ]]; then
        mv "$STAGING/Previous.app" "$DESTINATION"
    fi
    rm -rf "$DOWNLOAD"
    [[ -z "$STAGING" ]] || rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BASE_URL='https://github.com/Zheruel/pressay-macos/releases/latest/download'
ARCHIVE='Pressay-macos-arm64.zip'
printf 'Downloading Pressay…\n'
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$BASE_URL/$ARCHIVE" --output "$DOWNLOAD/$ARCHIVE"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$BASE_URL/SHA256SUMS" --output "$DOWNLOAD/SHA256SUMS"
EXPECTED="$(awk -v name="$ARCHIVE" '$2 == name { print $1 }' "$DOWNLOAD/SHA256SUMS")"
[[ ${#EXPECTED} == 64 && "$EXPECTED" != *[!0-9a-fA-F]* ]] || fail 'Missing or invalid release checksum.'
printf '%s  %s\n' "$EXPECTED" "$DOWNLOAD/$ARCHIVE" | shasum -a 256 --check --status - \
    || fail 'Download verification failed. Your installed app was not changed. Try again.'

mkdir -p "$INSTALL_DIR"
[[ -w "$INSTALL_DIR" ]] || fail 'Install folder is not writable. Set PRESSAY_INSTALL_DIR to a folder you own.'
STAGING="$(mktemp -d "$INSTALL_DIR/.pressay-install.XXXXXX")"
ditto -x -k "$DOWNLOAD/$ARCHIVE" "$STAGING"
APP="$STAGING/Pressay.app"
[[ -d "$APP" && ! -L "$APP" ]] || fail 'The release does not contain Pressay.app.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == dev.localflow.app ]] \
    || fail 'Unexpected app identifier.'
codesign --verify --deep --strict "$APP" || fail 'App signature verification failed.'
if pgrep -x Pressay >/dev/null; then
    fail 'Pressay started during the download. Quit it before installing.'
fi

# Stage on the destination volume. Keep the previous app until replacement succeeds.
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$STAGING/Previous.app"; fi
mv "$APP" "$DESTINATION"
printf 'Installed %s\n' "$DESTINATION"
open "$DESTINATION"
