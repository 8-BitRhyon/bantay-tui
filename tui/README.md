# bantay-tui (Go TUI)

The standalone terminal companion for the Bantay control plane (plan 017 WI-7).
Runs in full-screen terminal or SSH sessions where the macOS notch overlay
isn't available.

Speaks the same NDJSON wire contract (plan 015 D2) as the macOS app's control
gateway: status list + approve/deny, gateway-first with retry/backoff.

## Build

```sh
cd tui
go build ./cmd/bantay-tui
```

## Run

```sh
BANTAY_CONTROL_SOCKET=/path/to/control.sock ./bantay-tui
```

Without the env var it defaults to
`~/Library/Application Support/Bantay-TUI/control.sock`.

## Keys

- `y` / `n` — approve / deny the top pending approval
- `q` / `Esc` / `Ctrl-C` — quit

## Layout

- `cmd/bantay-tui` — bubbletea entrypoint
- `internal/wire` — NDJSON framing (G1)
- `internal/taskspec` — shared task-spec JSON (G2)
- `internal/events` — event payload mirror + status mapping (G3)
- `internal/gateway` — UDS control-gateway client (G4)
- `internal/ui` — pure model state (G5)

Go 1.22+ required. Tests: `go test ./...`.
