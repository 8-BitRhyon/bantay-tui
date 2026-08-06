// Package gateway implements a minimal UDS client speaking the Bantay NDJSON
// wire contract (W1). Dial once, one request line, one response line, close.
package gateway

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/8-BitRhyon/bantay-tui/tui/internal/wire"
)

// Client is a control-gateway UDS client.
type Client struct {
	socketPath string
	timeout    time.Duration
}

// NewClient creates a client for the given UDS path.
func NewClient(socketPath string, timeout time.Duration) *Client {
	return &Client{socketPath: socketPath, timeout: timeout}
}

// Close is a no-op for the per-call dial model.
func (c *Client) Close() {}

// Call sends one request and returns the parsed result object.
func (c *Client) Call(method string, params map[string]any) (map[string]any, error) {
	conn, err := net.DialTimeout("unix", c.socketPath, c.timeout)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", c.socketPath, err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(c.timeout))

	line := wire.RequestLine("tui_1", method, params)
	if _, err := conn.Write([]byte(line + "\n")); err != nil {
		return nil, fmt.Errorf("write: %w", err)
	}

	reader := bufio.NewReader(conn)
	respLine, err := reader.ReadString('\n')
	if err != nil {
		return nil, fmt.Errorf("read: %w", err)
	}
	resp, err := wire.ParseResponse(strings.TrimSpace(respLine))
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("%s: %s", resp.Error.Code, resp.Error.Message)
	}
	var result map[string]any
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return nil, fmt.Errorf("result decode: %w", err)
	}
	return result, nil
}
