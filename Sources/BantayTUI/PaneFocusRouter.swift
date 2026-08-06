import Foundation

/// Pure focus routing (plan 017 WI-3): maps a composed `paneId` to (a) the
/// multiplexer command that selects the pane and (b) the macOS terminal
/// activation strategy. Everything here is deterministic and harness-safe —
/// no process is ever spawned from this type; the caller (an adapter or the
/// island's focus button) executes the returned command and terminal action.
///
/// Pane ids drift: tmux `%N` regenerates on server restart and zellij pane
/// ids are session-scoped, so the composed id can stop resolving after the
/// mux restarts. The drift fallback re-keys by `tty` (strongest signal)
/// then `pid`, guarded against pid reuse (a pid that now belongs to a
/// different pane loses to a matching tty).
enum PaneFocusRouter {
    /// What a focus gesture resolves to. `standalone` means no multiplexer
    /// is involved (plain terminal app); `none` means nothing to focus.
    enum FocusTarget: Equatable {
        case tmux(session: String, window: String, pane: String)
        case zellij(session: String, pane: String)
        case herdr(paneId: String)
        case standalone
        case none
    }

    /// How to activate a focus target. `muxFocus` is reserved for a future
    /// no-terminal-activation slice; today mux kinds route to `.both`.
    enum RouteAction: Equatable {
        case muxFocus
        case terminalOnly
        case both
        case none
    }

    /// Parses a composed `paneId` into a `FocusTarget` for the given mux
    /// kind. tmux ids are `session:window.pane`, zellij ids are
    /// `session|pane` (the composition `ZellijAdapter.splitPaneId` already
    /// owns), and herdr ids are raw pane ids that pass through unchanged.
    /// A malformed id for the kind resolves to `.none`.
    static func resolveTarget(paneId: String, kind: PlexerKind) -> FocusTarget {
        switch kind {
        case .tmux:
            return parseTmuxTarget(paneId)
        case .zellij:
            guard let split = ZellijAdapter.splitPaneId(paneId) else { return .none }
            return .zellij(session: split.session, pane: split.pane)
        case .herdr:
            let trimmed = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .none : .herdr(paneId: trimmed)
        }
    }

    /// Drift-aware resolution for a focus gesture. A nil `kind` means no mux
    /// is detected → `.standalone` (activate the terminal app only). herdr
    /// ids are stable raw ids and pass through unchanged. tmux/zellij
    /// compose ids that regenerate on mux restart: when the parsed id no
    /// longer exists in the current pane list, re-key via tty/pid.
    static func resolveForFocus(
        paneId: String, kind: PlexerKind?, tty: String?, pid: Int?, panes: [PaneInfo]
    ) -> FocusTarget {
        guard let kind else { return .standalone }
        switch kind {
        case .herdr:
            return resolveTarget(paneId: paneId, kind: kind)
        case .tmux, .zellij:
            let direct = resolveTarget(paneId: paneId, kind: kind)
            guard case .none = direct else {
                // The composed id parses; without a pane list there is
                // nothing to drift against, so the direct target stands.
                guard !panes.isEmpty, !panes.contains(where: { $0.id == paneId }) else {
                    return direct
                }
                guard
                    let rekeyed = resolveDrifted(
                        stalePaneId: paneId, tty: tty, pid: pid, panes: panes)
                else {
                    return .none
                }
                return resolveTarget(paneId: rekeyed, kind: kind)
            }
            return .none
        }
    }

    /// Drift re-key: given a stale pane id plus the pane's last-known tty
    /// and pid, and the current pane list, resolve the id the pane now
    /// lives under. A live id wins verbatim; then the tty match (strongest
    /// signal — a tty is not reused while a pane holds it); then the pid
    /// match. A pid that maps to a *different* pane than the stale id is
    /// only accepted when no tty evidence exists (pid reuse guard).
    static func resolveDrifted(
        stalePaneId: String, tty: String?, pid: Int?, panes: [PaneInfo]
    ) -> String? {
        if panes.contains(where: { $0.id == stalePaneId }) { return stalePaneId }
        if let tty, !tty.isEmpty, let byTty = resolveByTty(tty: tty, panes: panes) {
            return byTty
        }
        if let pid, pid > 0, let byPid = resolveByPid(pid: pid, panes: panes) {
            return byPid
        }
        return nil
    }

    /// First pane whose `tty` matches, or nil. The strongest re-key signal.
    static func resolveByTty(tty: String, panes: [PaneInfo]) -> String? {
        guard !tty.isEmpty else { return nil }
        return panes.first { $0.tty == tty }?.id
    }

    /// First pane whose `pid` matches, or nil. Weaker than tty: pids are
    /// recycled by the OS, so a pid hit is only trusted after tty fails.
    static func resolveByPid(pid: Int, panes: [PaneInfo]) -> String? {
        guard pid > 0 else { return nil }
        return panes.first { $0.pid == pid }?.id
    }

    /// The fully executable command that selects the pane inside its mux,
    /// binary name included (argv[0]) so the caller can launch it as-is.
    /// tmux: `select-pane -t <s:w.p>` joined with `switch-client -t <s>`
    /// (tmux's `;` command separator) so the client follows the session.
    /// zellij: the 0.40+ `focus-pane-id` verb scoped to the session.
    /// herdr: the CLI `agent focus` verb. standalone/none → nil.
    static func focusCommand(target: FocusTarget) -> [String]? {
        switch target {
        case .tmux(let session, let window, let pane):
            return [
                "tmux", "select-pane", "-t", "\(session):\(window).\(pane)",
                ";", "switch-client", "-t", session,
            ]
        case .zellij(let session, let pane):
            return ["zellij", "--session", session, "action", "focus-pane-id", pane]
        case .herdr(let paneId):
            return ["herdr", "agent", "focus", paneId]
        case .standalone, .none:
            return nil
        }
    }

    /// Activation strategy per target: any mux → `.both` (select the pane
    /// inside the mux, then raise the terminal app); no mux → `.terminalOnly`
    /// (raise the terminal app only); unresolvable → `.none`.
    static func route(target: FocusTarget) -> RouteAction {
        switch target {
        case .tmux, .zellij, .herdr:
            return .both
        case .standalone:
            return .terminalOnly
        case .none:
            return .none
        }
    }

    /// tmux composed id `session:window.pane`. The window and pane halves
    /// are kept as the composed strings (numeric in practice); any shape
    /// that is not exactly one `:` and one `.` → `.none`.
    private static func parseTmuxTarget(_ paneId: String) -> FocusTarget {
        let colon = paneId.split(separator: ":", maxSplits: 1)
        guard colon.count == 2 else { return .none }
        let session = String(colon[0])
        let winPane = colon[1].split(separator: ".", omittingEmptySubsequences: false)
        guard winPane.count == 2 else { return .none }
        let window = String(winPane[0])
        let pane = String(winPane[1])
        guard !session.isEmpty, !window.isEmpty, !pane.isEmpty else { return .none }
        return .tmux(session: session, window: window, pane: pane)
    }
}
