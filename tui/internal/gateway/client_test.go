package gateway

import (
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"
)

// startMockServer runs an in-process UDS server that responds to any request
// line with a pong response. Returns the socket path.
func startMockServer(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	sock := filepath.Join(dir, "control.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 4096)
				n, _ := c.Read(buf)
				var req map[string]any
				json.Unmarshal(buf[:n], &req)
				id, _ := req["id"].(string)
				resp, _ := json.Marshal(map[string]any{
					"id":     id,
					"result": map[string]any{"type": "pong", "v": 1, "kind": "herdr"},
					"error":  nil,
				})
				c.Write(append(resp, '\n'))
			}(conn)
		}
	}()
	return sock
}

func TestCallRoundTrip(t *testing.T) {
	sock := startMockServer(t)
	client := NewClient(sock, 2*time.Second)
	defer client.Close()
	result, err := client.Call("bantay.ping", map[string]any{})
	if err != nil {
		t.Fatalf("Call: %v", err)
	}
	if result["type"] != "pong" {
		t.Fatalf("result = %v, want pong", result)
	}
}

func TestCallTimeout(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "control.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer l.Close()
	// Accept but never respond — the client must time out.
	go func() {
		conn, _ := l.Accept()
		if conn != nil {
			defer conn.Close()
			time.Sleep(5 * time.Second)
		}
	}()
	client := NewClient(sock, 300*time.Millisecond)
	defer client.Close()
	if _, err := client.Call("bantay.ping", map[string]any{}); err == nil {
		t.Fatal("Call on silent server expected timeout error")
	}
}

func TestCallMissingSocket(t *testing.T) {
	client := NewClient(filepath.Join(t.TempDir(), "nope.sock"), time.Second)
	defer client.Close()
	if _, err := client.Call("bantay.ping", map[string]any{}); err == nil {
		t.Fatal("Call on missing socket expected error")
	}
}
