import Foundation

/// The terminal multiplexer family currently driving the control plane.
/// All adapters share the same verbs so the island UI never knows which
/// multiplexer is underneath.
enum PlexerKind: String, Sendable {
    case herdr
    case tmux
    case zellij

    var label: String {
        switch self {
        case .herdr: return "herdr"
        case .tmux: return "tmux"
        case .zellij: return "zellij"
        }
    }
}

/// Pure multiplexer detection: probe cheap facts first, never start a server.
enum PlexerDetection {
    /// - Parameters:
    ///   - env: process environment (injected for testability).
    ///   - herdrSocketExists: whether a herdr socket was found on disk.
    ///   - tmuxSocketExists: whether a tmux server socket was found.
    ///   - herdrBinaryExists: whether the herdr binary is on PATH.
    static func detect(
        env: [String: String],
        herdrSocketExists: Bool = false,
        tmuxSocketExists: Bool = false,
        herdrBinaryExists: Bool = true
    ) -> PlexerKind? {
        if env["HERDR_ENV"] == "1" || (herdrSocketExists && herdrBinaryExists) {
            return .herdr
        }
        if env["TMUX"] != nil || tmuxSocketExists {
            return .tmux
        }
        if env["ZELLIJ"] != nil {
            return .zellij
        }
        return nil
    }
}

/// Unified control-plane surface for any multiplexer. Every operation is
/// fire-and-forget from the UI side; blocking work belongs in a detached
/// task with a timeout.
protocol PlexerAdapter: Sendable {
    var kind: PlexerKind { get }

    func listPanes() -> [PaneInfo]
    /// Latest rendered output of a pane, up to `lines`.
    func captureTail(paneId: String, lines: Int) async -> String
    func focusPane(paneId: String)
    /// Sends a full line (text + Enter) to the pane.
    func sendLine(paneId: String, text: String)
    func sendKeys(paneId: String, keys: [String])
    func approve(paneId: String)
    func deny(paneId: String)
    /// Interrupts the running process (Ctrl-C equivalent).
    func stop(paneId: String)
    /// Best-effort: raise a GUI terminal attached to the pane.
    func attachPane(paneId: String)
}
