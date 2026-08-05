import AppKit
import Foundation

/// tmux pane adapter (plan 017 WI-1), mirroring `HerdrSocketAdapter`'s
/// structure: executable discovery via PATH, CLI verb construction, and
/// fire-and-forget sends from detached tasks. Every verb is a pure client
/// command (`list-panes`, `select-pane`, `send-keys`, `capture-pane`, ...) —
/// a machine with no tmux server simply reports no panes, and listing never
/// auto-starts a server (`new-session`/`start-server` are never used).
struct TmuxAdapter: Sendable, PlexerAdapter {
    private let tmuxBinPath: String

    var kind: PlexerKind { .tmux }

    init(tmuxBinPath: String = "tmux") {
        self.tmuxBinPath = tmuxBinPath
    }

    /// Every location a tmux binary can live, most specific first: PATH
    /// dirs, then Homebrew on Apple Silicon, Homebrew on Intel, and the
    /// system bindirs (for GUI-launched processes with a stripped PATH).
    /// Pure for tests.
    static func candidateTmuxPaths(
        env: [String: String], home: String, binName: String = "tmux"
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            candidates.append(path)
        }
        if let pathEnv = env["PATH"] {
            for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
                add(String(dir) + "/" + binName)
            }
        }
        add("/opt/homebrew/bin/" + binName)
        add("/usr/local/bin/" + binName)
        add("/usr/bin/" + binName)
        add("/bin/" + binName)
        return candidates
    }

    private func tmuxExecutableURL() -> URL? {
        for path in Self.candidateTmuxPaths(
            env: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
            binName: tmuxBinPath)
        {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// CLI fallback: run tmux through the non-blocking `ProcessRunner`.
    /// Never blocks the caller; `ProcessRunner.run` drains output
    /// concurrently and terminates on timeout.
    private func runTmuxAsync(_ arguments: [String], timeout: TimeInterval = 3.0) async -> String {
        guard let url = tmuxExecutableURL() else { return "" }
        let result = await ProcessRunner.run(
            executableURL: url, arguments: arguments, timeout: timeout)
        return result.stdout
    }

    // MARK: - tmux pane listing

    /// Full 8-field `-F` template: session, window, pane, id, tty, shell
    /// pid, current command, current path.
    static let fullPaneTemplate =
        "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}"
        + "\t#{pane_tty}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}"

    /// Minimal 4-field fallback for older tmux versions whose `-F` support
    /// predates the per-pane detail variables.
    static let minimalPaneTemplate = "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}"

    /// `list-panes` invocation variants in preference order (the exact
    /// dual-format fallback pattern of `HerdrSocketAdapter.paneListCommandVariants`).
    /// Both are pure reads — never `new-session`/`start-server`.
    static func paneListCommandVariants() -> [[String]] {
        [
            ["list-panes", "-a", "-F", fullPaneTemplate],
            ["list-panes", "-a", "-F", minimalPaneTemplate],
        ]
    }

    /// Parse `tmux list-panes -a -F ...` output into `PaneInfo` values.
    ///
    /// Two template shapes are accepted: the full 8-field shape and the
    /// minimal 4-field shape. tmux emits the literal `%N` pane id, which
    /// regenerates on server restart, so the stable `PaneInfo.id` is composed
    /// as `session:window.pane`. A tab inside the trailing `currentPath`
    /// field widens the line past 8 columns — the remainder is rejoined so
    /// the value survives. Quoted fields (`#{q:...}` style or hand-quoted)
    /// are unquoted. Empty output is `[]`; any line that matches neither
    /// template shape (or fewer than 4 fields) is skipped.
    static func parsePaneLines(_ output: String) -> [PaneInfo] {
        var panes: [PaneInfo] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.split(separator: "\t").map(unquoted)
            let count = fields.count
            guard count >= 4 else { continue }
            let session = fields[0]
            guard !session.isEmpty else { continue }
            let windowRaw = fields[1]
            let paneRaw = fields[2]
            let id = "\(session):\(windowRaw).\(paneRaw)"
            var info = PaneInfo(id: id, title: nil, cwd: nil, workspaceId: nil)
            info.session = session
            info.windowIndex = Int(windowRaw)
            info.paneIndex = Int(paneRaw)
            switch count {
            case 4:
                break
            case 8:
                info.tty = fields[4]
                info.pid = Int(fields[5])
                info.currentCommand = fields[6]
                info.currentPath = fields[7]
            case 9...:
                info.tty = fields[4]
                info.pid = Int(fields[5])
                info.currentCommand = fields[6]
                info.currentPath = fields[7...].joined(separator: "\t")
            default:
                // 5-7 fields match neither template shape — malformed.
                continue
            }
            panes.append(info)
        }
        return panes
    }

    /// Strip surrounding double quotes from a raw `-F` field value.
    private static func unquoted(_ raw: Substring) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// The tmux target spec `session:window.pane` is the id as composed by
    /// `parsePaneLines`, so pane ids pass through unchanged.
    static func paneTarget(from paneId: String) -> String? {
        let trimmed = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The session component of a composed pane id (everything before the
    /// first colon), used by `switch-client`.
    static func sessionName(from paneId: String) -> String? {
        let part = paneId.split(separator: ":", maxSplits: 1).first.map(String.init)
        guard let part, !part.isEmpty else { return nil }
        return part
    }

    // MARK: - PlexerAdapter

    /// Async workhorse behind the sync `listPanes()` protocol seam: try the
    /// full template, fall back to the minimal template when the full one
    /// yields nothing parseable.
    nonisolated func listPanesAsync() async -> [PaneInfo] {
        for args in Self.paneListCommandVariants() {
            let output = await runTmuxAsync(args)
            guard !output.isEmpty else { continue }
            let panes = Self.parsePaneLines(output)
            if !panes.isEmpty { return panes }
        }
        return []
    }

    /// Sync protocol seam (PlexerAdapter) — the D2 boundary shared by all
    /// adapters, so its signature must stay put. No app caller today; the
    /// fetch runs on a background task and the calling thread waits on the
    /// result, so a hypothetical main-actor caller never holds
    /// `waitUntilExit` on the main thread.
    func listPanes() -> [PaneInfo] {
        final class Box: @unchecked Sendable {
            var panes: [PaneInfo] = []
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            box.panes = await self.listPanesAsync()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 4.0)
        return box.panes
    }

    func captureTail(paneId: String, lines: Int) async -> String {
        guard let target = Self.paneTarget(from: paneId) else { return "" }
        let count = max(lines, 1)
        return await runTmuxAsync(
            ["capture-pane", "-p", "-t", target, "-S", "-\(count)"],
            timeout: 2.0)
    }

    /// Selects the pane inside tmux, switches the client to its session, then
    /// raises the GUI terminal hosting the pane via `TerminalFocusser`.
    func focusPane(paneId: String) {
        guard let target = Self.paneTarget(from: paneId) else { return }
        let session = Self.sessionName(from: paneId)
        Task.detached { [self] in
            _ = await runTmuxAsync(["select-pane", "-t", target], timeout: 1.0)
            if let session {
                _ = await runTmuxAsync(["switch-client", "-t", session], timeout: 1.0)
            }
            await MainActor.run {
                _ = TerminalFocusser.focus()
            }
        }
    }

    /// Sends raw key presses to the pane. Works without focus.
    func sendKeys(paneId: String, keys: [String]) {
        guard let target = Self.paneTarget(from: paneId) else { return }
        Task.detached { [self] in
            var arguments = ["send-keys", "-t", target]
            arguments.append(contentsOf: keys)
            _ = await runTmuxAsync(arguments, timeout: 1.0)
        }
    }

    func sendLine(paneId: String, text: String) {
        sendKeys(paneId: paneId, keys: [text, "enter"])
    }

    /// Approves a yes-no "Need approval" prompt (e.g. "y" + Enter).
    func approve(paneId: String) {
        sendKeys(paneId: paneId, keys: ["y", "enter"])
    }

    /// Denies a yes-no "Need approval" prompt (e.g. "n" + Enter).
    func deny(paneId: String) {
        sendKeys(paneId: paneId, keys: ["n", "enter"])
    }

    /// Responds to a single-choice prompt with the 1-based option index.
    func approveChoice(paneId: String, choice: Int) {
        sendKeys(paneId: paneId, keys: [String(choice), "enter"])
    }

    /// Responds to a multi-select prompt with the comma-joined, 1-based
    /// option indices followed by Enter (e.g. "1,3" + Enter).
    func approveMulti(paneId: String, selections: [Int]) {
        let joined = selections.map(String.init).joined(separator: ",")
        sendKeys(paneId: paneId, keys: [joined, "enter"])
    }

    /// Interrupts the running process (Ctrl-C equivalent).
    func stop(paneId: String) {
        sendKeys(paneId: paneId, keys: ["ctrl+c"])
    }

    func attachPane(paneId: String) {
        focusPane(paneId: paneId)
    }
}
