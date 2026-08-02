#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="$HOME/Library/Application Support/Bantay-TUI"
EVENTS_FILE="$DATA_DIR/agent-events.jsonl"
AGENTS_PLIST="$HOME/Library/LaunchAgents/com.bantay-tui.agent.plist"
INSTALLED_BIN="$DATA_DIR/bantay"

UNINSTALL="no"
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL="yes" ;;
  esac
done

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

echo "bantay-tui: data directory ready at $DATA_DIR"

BINARY="$(cd "$(dirname "$0")/.." && pwd)/.build/debug/bantay"
if [[ ! -x "$BINARY" ]]; then
  echo "bantay-tui: binary not found at $BINARY -- build with 'swift build' first"
  echo "bantay-tui: skipping launch agent install"
  exit 0
fi

cp "$BINARY" "$INSTALLED_BIN"
cp "$(cd "$(dirname "$0")" && pwd)/setup.sh" "$DATA_DIR/setup.sh"

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
        <string>$INSTALLED_BIN</string>
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
