#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="$HOME/Library/Application Support/Bantay-TUI"
EVENTS_FILE="$DATA_DIR/agent-events.jsonl"

mkdir -p "$DATA_DIR"
touch "$EVENTS_FILE"

echo "bantay-tui: data directory ready at $DATA_DIR"

AGENTS_PLIST="$HOME/Library/LaunchAgents/com.bantay-tui.agent.plist"

if [[ -f "$AGENTS_PLIST" ]]; then
  echo "bantay-tui: launch agent already installed"
  exit 0
fi

BINARY="$(cd "$(dirname "$0")/.." && pwd)/.build/debug/bantay"
if [[ ! -x "$BINARY" ]]; then
  echo "bantay-tui: binary not found at $BINARY -- build with 'swift build' first"
  echo "bantay-tui: skipping launch agent install"
  exit 0
fi

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
        <string>$BINARY</string>
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

launchctl load "$AGENTS_PLIST" 2>/dev/null || true

echo "bantay-tui: launch agent installed at $AGENTS_PLIST"
