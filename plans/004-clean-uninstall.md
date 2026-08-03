# Plan 004: Clean uninstall (`setup.sh --uninstall` + in-app path)

> **Executor instructions**: Follow plan step by step. Run every verification
> command and confirm its expected output. If a STOP condition appears, stop
> and report — do not improvise. Mark your row in `plans/README.md` done when
> finished unless told otherwise.
>
> **Drift check (run first)**: `git diff --stat b3a29ef..HEAD -- scripts`
> scripts/setup.sh is the only in-scope script; if it changed, compare excerpts.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `b3a29ef`, 2026-08-02

## Why this matters

The number-one complaint notch users have is "how do I remove it?" After
`setup.sh`, the app runs under a `RunAtLoad`+`KeepAlive` LaunchAgent; dragging
`bantay` to Trash does nothing because launchd relaunches it. Today there is
no uninstall and the README (which tells you how to *install*) doesn't tell
you how to remove. Competitors (NotchDrop, BoringNotch) are trivially removable
because they're standard apps; a launchd-agent install needs a first-class
removal path. This plan adds `setup.sh --uninstall` (reversible, safe,
idempotent) and a menu item + README section referencing it, so "removing it"
is one command and fully documented (000's bar #4).

## Current state

`scripts/setup.sh` (see b3a29af):

- data dir: `~/Library/Application Support/Bantay-TUI` (holds `bantay`, `agent-events.jsonl`, `bantay.log`, `bantay.err`)
- plist: `~/Library/LaunchAgents/com.bantay-tui.agent.plist` (`RunAtLoad`, `KeepAlive`)
- install: `cp` binary → bootout → bootstrap; nothing that removes.

No uninstall today: manual sequence is `launchctl bootout gui/$(id -u)/com.bantay-tui.agent && rm -f "$HOME/Library/LaunchAgents/com.bantay-tui.agent.plist" && rm -rf "$HOME/Library/Application Support/Bantay-TUI"` — but launching bootout is risky for the installed agent binary its own (the process is running; `bootout` then `unloads` after a grace period kills it).

## 1. Commands

| Purpose | Command | Expected on success |
|---|---|---|
| Script syntax | `bash -n scripts/setup.sh` | exit 0 |
| Shell rack | `sh -c 'bash scripts/setup.sh --uninstall'` | exit 0 |
| Format lint (no swift changes) | `swift format lint --recursive --strict Sources Tests` | exit 0, no file change |
| Build | `swift build` | exit 0 |
| Release | `swift build -c release` | exit 0 |

## 2. Scope

**In scope**:
- `scripts/setup.sh` — add `--uninstall`.
- `README.md` — "Uninstalling" section.
- `Sources/BantayTUI/DynamicIslandApp.swift` — a menu "Remove Bantay-TUI…"
  item that launches the uninstall script and quits (see Step 4, optional but
  recommended — make it dead simple).
- `.gitignore`? None needed.

**Out of scope**:
- 002's LaunchAgent toggle (already planned; it only toggles `RunAtLoad`; it does
  not remove data).
- Homebrew cask removal.

## 3. Repo conventions

- `setup.sh` is idempotent bash with `set -euo pipefail`, echo-prefixed messages
  (`bantay-tui: ...`). Match it.
- Menu items match the `menuNeedsUpdate` pattern (DynamicIslandApp).

## 4. Steps

### Step 1: Add `--uninstall` to `setup.sh`

Keep install behavior unchanged. Add:

```bash
UNINSTALL="no"
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL="yes" ;;
  esac
done

if [[ "$UNINSTALL" == "yes" ]]; then
  echo "bantay-tui: uninstalling..."
  launchctl bootout gui/$(id -u)/com.bantay-tui.agent 2>/dev/null || \
    launchctl unload "$AGENTS_PLIST" 2>/dev/null || true
  # give launchd a beat to release the binary
  sleep 1
  rm -f "$AGENTS_PLIST"
  rm -f "$INSTALLED_BIN"
  rm -f "$EVENTS_FILE"
  rm -f "$DATA_DIR/bantay.log" "$DATA_DIR/bantay.err"
  rmdir "$DATA_DIR" 2>/dev/null || true
  echo "bantay-tui: removed; app files deleted, “Run in terminal” profiles untouched."
  exit 0
fi
```

