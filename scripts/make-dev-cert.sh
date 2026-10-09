#!/bin/bash
# Creates a local self-signed code-signing identity "CineNotch Dev" in the login keychain.
# Why: ad-hoc signed builds get a new identity on every rebuild, so macOS drops
# Accessibility / Screen Recording permissions each time. A stable certificate keeps them.
# Nothing is uploaded anywhere and no trust settings are changed.
set -euo pipefail
NAME="CineNotch Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:cinenotch -out "$TMP/id.p12"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P cinenotch -T /usr/bin/codesign >/dev/null

# Smoke test: sign a throwaway binary with the new identity.
cp /usr/bin/true "$TMP/t"
codesign -s "$NAME" -f "$TMP/t"
echo "OK: \"$NAME\" created and usable by codesign."
