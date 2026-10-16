import Foundation

/// Focus routing: maps composed pane identifiers to multiplexer commands and terminal focus.
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

    /// Parses a composed multiplexer pane identifier into a structured FocusTarget.
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

    /// Resolves target multiplexer and pane taking drift into account.
    static func resolveForFocus(
        paneId: String, kind: PlexerKind?, tty: String?, pid: Int?, panes: [PaneInfo]
    ) -> FocusTarget {
        guard let kind else { return .standalone }
        if kind == .herdr { return resolveTarget(paneId: paneId, kind: kind) }

        let direct = resolveTarget(paneId: paneId, kind: kind)
        guard direct != .none else { return .none }
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

    /// Re-resolves a pane identifier that may have drifted across mux restarts using tty or pid.
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

    /// Generates the CLI command to focus the targeted multiplexer pane.
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
