package events

import "testing"

func TestStatusMapping(t *testing.T) {
	cases := map[string]string{
		"access_request": "needs_input",
		"blocked":        "needs_input",
		"completed":      "completed",
		"done":           "completed",
		"failed":         "failed",
		"working":        "working",
		"running":        "working",
		"waiting":        "waiting",
		"idle":           "idle",
		"started":        "working",
		"cancelled":      "idle",
		"clear":          "idle",
	}
	for in, want := range cases {
		if got := StatusKind(in); got != want {
			t.Errorf("StatusKind(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStatusUnknownDefaultsIdle(t *testing.T) {
	if got := StatusKind("totally_unknown"); got != "idle" {
		t.Fatalf("StatusKind(unknown) = %q, want idle", got)
	}
}

func TestPayloadRoundTrip(t *testing.T) {
	in := AgentEventPayload{
		Version:     1,
		Source:      "kilo",
		Type:        "access_request",
		Title:       "Approve?",
		PaneID:      "w3:p3",
		WorkspaceID: "w3",
		Variance:    "yes-no",
	}
	data, err := in.Marshal()
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var out AgentEventPayload
	if err := out.Unmarshal(data); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if out.Title != in.Title || out.PaneID != in.PaneID {
		t.Fatalf("round-trip mismatch: %+v", out)
	}
}

func TestPayloadUnknownFieldsTolerated(t *testing.T) {
	data := []byte(`{"v":1,"type":"idle","future":true}`)
	var out AgentEventPayload
	if err := out.Unmarshal(data); err != nil {
		t.Fatalf("Unmarshal with unknown field: %v", err)
	}
	if out.Type != "idle" {
		t.Fatalf("Type = %q, want idle", out.Type)
	}
}
