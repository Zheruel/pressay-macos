#!/bin/zsh
# Credentials are provided through notarytool's keychain profile, never arguments
# containing secret values. Public packaging fails closed on every validation.
set -euo pipefail

[[ $# == 1 ]] || { echo 'Usage: notarize-macos.sh <app-or-dmg>' >&2; exit 2; }
ARTIFACT="${1:A}"
PROFILE="${PRESSAY_NOTARY_PROFILE:?Set PRESSAY_NOTARY_PROFILE to a notarytool keychain profile}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KEYCHAIN_ARGS=()
if [[ -n "${PRESSAY_NOTARY_KEYCHAIN:-}" ]]; then
    KEYCHAIN_ARGS=(--keychain "$PRESSAY_NOTARY_KEYCHAIN")
fi

codesign --verify --deep --strict "$ARTIFACT"
if ! codesign --display --verbose=2 "$ARTIFACT" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
    echo 'Notarization requires a Developer ID Application signature.' >&2
    exit 1
fi
SUBMISSION="$ARTIFACT"
if [[ "$ARTIFACT" == *.app && -d "$ARTIFACT" ]]; then
    SUBMISSION="$WORK/Pressay.zip"
    ditto -c -k --sequesterRsrc --keepParent "$ARTIFACT" "$SUBMISSION"
elif [[ "$ARTIFACT" != *.dmg || ! -f "$ARTIFACT" ]]; then
    echo 'Expected an app bundle or disk image.' >&2
    exit 1
fi

xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" \
    "${KEYCHAIN_ARGS[@]}" --wait --timeout 30m --output-format json > "$WORK/result.json"
python3 - "$WORK/result.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    result = json.load(handle)
if result.get("status") != "Accepted":
    raise SystemExit(f"Notarization was not accepted: {result.get('status', 'unknown')}; submission {result.get('id', 'unknown')}")
print(f"Notarization accepted: {result['id']}")
PY
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
if [[ "$ARTIFACT" == *.app ]]; then
    spctl --assess --type execute --verbose=2 "$ARTIFACT"
else
    spctl --assess --type open --context context:primary-signature --verbose=2 "$ARTIFACT"
fi
