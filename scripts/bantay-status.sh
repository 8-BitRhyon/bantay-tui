#!/bin/bash
# bantay-status — one-line agent status for the tmux status bar.
#
# Emits e.g.:  ◐ 2 working · ⚠ 1 blocked · ✓ 1 done
# Source is herdr's own socket/CLI so it works even when the Bantay app is
# not running. Wire it up with:
#
#   tmux set-option -g status-right '#(bantay-status)'
#
# or install it automatically from Bantay Settings. Re-runs periodically
# because tmux re-executes `#(...)` status interpolation.

# Only proceed inside a herdr-capable environment; fail silently otherwise.
command -v herdr >/dev/null 2>&1 || exit 0

JSON="$("${HERDR_BIN_PATH:-herdr}" agent list 2>/dev/null)" || exit 0

working=$(printf '%s' "$JSON" | grep -o '"agent_status":"working"' | wc -l | tr -d ' ')
blocked=$(printf '%s' "$JSON" | grep -o '"agent_status":"blocked"' | wc -l | tr -d ' ')
done_count=$(printf '%s' "$JSON" | grep -o '"agent_status":"done"' | wc -l | tr -d ' ')

out=""
[ "$working" != "0" ] && out="${out} ◐ ${working} working"
[ "$blocked" != "0" ] && out="${out} ⚠ ${blocked} blocked"
[ "$done_count" != "0" ] && out="${out} ✓ ${done_count} done"
[ -z "$out" ] && out=" · 0 agents"
printf '%s' "${out# }"
