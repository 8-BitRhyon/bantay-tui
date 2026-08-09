#!/bin/bash
# build-logic-harness.sh — compile + run the pure-logic harness (Layer 3.5).
#
# Self-maintaining: globs every source file in Sources/BantayTUI, excludes the
# SwiftUI/AppKit UI files that can't compile in a headless swiftc invocation,
# and compiles them with .kilo/LogicCheck.swift. New pure-logic source files
# are picked up automatically — CI can never go red from a forgotten entry in
# a hand-maintained list (the failure mode that bit the push-stream branch).
#
# Exclusions must stay in sync with what genuinely imports SwiftUI/AppKit:
# add a file here ONLY when it cannot compile without the UI frameworks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

UI_ONLY=(
  DynamicIslandApp.swift
  NotchStatusView.swift
  PeekPanel.swift
  SettingsView.swift
)

SRC=()
for f in "$ROOT"/Sources/BantayTUI/*.swift; do
  base="$(basename "$f")"
  skip=0
  for ui in "${UI_ONLY[@]}"; do
    if [[ "$base" == "$ui" ]]; then skip=1; break; fi
  done
  if [[ $skip -eq 0 ]]; then SRC+=("$f"); fi
done

OUT="${LOGIC_CHECK_BIN:-/tmp/logic-check}"
swiftc -o "$OUT" "${SRC[@]}" "$ROOT/.kilo/LogicCheck.swift"
"$OUT"
