#!/usr/bin/env bash
# doctor.sh — explain why macOS permissions keep resetting.
#
# TCC stores a code requirement (csreq) when a grant is given, not a bundle
# ID. The requirement matches the current signature. An ad-hoc signature pins
# it to a per-build cdhash, so every rebuild looks like a new app. A stable
# certificate makes it survive rebuilds. Two same-named certificates make the
# signer unpredictable, which is just as bad.
#
# Read-only: this script changes nothing.
set -uo pipefail

APP="${BANTAY_APP:-$HOME/Library/Application Support/Bantay-TUI/Bantay-TUI.app}"
DEV_KEYCHAIN="${BANTAY_DEV_KEYCHAIN:-$HOME/.config/bantay/signing.keychain-db}"
PW_FILE="$HOME/.config/bantay/.signing-keychain-pass"
IDENTITY_NAME="${BANTAY_DEV_SIGNING_IDENTITY:-Bantay Local Dev}"

echo "bantay doctor"
echo

echo "app: $APP"
if [[ -d "$APP" ]]; then
    DR="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
    echo "  requirement: ${DR:-<none>}"
    case "$DR" in
        *cdhash*) echo "  verdict: AD-HOC CDHASH (grants reset on every rebuild)" ;;
        *certificate*) echo "  verdict: certificate-anchored (grants can survive rebuilds)" ;;
        *identifier*) echo "  verdict: identifier-only (stable, but any code with this ID matches)" ;;
        *) echo "  verdict: unknown" ;;
    esac
    codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)=" | sed 's/^/  /'
else
    echo "  missing (not installed)"
fi
echo

echo "signing identities"
for KC in "$DEV_KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"; do
    [[ -f "$KC" ]] || continue
    COUNT=0
    LAST_HASH=""
    while IFS= read -r LINE; do
        [[ "$LINE" == *"$IDENTITY_NAME"* ]] || continue
        [[ "$LINE" =~ ^[[:space:]]*[0-9]+\) ]] || continue
        HASH="$(printf '%s' "$LINE" | awk '{print $2}')"
        [[ "$HASH" == "$LAST_HASH" ]] && continue
        LAST_HASH="$HASH"
        COUNT=$((COUNT + 1))
        echo "  $(basename "$KC"): $LINE"
    done < <(security find-identity -p codesigning "$KC" 2>/dev/null)
    [[ $COUNT -eq 0 ]] && echo "  $(basename "$KC"): no \"$IDENTITY_NAME\""
done
echo "  note: more than one matching identity makes the signer unpredictable."
echo "  note: probes must not use -v; it hides untrusted self-signed roots."
echo

echo "dedicated keychain"
if [[ -f "$DEV_KEYCHAIN" && -f "$PW_FILE" ]]; then
    if security unlock-keychain -p "$(cat "$PW_FILE")" "$DEV_KEYCHAIN" >/dev/null 2>&1; then
        echo "  password: matches the stored keychain password"
    else
        echo "  password: STALE (signing will fail; rerun ensure-dev-signing-identity.sh)"
    fi
else
    echo "  missing keychain or password file"
fi
echo

echo "if grants look stale after switching identities, reset them once"
echo "  tccutil reset Accessibility com.bantay-tui"
echo "  tccutil reset Reminders com.bantay-tui"
echo "then relaunch and grant again. With a stable signature, that is the last time."
