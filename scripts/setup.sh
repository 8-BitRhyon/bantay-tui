#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="$HOME/Library/Application Support/Bantay-TUI"
EVENTS_FILE="$DATA_DIR/agent-events.jsonl"
AGENTS_PLIST="$HOME/Library/LaunchAgents/com.bantay-tui.agent.plist"
INSTALLED_BIN="$DATA_DIR/bantay"

UNINSTALL="no"
PACKAGE="no"
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL="yes" ;;
    --package) PACKAGE="yes" ;;
  esac
done

if [[ "$PACKAGE" == "yes" ]]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$ROOT"
  echo "bantay-tui: building universal release (arm64 + x86_64)..."
  ARCHES=(--arch arm64 --arch x86_64)
  if ! swift build -c release "${ARCHES[@]}" 2>/dev/null; then
    echo "bantay-tui: universal build unavailable (needs full Xcode; falling back to host arch)"
    ARCHES=()
    swift build -c release || exit 1
  fi
  RELEASE_BIN="$ROOT/.build/apple/Products/Release/bantay"
  if [[ ! -x "$RELEASE_BIN" ]]; then
    RELEASE_BIN="$ROOT/.build/release/bantay"
  fi
  if [[ ! -x "$RELEASE_BIN" ]]; then
    echo "bantay-tui: release binary not found after build" >&2
    exit 1
  fi
  DIST="$ROOT/dist"
  STAGE="$DIST/Bantay-TUI.app/Contents"
  rm -rf "$DIST/Bantay-TUI.app"
  mkdir -p "$STAGE/MacOS"
  cp "$RELEASE_BIN" "$STAGE/MacOS/bantay"
  cat > "$STAGE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Bantay-TUI</string>
    <key>CFBundleDisplayName</key>
    <string>Bantay-TUI</string>
    <key>CFBundleIdentifier</key>
    <string>com.bantay-tui</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>bantay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSRemindersUsageDescription</key>
    <string>Bantay-TUI syncs your task widget with Apple Reminders.</string>
</dict>
</plist>
PLIST
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    KEYCHAIN=""
    if [[ -n "${P12_BASE64:-}" && -n "${P12_PASSWORD:-}" ]]; then
      # CI: import the Developer ID cert into a throwaway keychain.
      KEYCHAIN="$(mktemp -d)/bantay.keychain-db"
      security create-keychain -p bantay "$KEYCHAIN" >/dev/null
      security default-keychain -s "$KEYCHAIN" >/dev/null
      security unlock-keychain -p bantay "$KEYCHAIN" >/dev/null
      echo "$P12_BASE64" | base64 --decode > /tmp/bantay-cert.p12
      security import /tmp/bantay-cert.p12 -P "$P12_PASSWORD" -A -k "$KEYCHAIN" >/dev/null
      rm -f /tmp/bantay-cert.p12
    fi
    echo "bantay-tui: signing with $CODESIGN_IDENTITY"
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$DIST/Bantay-TUI.app" || exit 1
    cd "$DIST" && rm -f bantay-tui.zip && zip -qry bantay-tui.zip Bantay-TUI.app
    if [[ -n "${NOTARY_PROFILE:-}" || -n "${APPLE_ID:-}" ]]; then
      echo "bantay-tui: submitting to Apple notary..."
      NOTARY_ARGS=()
      if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        NOTARY_ARGS+=(--keychain-profile "$NOTARY_PROFILE")
      else
        NOTARY_ARGS+=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
      fi
      xcrun notarytool submit bantay-tui.zip "${NOTARY_ARGS[@]}" --wait || exit 1
      xcrun stapler staple "$DIST/Bantay-TUI.app" || exit 1
      rm -f bantay-tui.zip && zip -qry bantay-tui.zip Bantay-TUI.app
    fi
    if [[ -n "$KEYCHAIN" ]]; then
      security default-keychain -s "$HOME/Library/Keychains/login.keychain-db" >/dev/null
    fi
  else
    # Ad-hoc bundle sign so the seal matches the binary. This is NOT
    # notarized: Gatekeeper will still block it on other Macs. For public
    # distribution set CODESIGN_IDENTITY (Developer ID) and notarize:
    #   xcrun notarytool submit bantay-tui.zip --keychain-profile bantay --wait
    codesign --force --deep --sign - -r='designated => identifier "com.bantay-tui"' "$DIST/Bantay-TUI.app"
    echo "bantay-tui: WARNING ad-hoc signed only (not notarized)."
    echo "bantay-tui:   set CODESIGN_IDENTITY + notarize for Gatekeeper-clean distribution."
    cd "$DIST" && rm -f bantay-tui.zip && zip -qry bantay-tui.zip Bantay-TUI.app
  fi
  SHA="$(shasum -a 256 "$DIST/bantay-tui.zip" | awk '{print $1}')"
  echo "bantay-tui: packaged $DIST/bantay-tui.zip"
  echo "bantay-tui: sha256 $SHA (update Cask/bantay-tui.rb)"
  if ! lipo -archs "$STAGE/MacOS/bantay" | grep -q "x86_64"; then
    echo "bantay-tui: WARNING binary is $(lipo -archs "$STAGE/MacOS/bantay" | tr '\n' ' ')-only --"
    echo "bantay-tui:   universal2 requires full Xcode. Intel Macs need the CI release build."
  fi
  exit 0
