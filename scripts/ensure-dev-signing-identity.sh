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
# The identity lives in a dedicated keychain
# (~/.config/bantay/signing.keychain-db) whose password is stored in a
# user-private file (mode 600) next to it. The login keychain is never
# touched: unlocking it or using its keys can pop a GUI password prompt and
# hang headless `codesign` runs. The dedicated keychain unlocks
# non-interactively from the stored password, so `setup.sh` signs without
# ever blocking on authorization dialogs.
#
# This identity is for this Mac only. It is not a replacement for Developer ID
# signing or notarization when distributing the app.
#
# Environment:
#   BANTAY_DEV_SIGNING_IDENTITY  identity name (default: Bantay Local Dev)
#   BANTAY_DEV_KEYCHAIN          keychain path (default: ~/.config/bantay/signing.keychain-db)
#   BANTAY_DISABLE_DEV_SIGNING   set to 1 to skip creation
set -euo pipefail

IDENTITY_NAME="${BANTAY_DEV_SIGNING_IDENTITY:-Bantay Local Dev}"
CONFIG_DIR="$HOME/.config/bantay"
KEYCHAIN="${BANTAY_DEV_KEYCHAIN:-$CONFIG_DIR/signing.keychain-db}"
PW_FILE="$CONFIG_DIR/.signing-keychain-pass"

if [[ "${BANTAY_DISABLE_DEV_SIGNING:-0}" == "1" ]]; then
    echo "bantay: local signing disabled by BANTAY_DISABLE_DEV_SIGNING" >&2
    exit 1
fi

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [[ ! -f "$PW_FILE" ]]; then
    openssl rand -hex 32 > "$PW_FILE"
    chmod 600 "$PW_FILE"
fi
PW="$(cat "$PW_FILE")"

# Validate the keychain BEFORE trusting the identity listing. `find-identity`
# lists certificates without unlocking the keychain, so a stale password file
# looks healthy until codesign runs and fails — and a failed sign falls back
# to ad-hoc, which changes the TCC requirement and re-prompts.
if [[ -f "$KEYCHAIN" ]] && ! security unlock-keychain -p "$PW" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "bantay: signing keychain password is stale; recreating it." >&2
    rm -f "$KEYCHAIN" "$KEYCHAIN"-db "$KEYCHAIN"-shm "$CONFIG_DIR/dev-signing.crt"
    openssl rand -hex 32 > "$PW_FILE"
    chmod 600 "$PW_FILE"
    PW="$(cat "$PW_FILE")"
fi

if IDENTITY_HASH="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v name="$IDENTITY_NAME" 'index($0, "\"" name "\"") && $1 ~ /^[0-9]+\)$/ {print $2; exit}')" \
    && [[ -n "$IDENTITY_HASH" ]]; then
    echo "$IDENTITY_HASH"
    exit 0
fi

if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$PW" "$KEYCHAIN" >/dev/null
fi
security unlock-keychain -p "$PW" "$KEYCHAIN" >/dev/null

if ! IDENTITY_HASH="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v name="$IDENTITY_NAME" 'index($0, "\"" name "\"") && $1 ~ /^[0-9]+\)$/ {print $2; exit}')" \
    || [[ -z "$IDENTITY_HASH" ]]; then
    echo "bantay: creating local code-signing identity \"$IDENTITY_NAME\"..." >&2
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
    # Allow codesign to use the key without a GUI approval dialog.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" \
        "$KEYCHAIN" >/dev/null

    # Trust the certificate for code signing in the user's trust domain. This is
    # what makes `security find-identity -p codesigning` report a valid identity.
    security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem" \
        >/dev/null 2>&1 || true

    # Keep the certificate (public only) so it can be re-trusted if needed.
    cp "$WORK/cert.pem" "$HOME/.config/bantay/dev-signing.crt"
fi

if ! IDENTITY_HASH="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v name="$IDENTITY_NAME" 'index($0, "\"" name "\"") && $1 ~ /^[0-9]+\)$/ {print $2; exit}')" \
    || [[ -z "$IDENTITY_HASH" ]]; then
    echo "bantay: identity created but not trusted yet." >&2
    echo "bantay: open Keychain Access, select \"$IDENTITY_NAME\"," >&2
    echo "bantay: then Trust > Code Signing > Always Trust." >&2
    exit 1
fi

IDENTITY_HASH="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | awk -v name="$IDENTITY_NAME" 'index($0, "\"" name "\"") && $1 ~ /^[0-9]+\)$/ {print $2; exit}')"
echo "$IDENTITY_HASH"
