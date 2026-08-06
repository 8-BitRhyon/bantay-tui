#!/usr/bin/env bash
# hook-emit.sh — Bantay universal agent event emitter (plan 017 W4 / WI-6).
#
# Emits one canonical NDJSON event line for an agent into Bantay's UDS
# ingest socket using the W2 bare-line form: a `token <secret>` line, then
# ONE event JSON line, then close (see EventIngestServer.bareLineEvent).
# When the socket — or a token to authenticate with it — is unavailable,
# falls back to appending the events file directly so a hook never silently
# drops an event.
#
# Socket + token resolution (matches EventIngestServer.swift / WI-5):
#   socket: BANTAY_INGEST_SOCKET env wins, else
#           ~/Library/Application Support/Bantay-TUI/ingest.sock
#   token:  BANTAY_INGEST_TOKEN env wins, else
#           ~/Library/Application Support/Bantay-TUI/ingest.token
#           (written by the app so hook scripts can authenticate)
#
# Usage:
#   hook-emit --source <tool> --type <type> --title "..." [options]
#
# Required:
#   --source <tool>      agent family (aider, codex, windsurf, cursor, ...)
#   --type <type>        access_request | progress | completed | failed |
#                        started | waiting | idle | cancelled | clear
#   --title "..."        event title
#
# Options:
#   --pane-id <id>       pane identifier
#   --workspace-id <id>  workspace identifier
#   --variance <v>       yes-no | choices | multi
#   --choices a,b        comma-separated choices (use with --variance)
#   --message "..."      optional message
#   --help               show this help
set -euo pipefail

readonly EVENTS_FILE="${HOME}/Library/Application Support/Bantay-TUI/agent-events.jsonl"
readonly KNOWN_TYPES="access_request progress completed failed started waiting idle cancelled clear"

usage() {
    cat <<'EOF'
hook-emit — Bantay universal agent event emitter (plan 017 W4 / WI-6)

Usage:
  hook-emit --source <tool> --type <type> --title "..." [options]

Required:
  --source <tool>      agent family (aider, codex, windsurf, cursor, ...)
  --type <type>        access_request | progress | completed | failed |
                       started | waiting | idle | cancelled | clear
  --title "..."        event title

Options:
  --pane-id <id>       pane identifier
  --workspace-id <id>  workspace identifier
  --variance <v>       yes-no | choices | multi
  --choices a,b        comma-separated choices (use with --variance)
  --message "..."      optional message
  --help               show this help

Emits one canonical NDJSON line to Bantay's UDS ingest socket
(BANTAY_INGEST_SOCKET, else ~/Library/Application Support/Bantay-TUI/ingest.sock)
as the bare `token <secret>` + event-line form; the token comes from
BANTAY_INGEST_TOKEN or ~/Library/Application Support/Bantay-TUI/ingest.token.
Falls back to appending the events file when the socket or token is absent.
EOF
    exit "${1:-0}"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

SOURCE=""
TYPE=""
TITLE=""
PANE_ID=""
WORKSPACE_ID=""
VARIANCE=""
CHOICES=""
MESSAGE=""

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source)
                [ "$#" -ge 2 ] || { echo "hook-emit: --source requires a value" >&2; usage 2; }
                SOURCE="$2"
                shift 2
                ;;
            --type)
                [ "$#" -ge 2 ] || { echo "hook-emit: --type requires a value" >&2; usage 2; }
                TYPE="$2"
                shift 2
                ;;
            --title)
                [ "$#" -ge 2 ] || { echo "hook-emit: --title requires a value" >&2; usage 2; }
                TITLE="$2"
                shift 2
                ;;
            --pane-id)
                [ "$#" -ge 2 ] || { echo "hook-emit: --pane-id requires a value" >&2; usage 2; }
                PANE_ID="$2"
                shift 2
                ;;
            --workspace-id)
                [ "$#" -ge 2 ] || { echo "hook-emit: --workspace-id requires a value" >&2; usage 2; }
                WORKSPACE_ID="$2"
                shift 2
                ;;
            --variance)
                [ "$#" -ge 2 ] || { echo "hook-emit: --variance requires a value" >&2; usage 2; }
                VARIANCE="$2"
                shift 2
                ;;
            --choices)
                [ "$#" -ge 2 ] || { echo "hook-emit: --choices requires a value" >&2; usage 2; }
                CHOICES="$2"
                shift 2
                ;;
            --message)
                [ "$#" -ge 2 ] || { echo "hook-emit: --message requires a value" >&2; usage 2; }
                MESSAGE="$2"
                shift 2
                ;;
            --help)
                usage 0
                ;;
            *)
                echo "hook-emit: unknown option: $1" >&2
                usage 2
                ;;
        esac
    done

    [ -n "$SOURCE" ] || { echo "hook-emit: --source is required" >&2; usage 2; }
    [ -n "$TYPE" ] || { echo "hook-emit: --type is required" >&2; usage 2; }
    [ -n "$TITLE" ] || { echo "hook-emit: --title is required" >&2; usage 2; }
    case " $KNOWN_TYPES " in
        *" $TYPE "*) ;;
        *) echo "hook-emit: invalid --type: $TYPE" >&2; usage 2 ;;
    esac
    if [ -n "$VARIANCE" ]; then
        case "$VARIANCE" in
            yes-no | choices | multi) ;;
            *)
                echo "hook-emit: invalid --variance: $VARIANCE" >&2
                usage 2
                ;;
        esac
    fi
}

