package ui

import "testing"

func TestModelConnectErrorRetry(t *testing.T) {
	m := NewModel("/nonexistent.sock")
	if got := m.State(); got != StateConnecting {
		t.Fatalf("initial state = %q, want connecting", got)
	}
	m.MarkError("dial failed")
	if got := m.State(); got != StateError {
		t.Fatalf("after error state = %q, want error", got)
	}
	m.Retry()
	if got := m.State(); got != StateConnecting {
		t.Fatalf("after retry state = %q, want connecting", got)
	}
}

func TestApproveMarksResolving(t *testing.T) {
	m := NewModel("/tmp/x.sock")
	m.SetConnected()
	m.UpsertAgent("w3:p3", "kilo", "needs_input", "Approve terraform apply?")
	if !m.HasBlocked() {
		t.Fatal("expected a blocked agent")
	}
	m.Approve("w3:p3")
	if !m.IsResolving("w3:p3") {
		t.Fatal("approve should mark pane resolving")
	}
	if m.HasBlocked() {
		t.Fatal("resolving pane should not count as blocked")
	}
}

func TestDenyMarksResolving(t *testing.T) {
	m := NewModel("/tmp/x.sock")
	m.SetConnected()
	m.UpsertAgent("w3:p3", "kilo", "needs_input", "Run tests?")
	m.Deny("w3:p3")
	if !m.IsResolving("w3:p3") {
		t.Fatal("deny should mark pane resolving")
	}
}

func TestUpsertReplaces(t *testing.T) {
	m := NewModel("/tmp/x.sock")
	m.UpsertAgent("w3:p3", "kilo", "working", "step 1")
	m.UpsertAgent("w3:p3", "kilo", "completed", "step 2")
	if got := m.AgentStatus("w3:p3"); got != "completed" {
		t.Fatalf("status after upsert = %q, want completed", got)
	}
}

func TestNoBlockedWhenEmpty(t *testing.T) {
	m := NewModel("/tmp/x.sock")
	if m.HasBlocked() {
		t.Fatal("empty model must not report blocked")
	}
}
