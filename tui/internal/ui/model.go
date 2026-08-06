// Package ui holds the TUI model state. The state transitions are pure so
// they are testable without a terminal (G5).
package ui

// State is the connection lifecycle state.
type State string

const (
	StateConnecting State = "connecting"
	StateConnected  State = "connected"
	StateError      State = "error"
)

// AgentRow is a single agent in the status list.
type AgentRow struct {
	PaneID string
	Source string
	Status string // needs_input / working / completed / failed / waiting / idle
	Title  string
}

// Model is the pure TUI state.
type Model struct {
	state      State
	err        string
	socketPath string
	agents     map[string]AgentRow
	resolving  map[string]bool
}

// NewModel creates a model in the connecting state.
func NewModel(socketPath string) *Model {
	return &Model{
		state:      StateConnecting,
		socketPath: socketPath,
		agents:     map[string]AgentRow{},
		resolving:  map[string]bool{},
	}
}

// State returns the current lifecycle state.
func (m *Model) State() State { return m.state }

// SocketPath returns the configured socket path.
func (m *Model) SocketPath() string { return m.socketPath }

// MarkError transitions to the error state.
func (m *Model) MarkError(msg string) {
	m.state = StateError
	m.err = msg
}

// Retry returns to connecting (backoff is handled by the caller).
func (m *Model) Retry() {
	m.state = StateConnecting
	m.err = ""
}

// SetConnected marks the connection established.
func (m *Model) SetConnected() {
	m.state = StateConnected
	m.err = ""
}

// Error returns the last error message.
func (m *Model) Error() string { return m.err }

// UpsertAgent adds or replaces an agent row.
func (m *Model) UpsertAgent(paneID, source, status, title string) {
	m.agents[paneID] = AgentRow{
		PaneID: paneID, Source: source, Status: status, Title: title,
	}
}

// AgentStatus returns the status of a pane, or "" when absent.
func (m *Model) AgentStatus(paneID string) string {
	if row, ok := m.agents[paneID]; ok {
		return row.Status
	}
	return ""
}

// Agents returns the current agent rows.
func (m *Model) Agents() []AgentRow {
	out := make([]AgentRow, 0, len(m.agents))
	for _, row := range m.agents {
		out = append(out, row)
	}
	return out
}

// HasBlocked reports whether any agent needs input and is not resolving.
func (m *Model) HasBlocked() bool {
	for _, row := range m.agents {
		if row.Status == "needs_input" && !m.resolving[row.PaneID] {
			return true
		}
	}
	return false
}

// Approve marks a pane resolving after an approve command.
func (m *Model) Approve(paneID string) { m.resolving[paneID] = true }

// Deny marks a pane resolving after a deny command.
func (m *Model) Deny(paneID string) { m.resolving[paneID] = true }

// IsResolving reports whether the pane is awaiting resolution.
func (m *Model) IsResolving(paneID string) bool { return m.resolving[paneID] }

// ClearResolving un-marks a pane once the next poll shows a new status.
func (m *Model) ClearResolving(paneID string) { delete(m.resolving, paneID) }
