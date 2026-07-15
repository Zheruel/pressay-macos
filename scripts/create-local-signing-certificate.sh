#!/bin/zsh
set -euo pipefail

IDENTITY="Pressay Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
    echo "$IDENTITY already exists."
    exit 0
fi

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "A certificate named $IDENTITY exists without a usable private key." >&2
    echo "Remove that incomplete certificate in Keychain Access before retrying." >&2
    exit 2
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pressay-signing.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[ subject ]
CN = Pressay Local Signing
O = Pressay
OU = Local Development

[ extensions ]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

openssl req \
    -new \
    -newkey rsa:3072 \
    -nodes \
    -x509 \
    -days 3650 \
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

security import "$TEMP_DIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$PASSWORD" \
    -T /usr/bin/codesign \
    >/dev/null
unset PASSWORD

# Trust only this self-signed root for the code-signing policy. It is not a
# distribution identity and is never exported from the login keychain.
security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$TEMP_DIR/certificate.pem"

security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$IDENTITY"