fi

if [[ "$UNINSTALL" == "yes" ]]; then
  if [[ ! -e "$AGENTS_PLIST" && ! -d "$DATA_DIR" ]]; then
    echo "bantay-tui: nothing installed; nothing to do."
    exit 0
  fi
  echo "bantay-tui: uninstalling..."
  launchctl bootout gui/$(id -u)/com.bantay-tui.agent 2>/dev/null || \
    launchctl unload "$AGENTS_PLIST" 2>/dev/null || true
  # give launchd a beat to release the running binary
  sleep 1
  rm -f "$AGENTS_PLIST"
  rm -f "$INSTALLED_BIN"
  rm -f "$DATA_DIR/setup.sh"
  rm -f "$EVENTS_FILE"
  rm -f "$DATA_DIR/bantay.log" "$DATA_DIR/bantay.err"
  rmdir "$DATA_DIR" 2>/dev/null || true
  echo "bantay-tui: removed; launch agent, app binary, and event history deleted."
  exit 0
fi

mkdir -p "$DATA_DIR"
touch "$EVENTS_FILE"
# Events carry agent shell commands — keep them user-private.
chmod 600 "$EVENTS_FILE"

echo "bantay-tui: data directory ready at $DATA_DIR"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT/.build/release/bantay"
if [[ -f "$ROOT/.build/debug/bantay" && (! -f "$BINARY" || "$ROOT/.build/debug/bantay" -nt "$BINARY") ]]; then
  BINARY="$ROOT/.build/debug/bantay"
elif [[ ! -x "$BINARY" ]]; then
  BINARY="$ROOT/.build/debug/bantay"
fi
if [[ ! -x "$BINARY" ]]; then
  echo "bantay-tui: binary not found at $BINARY -- build with 'swift build' first"
  echo "bantay-tui: skipping launch agent install"
  exit 0
fi

# Kill running instance before replacing the binary — launchd will restart it,
# or we trigger kickstart at the bottom of the script.
pkill -x bantay 2>/dev/null || true
sleep 0.3

cp "$(cd "$(dirname "$0")" && pwd)/setup.sh" "$DATA_DIR/setup.sh"
# Ship the tmux status-bar helper alongside the app.
cp "$(cd "$(dirname "$0")" && pwd)/bantay-status.sh" "$DATA_DIR/bantay-status.sh"
chmod +x "$DATA_DIR/bantay-status.sh"
# Ship the openCode plugin so Settings can install it into openCode.
cp "$(cd "$(dirname "$0")" && pwd)/bantay-opencode.js" "$DATA_DIR/bantay-opencode.js"

# Run from a minimal .app bundle so the process has a bundle identifier —
# UNUserNotificationCenter (approval notification actions) requires one and
# crashes with `bundleProxyForCurrentProcess is nil` for a bare binary.
APP_BUNDLE="$DATA_DIR/Bantay-TUI.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/bantay"
LAUNCH_BIN="$APP_BIN"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BINARY" "$APP_BIN"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Bantay-TUI</string>
    <key>CFBundleDisplayName</key>
    <string>Bantay-TUI</string>
    <key>CFBundleIdentifier</key>
    <string>com.bantay-tui</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>bantay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSRemindersUsageDescription</key>
    <string>Bantay-TUI syncs your task widget with Apple Reminders.</string>
</dict>
</plist>
PLIST

