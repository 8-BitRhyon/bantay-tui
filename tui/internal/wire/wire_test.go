package wire

import "testing"

func TestRequestLine(t *testing.T) {
	line := RequestLine("req_1", "bantay.ping", map[string]any{})
	want := `{"id":"req_1","method":"bantay.ping","params":{}}`
	if line != want {
		t.Fatalf("RequestLine = %q, want %q", line, want)
	}
}

func TestParseResponseSuccess(t *testing.T) {
	resp, err := ParseResponse(`{"id":"r","result":{"type":"pong","v":1},"error":null}`)
	if err != nil {
		t.Fatalf("ParseResponse error: %v", err)
	}
	if resp.ID != "r" {
		t.Fatalf("ID = %q, want r", resp.ID)
	}
	if resp.Error != nil {
		t.Fatalf("Error = %v, want nil", resp.Error)
	}
	if resp.Result == nil {
		t.Fatal("Result is nil, want object")
	}
}

func TestParseResponseError(t *testing.T) {
	resp, err := ParseResponse(
		`{"id":"r","result":null,"error":{"code":"unknown_method","message":"bantay.x"}}`)
	if err != nil {
		t.Fatalf("ParseResponse error: %v", err)
	}
	if resp.Error == nil {
		t.Fatal("Error is nil, want set")
	}
	if resp.Error.Code != "unknown_method" {
		t.Fatalf("Error.Code = %q, want unknown_method", resp.Error.Code)
	}
}

func TestParseResponseGarbage(t *testing.T) {
	if _, err := ParseResponse(`not json`); err == nil {
		t.Fatal("ParseResponse(garbage) expected error")
	}
	if _, err := ParseResponse(`{"id":"r"}`); err == nil {
		t.Fatal("ParseResponse(missing method/result) expected error")
	}
	if _, err := ParseResponse(""); err == nil {
		t.Fatal("ParseResponse(empty) expected error")
	}
}

func TestExtractLines(t *testing.T) {
	lines := ExtractLines([]byte("{\"a\":1}\n{\"b\":2}\n"))
	if len(lines) != 2 {
		t.Fatalf("ExtractLines = %d lines, want 2", len(lines))
	}
	lines = ExtractLines([]byte("partial"))
	if len(lines) != 0 {
		t.Fatalf("ExtractLines(partial) = %d lines, want 0", len(lines))
	}
	lines = ExtractLines([]byte("{\"a\":1}\n{\"b\":2}"))
	if len(lines) != 1 {
		t.Fatalf("ExtractLines(no trailing newline) = %d lines, want 1", len(lines))
	}
}

func TestExtractLinesCap(t *testing.T) {
	// A single line over 64 KiB must be split or dropped, never returned whole.
	big := make([]byte, 64*1024+1)
	for i := range big {
		big[i] = 'x'
	}
	lines := ExtractLines(append(big, '\n'))
	for _, l := range lines {
		if len(l) > 64*1024 {
			t.Fatalf("line length %d exceeds 64 KiB cap", len(l))
		}
	}
}
