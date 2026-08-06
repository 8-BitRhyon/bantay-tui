package taskspec

import "testing"

func TestTaskSpecRoundTrip(t *testing.T) {
	in := TaskSpec{
		Version:     1,
		Goal:        "Add --dry-run flag",
		Files:       []string{"src/main.go"},
		Constraints: []string{"no new deps"},
		Source:      "bantay-tui",
	}
	data, err := in.Marshal()
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var out TaskSpec
	if err := out.Unmarshal(data); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if out.Version != in.Version || out.Goal != in.Goal || out.Source != in.Source {
		t.Fatalf("round-trip mismatch: %+v != %+v", out, in)
	}
	if len(out.Files) != len(in.Files) || len(out.Constraints) != len(in.Constraints) {
		t.Fatalf("slice length mismatch: %+v != %+v", out, in)
	}
}

func TestTaskSpecUnknownFieldsTolerated(t *testing.T) {
	// Unknown fields must be ignored, not rejected.
	data := []byte(
		`{"v":1,"goal":"g","files":["a"],"constraints":["c"],"source":"s","future_field":42}`)
	var out TaskSpec
	if err := out.Unmarshal(data); err != nil {
		t.Fatalf("Unmarshal with unknown field: %v", err)
	}
	if out.Goal != "g" {
		t.Fatalf("Goal = %q, want g", out.Goal)
	}
}

func TestTaskSpecEmpty(t *testing.T) {
	var out TaskSpec
	if err := out.Unmarshal([]byte(`{}`)); err != nil {
		t.Fatalf("Unmarshal({}) : %v", err)
	}
	if out.Version != 0 {
		t.Fatalf("Version = %d, want 0", out.Version)
	}
}
