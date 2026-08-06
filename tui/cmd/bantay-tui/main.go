// Command bantay-tui is the standalone Go TUI companion for the Bantay
// control plane (plan 017 WI-7). It talks to the macOS app's control gateway
// (or herdr directly) over a Unix socket using the NDJSON wire contract, and
// renders agent status with approve/deny.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/8-BitRhyon/bantay-tui/tui/internal/gateway"
	"github.com/8-BitRhyon/bantay-tui/tui/internal/ui"
)

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("39"))
	errStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
	okStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
)

type tickMsg struct{}

type app struct {
	model   *ui.Model
	gateway *gateway.Client
	// For herdr-direct fallback later.
	lastError error
}

func defaultSocket() string {
	if env := os.Getenv("BANTAY_CONTROL_SOCKET"); env != "" {
		return env
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "/tmp/bantay.sock"
	}
	return filepath.Join(home, "Library", "Application Support", "Bantay-TUI", "control.sock")
}

func (a *app) Init() tea.Cmd {
	return tea.Batch(a.connect, tick())
}

func tick() tea.Cmd {
	return tea.Tick(2*time.Second, func(time.Time) tea.Msg { return tickMsg{} })
}

func (a *app) connect() tea.Msg {
	a.gateway = gateway.NewClient(a.model.SocketPath(), 2*time.Second)
	result, err := a.gateway.Call("bantay.ping", map[string]any{})
	if err != nil {
		a.model.MarkError(err.Error())
		return tickMsg{}
	}
	if result["type"] == "pong" {
		a.model.SetConnected()
	}
	return tickMsg{}
}

func (a *app) poll() tea.Msg {
	if a.gateway == nil {
		a.model.MarkError("not connected")
		return tickMsg{}
	}
	result, err := a.gateway.Call("agent.list", map[string]any{})
	if err != nil {
		a.model.MarkError(err.Error())
		return tickMsg{}
	}
	kind, _ := result["kind"].(string)
	_ = kind
	if agents, ok := result["agents"].([]any); ok {
		for _, raw := range agents {
			agent, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			paneID, _ := agent["paneId"].(string)
			source, _ := agent["agent"].(string)
			status, _ := agent["agentStatus"].(string)
			title, _ := agent["terminalTitle"].(string)
			if paneID == "" {
				continue
			}
			a.model.UpsertAgent(paneID, source, uiKind(status), title)
			if status != "blocked" {
				a.model.ClearResolving(paneID)
			}
		}
	}
	return tickMsg{}
}

func uiKind(status string) string {
	switch status {
	case "blocked":
		return "needs_input"
	case "working":
		return "working"
	case "idle", "waiting":
		return "waiting"
	case "done", "completed":
		return "completed"
	case "failed":
		return "failed"
	default:
		return "idle"
	}
}

func (a *app) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch m := msg.(type) {
	case tea.KeyMsg:
		switch m.String() {
		case "ctrl+c", "esc", "q":
			return a, tea.Quit
		case "y", "Y":
			a.approveFirst()
			return a, tick()
		case "n", "N":
			a.denyFirst()
			return a, tick()
		}
	case tickMsg:
		switch a.model.State() {
		case ui.StateConnecting, ui.StateError:
			if a.model.State() == ui.StateError {
				// Exponential backoff, capped at 8s.
				return a, tea.Tick(8*time.Second, func(time.Time) tea.Msg { return tickMsg{} })
			}
			return a, a.connect
		case ui.StateConnected:
			return a, a.poll
		}
	}
	return a, nil
}

func (a *app) approveFirst() {
	for _, row := range a.model.Agents() {
		if row.Status == "needs_input" && !a.model.IsResolving(row.PaneID) {
			a.model.Approve(row.PaneID)
			a.sendKeys(row.PaneID, []string{"y", "enter"})
			return
		}
	}
}

func (a *app) denyFirst() {
	for _, row := range a.model.Agents() {
		if row.Status == "needs_input" && !a.model.IsResolving(row.PaneID) {
			a.model.Deny(row.PaneID)
			a.sendKeys(row.PaneID, []string{"n", "enter"})
			return
		}
	}
}

func (a *app) sendKeys(paneID string, keys []string) {
	if a.gateway == nil {
		return
	}
	_, err := a.gateway.Call("pane.send_keys", map[string]any{
		"pane_id": paneID,
		"keys":    keys,
	})
	if err != nil {
		a.lastError = err
	}
}

func (a *app) View() string {
	var body string
	switch a.model.State() {
	case ui.StateConnecting:
		body = titleStyle.Render("bantay-tui") + "\n\n  connecting to " + a.model.SocketPath() + " …"
	case ui.StateError:
		body = titleStyle.Render("bantay-tui") + "\n\n" + errStyle.Render("  "+a.model.Error())
		body += "\n\n  Press q to quit. Will retry automatically."
	case ui.StateConnected:
		body = titleStyle.Render("bantay-tui") + "\n\n"
		rows := a.model.Agents()
		if len(rows) == 0 {
			body += "  No agents."
		} else {
			for _, row := range rows {
				body += fmt.Sprintf("  %-12s %-12s %s\n", row.Source, statusColor(row.Status), row.Title)
			}
		}
		body += "\n  [y] approve top  [n] deny top  [q] quit"
	}
	return body + "\n"
}

func statusColor(status string) string {
	switch status {
	case "needs_input":
		return lipgloss.NewStyle().Foreground(lipgloss.Color("220")).Render(status)
	case "completed":
		return okStyle.Render(status)
	case "failed":
		return errStyle.Render(status)
	default:
		return status
	}
}

func main() {
	socket := defaultSocket()
	m := ui.NewModel(socket)
	app := &app{model: m}
	if _, err := tea.NewProgram(app).Run(); err != nil {
		fmt.Fprintln(os.Stderr, errStyle.Render("bantay-tui: "+err.Error()))
		os.Exit(1)
	}
}