# Sign the bundle with a stable identity so macOS TCC grants survive rebuilds.
# Ad-hoc signatures pin the designated requirement to a per-build cdhash, so
# every rebuild looks like a new app and prompts again. The local self-signed
# identity anchors the requirement to the certificate instead.
#
# Ad-hoc is opt-in: silently falling back to it is what makes grants flap, so
# this script refuses unless BANTAY_ALLOW_ADHOC=1 is set.
SIGN_IDENTITY=""
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$CODESIGN_IDENTITY"
elif DEV_IDENTITY="$(bash "$ROOT/scripts/ensure-dev-signing-identity.sh")"; then
  SIGN_IDENTITY="$DEV_IDENTITY"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  if [[ "${BANTAY_ALLOW_ADHOC:-0}" == "1" ]]; then
    SIGN_IDENTITY="-"
    echo "bantay-tui: no signing identity; using ad-hoc (BANTAY_ALLOW_ADHOC=1)." >&2
    echo "bantay-tui: permissions will reset on every rebuild." >&2
  else
    echo "bantay-tui: no stable signing identity available." >&2
    echo "bantay-tui: run scripts/ensure-dev-signing-identity.sh, then retry." >&2
    echo "bantay-tui: set BANTAY_ALLOW_ADHOC=1 to accept ad-hoc signing." >&2
    exit 1
  fi
fi
echo "bantay-tui: codesigning $APP_BUNDLE with identifier com.bantay-tui"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "bantay-tui: signed-with: ad-hoc (permissions reset on rebuild)"
  codesign --force --deep --sign - -r='designated => identifier "com.bantay-tui"' "$APP_BUNDLE"
else
  # Unlock the dedicated dev-signing keychain non-interactively so codesign
  # never blocks on a GUI authorization dialog, and add it to the search list
  # only for this call: codesign does not reliably resolve --keychain for
  # identity lookup, and a same-named certificate elsewhere wins silently.
  DEV_KEYCHAIN="${BANTAY_DEV_KEYCHAIN:-$HOME/.config/bantay/signing.keychain-db}"
  DEV_PW_FILE="$HOME/.config/bantay/.signing-keychain-pass"
  if [[ -f "$DEV_KEYCHAIN" && -f "$DEV_PW_FILE" ]]; then
    security unlock-keychain -p "$(cat "$DEV_PW_FILE")" "$DEV_KEYCHAIN" >/dev/null 2>&1 || true
    ORIGINAL_KEYCHAINS="$(security list-keychains -d user | sed 's/^ *//; s/"//g')"
    # shellcheck disable=SC2086
    restore_keychains() { security list-keychains -d user -s $ORIGINAL_KEYCHAINS; }
    trap restore_keychains EXIT
    security list-keychains -d user -s "$DEV_KEYCHAIN" $ORIGINAL_KEYCHAINS
    codesign --force --sign "$SIGN_IDENTITY" --identifier "com.bantay-tui" "$APP_BUNDLE"
    restore_keychains
    trap - EXIT
  else
    codesign --force --sign "$SIGN_IDENTITY" --identifier "com.bantay-tui" "$APP_BUNDLE"
  fi
  echo "bantay-tui: signed-with: $SIGN_IDENTITY (permissions survive rebuilds)"
fi

# TCC grants are keyed to the signed requirement, not the bundle ID. Writing
# TCC.db directly is blocked by SIP, so this script never attempts it. If a
# grant looks stale after switching signing identities, reset it once:
#   tccutil reset Accessibility com.bantay-tui
#   tccutil reset Reminders com.bantay-tui

cat > "$AGENTS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.bantay-tui.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>$LAUNCH_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BANTAY_DEBUG</key>
        <string>1</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$DATA_DIR/bantay.log</string>
    <key>StandardErrorPath</key>
    <string>$DATA_DIR/bantay.err</string>
</dict>
</plist>
PLIST

launchctl bootout gui/$(id -u)/com.bantay-tui.agent 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$AGENTS_PLIST" 2>/dev/null || \
  launchctl load "$AGENTS_PLIST" 2>/dev/null || true

if [[ -d "$HOME/.local/bin" ]]; then
  ln -sf "$LAUNCH_BIN" "$HOME/.local/bin/bantay"
fi

echo "bantay-tui: launch agent installed at $AGENTS_PLIST (binary: $INSTALLED_BIN)"