Guard: refuse if neither the plist nor the data dir exist:

```bash
if [[ ! -e "$AGENTS_PLIST" && ! -d "$DATA_DIR" ]]; then
  echo "bantay-tui: nothing installed; nothing to do."; exit 0
fi
```

### Step 2: README "Uninstalling" section

Under a new `## Uninstalling` heading (before `## Configuration` if desired —
match position after `### Verify the integration`):

```markdown
## Uninstalling

To fully remove Bantay-TUI (launch agent, app binary, event history, data):

    bash scripts/setup.sh --uninstall
```

Note: the app itself can be removed from the Trash afterward; the agent will
not relaunch it. Removing Bantai resets its `UserDefaults` domain — document
that Settings do not survive uninstall.

### Step 3: In-app menu path (recommended)

In `menuNeedsUpdate`, before "Quit Bantay-TUI" add:

```swift
let uninstallItem = NSMenuItem(title: "Remove Bantay-TUI…",
                               action: #selector(uninstallPrompt), keyEquivalent: "")
uninstallItem.target = self
```

Emitter (on `AppDelegate`):

```swift
@objc private func uninstallPrompt() {
    let a = NSAlert()
    a.messageText = "Uninstall Bantay-TUI?"
    a.informativeText = "This removes the launch agent, app binary, and event history. Your herdr sessions are untouched."
    a.addButton(withTitle: "Uninstall")
    a.addButton(withTitle: "Cancel")
    if a.runModal() == .alertFirstButtonReturn {
        let script = Bundle.main.resourceURL ...
            // run: `bash <appDir>/setup.sh --uninstall` via Process()
        // after successful exit: NSApp.terminate(nil)
    }
}
```

The `setup.sh --uninstall` runs against the default user dirs (the binary copied
location), so no path plumbing to source.

### Step 4: Verify

- `bash -n scripts/setup.sh` → exit 0
- Run `bash scripts/setup.sh --uninstall` on a box with the agent installed:
  `launchctl print gui/$(id -u)/com.bantay-tui.agent` → error (not found); plist gone; data dir gone.
- `swift build` → 0; `swift format lint` → 0 (if you touched Swift).

## 4. Test plan

Shell is not covered by the Swift XCSuite. Add `grep -n "--uninstall" scripts/setup.sh` check to Done, plus manual sequence above. Document that `--uninstall` is idempotent (run twice, second run exits 0 "nothing to uninstall").

## 5. Done criteria

- [ ] `bash scripts/setup.sh --uninstall` bootout + removes plist/bin/events/logs
- [ ] Running it again is a no-op exit 0
- [ ] README has "Uninstalling" section
- [ ] `bash -n` passes, install path unchanged (`setup.sh` with no args still installs)
- [ ] `swift build` and `swift format lint` green (only if Swift/App side touched)
- [ ] `plans/README.md` row updated

## 6. STOP conditions

- If uninstalling under a running app/gui session appears to leave the app running (KeepAlive race), STOP: the sleep-before-rm must be raised, or use `launchctl kill SIGTERM gui/$uid/...` then rm, then bootout; do not improvise a different teardown order.
- Do NOT delete `~/Library/Preferences`; the uninstall removes the launch agent, app binary, and data dir, but does not wipe the `BantayTUI` UserDefaults domain. Document that Settings survive an uninstall-driven removal only if the plist/data dir come back; keep the README honest about what "remove" means.

## 7. Maintenance notes

- After the future DMG/Sparkle installs land, tab-tck though a moving dir will change (app bundle vs copied binary); an `.app` variant should uninstall differently. Flag for future plans.
- Keep the script in sync with `setup.sh`'s vars (would prefer single source).