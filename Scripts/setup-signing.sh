#!/bin/bash
# One-time setup: create and trust a local code-signing certificate
# ("LocalFlow Dev Signing") so LocalFlow keeps its macOS permission grants
# (Accessibility / Input Monitoring) across rebuilds. Ad-hoc signatures
# change on every build, which makes macOS treat each build as a new app.
set -euo pipefail

if security find-identity -v -p codesigning | grep -q "LocalFlow Dev Signing"; then
  echo "✓ 'LocalFlow Dev Signing' already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# Use the system LibreSSL: Homebrew's OpenSSL 3.x writes PKCS#12 in a modern
# format that macOS `security import` cannot read (MAC verification failed).
OPENSSL="/usr/bin/openssl"

cat > ext.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_code
prompt = no
[dn]
CN = LocalFlow Dev Signing
[v3_code]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:FALSE
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 3650 -nodes -config ext.cnf
"$OPENSSL" pkcs12 -export -out lf.p12 -inkey key.pem -in cert.pem \
  -passout pass:localflow -name "LocalFlow Dev Signing"

echo "Importing into your login keychain…"
security import lf.p12 -P localflow -T /usr/bin/codesign

echo "Trusting it for code signing — enter your Mac login password in the dialog that appears…"
security add-trusted-cert -p codeSign cert.pem

echo
security find-identity -v -p codesigning
echo "✓ Done. LocalFlow builds will now keep a stable signature."