resolve_socket() {
    if [ -n "${BANTAY_INGEST_SOCKET:-}" ]; then
        printf '%s' "$BANTAY_INGEST_SOCKET"
        return 0
    fi
    printf '%s' "${HOME}/Library/Application Support/Bantay-TUI/ingest.sock"
}

resolve_token() {
    if [ -n "${BANTAY_INGEST_TOKEN:-}" ]; then
        printf '%s' "$BANTAY_INGEST_TOKEN"
        return 0
    fi
    local tokfile="${HOME}/Library/Application Support/Bantay-TUI/ingest.token"
    if [ -s "$tokfile" ]; then
        cat "$tokfile"
        return 0
    fi
    return 1
}

build_payload() {
    local choices_json="null"
    if [ -n "$CHOICES" ]; then
        local -a parts=()
        IFS=',' read -ra parts <<< "$CHOICES"
        choices_json="["
        local part
        for part in "${parts[@]}"; do
            choices_json="${choices_json}\"$(json_escape "$part")\","
        done
        choices_json="${choices_json%,}]"
    fi

    local pane_json="null"
    [ -n "$PANE_ID" ] && pane_json="\"$(json_escape "$PANE_ID")\""
    local ws_json="null"
    [ -n "$WORKSPACE_ID" ] && ws_json="\"$(json_escape "$WORKSPACE_ID")\""
    local variance_json="null"
    [ -n "$VARIANCE" ] && variance_json="\"$(json_escape "$VARIANCE")\""
    local msg_json="null"
    [ -n "$MESSAGE" ] && msg_json="\"$(json_escape "$MESSAGE")\""

    printf '{"v":1,"source":"%s","type":"%s","title":"%s","message":%s,"paneId":%s,"workspaceId":%s,"variance":%s,"choices":%s}' \
        "$(json_escape "$SOURCE")" "$(json_escape "$TYPE")" "$(json_escape "$TITLE")" \
        "$msg_json" "$pane_json" "$ws_json" "$variance_json" "$choices_json"
}

emit_via_socket() {
    local sock token payload resp
    sock="$(resolve_socket)" || return 1
    token="$(resolve_token)" || return 1
    [ -S "$sock" ] || return 1
    payload="$(build_payload)" || return 1
    # Write the bare form (`token <secret>` + one event line, then close)
    # over a UNIX-domain socket. bash cannot open AF_UNIX sockets via
    # redirection on macOS, so pipe through `nc -U` (ships with macOS). The
    # ingest server settles on EOF, replies `200 OK` when the payload was
    # accepted (403 on a token mismatch), and closes — `-w 2` bounds the
    # pathological case where the peer never closes. Any failure — including
    # a 403 — falls back to the events file so the event is never lost.
    if resp=$(printf 'token %s\n%s\n' "$token" "$payload" | nc -U -w 2 "$sock" 2>/dev/null); then
        case "$resp" in
            *200*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

append_to_events_file() {
    local payload events_dir
    payload="$(build_payload)" || return 1
    events_dir="$(dirname "$EVENTS_FILE")"
    mkdir -p "$events_dir" 2>/dev/null || true
    printf '%s\n' "$payload" >> "$EVENTS_FILE"
}

main() {
    parse_args "$@"
    if emit_via_socket; then
        exit 0
    fi
    append_to_events_file
}

main "$@"
