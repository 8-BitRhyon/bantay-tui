// Package events mirrors the AgentEventPayload shape from the Swift app and
// maps herdr/agent statuses to display kinds.
package events

import "encoding/json"

// AgentEventPayload mirrors AgentEventPayload in the Swift app.
type AgentEventPayload struct {
	Version     int      `json:"v"`
	Source      string   `json:"source"`
	Type        string   `json:"type"`
	Title       string   `json:"title"`
	Message     string   `json:"message"`
	PaneID      string   `json:"paneId"`
	WorkspaceID string   `json:"workspaceId"`
	Variance    string   `json:"variance"`
	Choices     []string `json:"choices"`
}

// Marshal encodes the payload as JSON.
func (p AgentEventPayload) Marshal() ([]byte, error) {
	return json.Marshal(p)
}

// Unmarshal decodes JSON into the payload. Unknown fields are ignored.
func (p *AgentEventPayload) Unmarshal(data []byte) error {
	return json.Unmarshal(data, p)
}

// StatusKind maps a raw status string to a display kind. Unknown statuses
// default to idle so the TUI never crashes on a new agent state.
func StatusKind(raw string) string {
	switch raw {
	case "access_request", "blocked":
		return "needs_input"
	case "completed", "done":
		return "completed"
	case "failed":
		return "failed"
	case "working", "running", "started":
		return "working"
	case "waiting":
		return "waiting"
	case "idle", "cancelled", "clear":
		return "idle"
	default:
		return "idle"
	}
}
