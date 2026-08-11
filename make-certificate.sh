#!/bin/bash
# Creates a local, self-signed code signing certificate in the login keychain,
# named "ZenRayDictate Local". Run once: ./make-certificate.sh
#
# Why this exists: an ad-hoc signature (codesign --sign -) is derived from the
# binary's own hash, so it changes at every build. macOS grants Accessibility
# and other TCC permissions against that signature, which means the grant is
# silently revoked on every rebuild even though the tick in System Settings
# never changes. A stable identity fixes that: same certificate every build,
# same signature, permissions survive.
set -euo pipefail

NAME="ZenRayDictate Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
    echo "Certificate '$NAME' already exists, nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.conf" -sha256 >/dev/null 2>&1

openssl pkcs12 -export -out "$TMP/cert.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:zenray

echo "==> Importing into the login keychain"
echo "    macOS will ask once whether codesign may use this key. Allow it."
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P zenray -T /usr/bin/codesign -A

security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "Done. Rebuild the app to sign with '$NAME':"
echo "  ./build.sh"
