#!/usr/bin/env bash
# ensure-dev-signing-identity.sh
#
# Prints the name of a stable local code-signing identity for development
# installs, creating and trusting one on first use.
#
# Why: ad-hoc signing (`codesign -s -`) gives every build a new designated
# requirement based on its cdhash. macOS TCC pins Accessibility to that
# requirement, so each rebuild looks like a new app and the user must grant
# Accessibility again. A self-signed certificate gives the app a stable
# requirement (`identifier "com.bantay-tui" and certificate root = H"..."`)
# that survives rebuilds.
#
# This identity is for this Mac only. It is not a replacement for Developer ID
# signing or notarization when distributing the app.
#
# Environment:
#   BANTAY_DEV_SIGNING_IDENTITY  identity name (default: Bantay Local Dev)
#   BANTAY_DEV_KEYCHAIN          keychain path (default: login keychain)
#   BANTAY_DISABLE_DEV_SIGNING   set to 1 to skip creation
set -euo pipefail

IDENTITY_NAME="${BANTAY_DEV_SIGNING_IDENTITY:-Bantay Local Dev}"
KEYCHAIN="${BANTAY_DEV_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY_NAME\""; then
  echo "$IDENTITY_NAME"
  exit 0
fi

if [[ "${BANTAY_DISABLE_DEV_SIGNING:-0}" == "1" ]]; then
  echo "bantay-tui: local signing disabled by BANTAY_DISABLE_DEV_SIGNING" >&2
  exit 1
fi

echo "bantay-tui: creating local code-signing identity \"$IDENTITY_NAME\"..." >&2
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bantay-signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY_NAME/O=Bantay/C=US" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

P12_PASS="$(openssl rand -hex 16)"
# Older macOS `security import` rejects modern PKCS#12 encryption defaults.
if ! openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -name "$IDENTITY_NAME" \
  -passout "pass:$P12_PASS" >/dev/null 2>&1; then
  openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -name "$IDENTITY_NAME" \
    -passout "pass:$P12_PASS" >/dev/null 2>&1
fi

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Trust the certificate for code signing in the user's trust domain. This is
# what makes `security find-identity -p codesigning` report a valid identity.
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem" \
  >/dev/null 2>&1 || true

# Keep the certificate (public only) so it can be re-trusted if needed.
mkdir -p "$HOME/.config/bantay"
cp "$WORK/cert.pem" "$HOME/.config/bantay/dev-signing.crt"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY_NAME\""; then
  echo "bantay-tui: identity created but not trusted yet." >&2
  echo "bantay-tui: open Keychain Access, select \"$IDENTITY_NAME\"," >&2
  echo "bantay-tui: then Trust > Code Signing > Always Trust." >&2
  exit 1
fi

echo "$IDENTITY_NAME"
