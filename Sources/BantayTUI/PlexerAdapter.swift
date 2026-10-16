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
    /// Probes environment and socket availability to detect active multiplexer.
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

/// Factory that dynamically produces the active multiplexer adapter based on runtime probe.
enum PlexerFactory {
    static func makeAdapter(
        env: [String: String] = ProcessInfo.processInfo.environment,
        herdrSocketExists: Bool = FileManager.default.fileExists(atPath: "/tmp/herdr.sock")
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.herdr.sock"),
        tmuxSocketExists: Bool? = nil,
        herdrBinaryExists: Bool = true
    ) -> any PlexerAdapter {
        let hasTmux = tmuxSocketExists ?? (env["TMUX"] != nil)
        let kind = PlexerDetection.detect(
            env: env,
            herdrSocketExists: herdrSocketExists,
            tmuxSocketExists: hasTmux,
            herdrBinaryExists: herdrBinaryExists
        )
        switch kind {
        case .tmux:
            return TmuxAdapter()
        case .zellij:
            return ZellijAdapter()
        case .herdr, .none:
            return HerdrSocketAdapter()
        }
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
    func approveChoice(paneId: String, choice: Int)
    func approveMulti(paneId: String, selections: [Int])
    /// Interrupts the running process (Ctrl-C equivalent).
    func stop(paneId: String)
    /// Best-effort: raise a GUI terminal attached to the pane.
    func attachPane(paneId: String)
    func agentPrompt(paneId: String, text: String) async
    func captureDiff(cwd: String, pathLimit: Int) async -> String?
}

extension PlexerAdapter {
    func approveChoice(paneId: String, choice: Int) {
        sendLine(paneId: paneId, text: String(choice))
    }

    func approveMulti(paneId: String, selections: [Int]) {
        let joined = selections.map(String.init).joined(separator: ",")
        sendLine(paneId: paneId, text: joined)
    }

    func paneFocus(paneId: String) {
        focusPane(paneId: paneId)
    }

    func agentPrompt(paneId: String, text: String) async {
        sendLine(paneId: paneId, text: text)
    }

    func captureDiff(cwd: String, pathLimit: Int = 10) async -> String? {
        guard !cwd.isEmpty else { return nil }
        let result = await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", cwd, "diff", "--stat"],
            timeout: 3.0)
        guard result.status == 0 else { return nil }
        let lines = result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let cap = max(pathLimit, 1)
        if lines.count <= cap + 1 {
            return lines.joined(separator: "\n")
        }
        let summary = lines.last ?? ""
        let files = lines.prefix(cap).joined(separator: "\n")
        let overflow = lines.count - 1 - cap
        return overflow > 0
            ? "\(files)\n+\(overflow) more\n\(summary)"
            : "\(files)\n\(summary)"
    }
}
