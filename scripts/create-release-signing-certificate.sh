#!/bin/zsh
set -euo pipefail

# One-time setup for the release signing identity. macOS ties permission
# approvals to it, so every release must keep using the same one.

IDENTITY="Pressay Release Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
REPOSITORY="${REPOSITORY:-Zheruel/pressay-macos}"

command -v gh >/dev/null || { echo 'Install the GitHub CLI (gh) first.' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Run gh auth login first.' >&2; exit 1; }

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "$IDENTITY already exists in the login keychain." >&2
    echo 'Replacing it makes every user approve permissions again; remove it in Keychain Access first if that is intended.' >&2
    exit 2
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pressay-release-signing.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
umask 077

cat > "$TEMP_DIR/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[ subject ]
CN = Pressay Release Signing
O = Pressay

[ extensions ]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

# Replacing an expired certificate would mean new permission prompts.
openssl req \
    -new \
    -newkey rsa:3072 \
    -nodes \
    -x509 \
    -days 36500 \
    -config "$TEMP_DIR/openssl.cnf" \
    -keyout "$TEMP_DIR/private-key.pem" \
    -out "$TEMP_DIR/certificate.pem" \
    >/dev/null 2>&1

PASSWORD="$(openssl rand -hex 32)"
openssl pkcs12 \
    -export \
    -legacy \
    -inkey "$TEMP_DIR/private-key.pem" \
    -in "$TEMP_DIR/certificate.pem" \
    -name "$IDENTITY" \
    -passout "pass:$PASSWORD" \
    -out "$TEMP_DIR/identity.p12"

base64 -i "$TEMP_DIR/identity.p12" | gh secret set RELEASE_SIGNING_CERTIFICATE --repo "$REPOSITORY"
printf '%s' "$PASSWORD" | gh secret set RELEASE_SIGNING_PASSWORD --repo "$REPOSITORY"
# Import last: a failed upload above leaves nothing behind, so a rerun works.
security import "$TEMP_DIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$PASSWORD" \
    -T /usr/bin/codesign \
    >/dev/null
unset PASSWORD

openssl x509 -in "$TEMP_DIR/certificate.pem" -noout -fingerprint -sha1
echo "Stored $IDENTITY in the login keychain and as $REPOSITORY secrets."
