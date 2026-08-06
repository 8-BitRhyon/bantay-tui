// Package taskspec defines the shared task-spec JSON (Goal/Files/Constraints,
// D2 in plan 015) that both the Swift app and Go TUI emit and consume.
package taskspec

import "encoding/json"

// TaskSpec is the versioned task specification shared across runtimes.
type TaskSpec struct {
	Version     int      `json:"v"`
	Goal        string   `json:"goal"`
	Files       []string `json:"files"`
	Constraints []string `json:"constraints"`
	Source      string   `json:"source"`
}

// Marshal encodes the spec as JSON.
func (t TaskSpec) Marshal() ([]byte, error) {
	return json.Marshal(t)
}

// Unmarshal decodes JSON into the spec. Unknown fields are ignored.
func (t *TaskSpec) Unmarshal(data []byte) error {
	return json.Unmarshal(data, t)
}
