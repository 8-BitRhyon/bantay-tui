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
    codesign --force --sign - "$DIST/Bantay-TUI.app"
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

BINARY="$(cd "$(dirname "$0")/.." && pwd)/.build/debug/bantay"
if [[ ! -x "$BINARY" ]]; then
  echo "bantay-tui: binary not found at $BINARY -- build with 'swift build' first"
  echo "bantay-tui: skipping launch agent install"
  exit 0
fi

cp "$BINARY" "$INSTALLED_BIN"
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
</dict>
</plist>
PLIST

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

echo "bantay-tui: launch agent installed at $AGENTS_PLIST (binary: $INSTALLED_BIN)"
