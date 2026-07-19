#!/bin/zsh
set -euo pipefail

# Replaces /Applications/Pressay.app with the freshly built bundle. TCC grants
# survive only with a stable signing identity ("Pressay Local Signing"); after
# an ad-hoc build, expect macOS to ask for the permissions again.

ROOT="${0:A:h:h}"
APP="$ROOT/.build/Pressay.app"
DEST="/Applications/Pressay.app"

[[ -d "$APP" ]] || { echo "error: $APP missing — run make app first" >&2; exit 1; }

if pgrep -xq Pressay; then
    pkill -x Pressay || true
    for _ in {1..25}; do
        pgrep -xq Pressay || break
        sleep 0.2
    done
    pgrep -xq Pressay && { echo "error: Pressay did not exit" >&2; exit 1; }
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "Installed and relaunched $DEST"
