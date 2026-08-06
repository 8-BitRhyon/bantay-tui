// Package wire implements the Bantay NDJSON wire contract (D2 in plan 015):
// one JSON object per line, versioned, unknown fields ignored, unknown
// methods rejected. Mirrors HerdrSocketProtocol / ControlGateway framing.
package wire

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// MaxLineSize caps a single NDJSON line (mirrors the Swift 64 KiB cap).
const MaxLineSize = 64 * 1024

// ResponseError is the error shape of a gateway response.
type ResponseError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Response is a parsed gateway response line.
type Response struct {
	ID     string          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *ResponseError  `json:"error"`
}

// RequestLine builds a single NDJSON request line.
func RequestLine(id, method string, params map[string]any) string {
	if params == nil {
		params = map[string]any{}
	}
	req := map[string]any{
		"id":     id,
		"method": method,
		"params": params,
	}
	data, _ := json.Marshal(req)
	return string(data)
}

// ParseResponse parses one NDJSON response line.
func ParseResponse(line string) (*Response, error) {
	if line == "" {
		return nil, fmt.Errorf("empty response line")
	}
	var resp Response
	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		return nil, fmt.Errorf("malformed response: %w", err)
	}
	if resp.ID == "" {
		return nil, fmt.Errorf("response missing id")
	}
	if resp.Error == nil && resp.Result == nil {
		return nil, fmt.Errorf("response missing result and error")
	}
	return &resp, nil
}

// ExtractLines splits a byte buffer into complete NDJSON lines. A partial
// trailing line is dropped. Each returned line is capped at MaxLineSize.
func ExtractLines(data []byte) []string {
	var lines []string
	for {
		idx := bytes.IndexByte(data, '\n')
		if idx < 0 {
			break
		}
		line := data[:idx]
		data = data[idx+1:]
		if len(line) > MaxLineSize {
			line = line[:MaxLineSize]
		}
		if len(line) > 0 {
			lines = append(lines, string(line))
		}
	}
	return lines
}
