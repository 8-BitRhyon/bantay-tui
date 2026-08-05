import Foundation

/// `PlexerAdapter` for the zellij terminal multiplexer (plan 017 WI-2).
///
/// Session listing goes through `zellij ls --short` (one session name per
/// line); pane listing through `zellij --session <name> action list-panes
/// --json`; capture through `zellij --session <name> action dump-screen
/// --pane-id <pane>`; focus/keys through the `zellij action` verbs below.
///
/// **Version assumption: zellij >= 0.40** — 0.40 reorganized `zellij action`
/// into subcommands (`dump-screen`, `focus-pane-id`, `send-keys`,
/// `write-chars`, `list-panes`). Verb spellings below were verified against
/// the current zellij docs and the CLI source at `main` (2026-08); an
/// unknown verb fails with exit != 0 and empty stdout, which surfaces as
/// empty results rather than a fabricated pane list.
///
/// **Pane identity**: zellij pane ids are session-scoped (`terminal_N`) and
/// die with their session. The protocol's single `paneId` string composes
/// them as `"<session>|<pane>"`; `|` is safe because zellij session names
/// are socket-path components and are not validated to exclude `:`, which
/// rules out tmux's `session:window.pane` separator.
struct ZellijAdapter: Sendable, PlexerAdapter {
    private let zellijBinPath: String

    var kind: PlexerKind { .zellij }

    init(zellijBinPath: String = "zellij") {
        self.zellijBinPath = zellijBinPath
    }

    // MARK: - Identity: (session, pane) composition

    /// Separator between the session and pane halves of a composed paneId.
    nonisolated static let paneIdSeparator = "|"

    /// Composes `(session, pane)` into the single paneId string the protocol
    /// uses, e.g. `("dev", "terminal_3")` -> `"dev|terminal_3"`.
    nonisolated static func composePaneId(session: String, pane: String) -> String {
        "\(session)\(paneIdSeparator)\(pane)"
    }

    /// Splits a composed paneId back into its `(session, pane)` halves.
    /// Returns nil for a string without the separator or with an empty half.
    nonisolated static func splitPaneId(_ paneId: String) -> (session: String, pane: String)? {
        guard
            let separator = paneId.firstIndex(of: Character(paneIdSeparator)),
            separator != paneId.startIndex
        else { return nil }
        let session = String(paneId[..<separator])
        let pane = String(paneId[paneId.index(after: separator)...])
        guard !session.isEmpty, !pane.isEmpty else { return nil }
        return (session, pane)
    }

    /// Stored pane ids whose session no longer exists. Zellij pane ids are
    /// session-scoped, so killing a session drifts every pane id under it;
    /// those ids must be dropped rather than re-targeted.
    nonisolated static func driftedPaneIds(
        paneIds: [String], activeSessions: [String]
    ) -> [String] {
        let active = Set(activeSessions)
        return paneIds.filter { paneId in
            guard let session = splitPaneId(paneId)?.session else { return false }
            return !active.contains(session)
        }
    }

    // MARK: - Session listing

    /// Session listing verb. `--short` prints one session name per line,
    /// which is the parseable form; the JSON variants of `parseSessions`
    /// exist for wrappers/future zellij versions that emit JSON.
    nonisolated static func listSessionsCommand() -> [String] {
        ["ls", "--short"]
    }

    /// Parses `zellij ls` output (text or JSON) into session names. Text
    /// variants keep the first whitespace-delimited token of each line
    /// (`--short` names, `--no-formatting` "name [Created X ago] [suffix]",
    /// and the default ANSI-styled output after stripping escape codes).
    /// Unhandled output (empty stdout on an unknown verb/flag, malformed
    /// JSON) yields empty results.
    nonisolated static func parseSessions(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("[") {
            return parseSessionsJSON(trimmed)
        }
        var sessions: [String] = []
        var seen = Set<String>()
        for rawLine in output.split(separator: "\n") {
            let line = stripANSI(String(rawLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let name = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            sessions.append(name)
        }
        return sessions
    }

    /// JSON variant of `parseSessions`: a `["a","b"]` string array or an
    /// array of objects carrying `name` / `session_name` / `id`.
    nonisolated static func parseSessionsJSON(_ json: String) -> [String] {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        if let names = object as? [String] {
            return names
        }
        if let items = object as? [[String: Any]] {
            return items.compactMap { item -> String? in
                if let name = item["name"] as? String { return name }
                if let name = item["session_name"] as? String { return name }
                if let name = item["id"] as? String { return name }
                return nil
            }
        }
        return []
    }

    /// Strips ANSI CSI sequences (the default `zellij ls` colors the session
    /// name and age) so the name token is extractable.
    nonisolated static func stripANSI(_ line: String) -> String {
        line.replacingOccurrences(
            of: "\u{1b}\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression)
    }

    // MARK: - Pane listing

    /// Pane listing verb, scoped to a session via the global `--session`
    /// flag. `--json` is the machine-consumable form of `list-panes`.
    nonisolated static func listPanesCommand(session: String) -> [String] {
        ["--session", session, "action", "list-panes", "--json"]
    }

    /// Parses `zellij action list-panes --json` output for one session into
    /// protocol `PaneInfo` rows. Plugin panes and exited panes are not agent
    /// surfaces and are skipped; `workspaceId` maps to the session name.
    nonisolated static func parsePaneList(_ output: String, session: String) -> [PaneInfo] {
        guard
            let data = output.data(using: .utf8),
            let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        var panes: [PaneInfo] = []
        for item in items {
            guard item["is_plugin"] as? Bool != true,
                item["exited"] as? Bool != true,
                let id = item["id"] as? Int
            else { continue }
            panes.append(
                PaneInfo(
                    id: composePaneId(session: session, pane: "terminal_\(id)"),
                    title: item["title"] as? String,
                    cwd: item["pane_cwd"] as? String,
                    workspaceId: session))
        }
        return panes
    }

    /// `zellij action` verbs verified against the zellij 0.40+ surface.
    /// Verbs outside this set are unhandled and must yield empty results,
    /// never a fabricated pane or command.
    nonisolated static let supportedActionVerbs: Set<String> = [
        "list-panes",
        "dump-screen",
        "focus-pane-id",
        "send-keys",
        "write-chars",
    ]

    nonisolated static func supportsActionVerb(_ verb: String) -> Bool {
        supportedActionVerbs.contains(verb)
    }

    // MARK: - Capture

    /// Capture verb: dumps the pane viewport to stdout (no `--path`).
    nonisolated static func captureCommand(session: String, pane: String) -> [String] {
        ["--session", session, "action", "dump-screen", "--pane-id", pane]
    }

    // MARK: - Focus / input

    /// Focus verb: focuses a specific pane by its session-scoped id.
    nonisolated static func focusCommand(session: String, pane: String) -> [String] {
        ["--session", session, "action", "focus-pane-id", pane]
    }

    /// Send-keys verb. Keys are passed as individual space-separated args;
    /// herdr-style names ("enter", "ctrl+c") are mapped to zellij spellings
    /// ("Enter", "Ctrl c") so the shared approve/deny/stop call sites work.
    nonisolated static func sendKeysCommand(
        session: String, pane: String, keys: [String]
    ) -> [String] {
        ["--session", session, "action", "send-keys", "--pane-id", pane]
            + keys.map { zellijKeyName(for: $0) }
    }

    /// Write-chars verb: injects literal characters (no Enter) into a pane.
    nonisolated static func writeCharsCommand(
        session: String, pane: String, text: String
    ) -> [String] {
        ["--session", session, "action", "write-chars", "--pane-id", pane, text]
    }

    /// Maps the protocol's key names to zellij's `send-keys` spellings
    /// (docs: "Enter", "Ctrl c", "Alt b", single chars pass through).
    nonisolated static func zellijKeyName(for key: String) -> String {
        let lower = key.lowercased()
        switch lower {
        case "enter", "return", "cr": return "Enter"
        case "esc", "escape": return "Escape"
        case "tab": return "Tab"
        case "space", "spc": return "Space"
        case "backspace", "bs": return "Backspace"
        case "up": return "Up"
        case "down": return "Down"
        case "left": return "Left"
        case "right": return "Right"
        case "home": return "Home"
        case "end": return "End"
        case "pageup": return "PageUp"
        case "pagedown": return "PageDown"
        case "ctrl+c", "ctrl-c": return "Ctrl c"
        case "ctrl+d", "ctrl-d": return "Ctrl d"
        case "ctrl+z", "ctrl-z": return "Ctrl z"
        default:
            if lower.count == 1 { return key }
            for prefix in ["ctrl+", "alt+", "shift+"] where lower.hasPrefix(prefix) {
                let rest = String(lower.dropFirst(prefix.count)).capitalized
                return prefix.dropLast(1).capitalized + " " + rest
            }
            return key
        }
    }

    // MARK: - Executable discovery

    /// Every location a zellij binary can live, most specific first: PATH
    /// dirs, then the common Homebrew/locals. Pure for tests.
    nonisolated static func candidateZellijPaths(
        env: [String: String], home: String, binName: String = "zellij"
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
        add(home + "/.local/bin/" + binName)
        return candidates
    }

    private func zellijExecutableURL() -> URL? {
        for path in Self.candidateZellijPaths(
            env: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            binName: zellijBinPath)
        {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// CLI workhorse behind every read verb. Unknown verbs exit nonzero with
    /// empty stdout, so the caller sees `""` and returns empty results.
    private func runZellijAsync(
        _ arguments: [String], timeout: TimeInterval = 3.0
    ) async -> String {
        guard let url = zellijExecutableURL() else { return "" }
        let result = await ProcessRunner.run(
            executableURL: url, arguments: arguments, timeout: timeout)
        return result.stdout
    }

    // MARK: - PlexerAdapter

    /// Async workhorse behind the sync `listPanes()` protocol seam.
    nonisolated func listPanesAsync() async -> [PaneInfo] {
        let output = await runZellijAsync(Self.listSessionsCommand())
        let sessions = Self.parseSessions(output)
        guard !sessions.isEmpty else { return [] }
        var panes: [PaneInfo] = []
        for session in sessions {
            let paneOutput = await runZellijAsync(Self.listPanesCommand(session: session))
            guard !paneOutput.isEmpty else { continue }
            panes.append(contentsOf: Self.parsePaneList(paneOutput, session: session))
        }
        return panes
    }

    /// Sync protocol seam (PlexerAdapter) — the D2 boundary. Mirrors
    /// `HerdrSocketAdapter.listPanes`: the fetch runs on a background task
    /// and the calling thread waits on the result, so a main-actor caller
    /// never holds `waitUntilExit` on the main thread.
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
        guard let target = Self.splitPaneId(paneId) else { return "" }
        let output = await runZellijAsync(
            Self.captureCommand(session: target.session, pane: target.pane),
            timeout: 2.0)
        guard !output.isEmpty else { return "" }
        let rows = output.split(whereSeparator: \.isNewline)
        let cap = max(lines, 1)
        guard rows.count > cap else { return output }
        return rows.suffix(cap).joined(separator: "\n")
    }

    func focusPane(paneId: String) {
        guard
            let target = Self.splitPaneId(paneId),
            let url = zellijExecutableURL()
        else { return }
        ProcessRunner.launch(
            executableURL: url,
            arguments: Self.focusCommand(session: target.session, pane: target.pane))
    }

    func sendLine(paneId: String, text: String) {
        guard
            let target = Self.splitPaneId(paneId),
            let url = zellijExecutableURL()
        else { return }
        ProcessRunner.launch(
            executableURL: url,
            arguments: Self.writeCharsCommand(
                session: target.session, pane: target.pane, text: text))
        ProcessRunner.launch(
            executableURL: url,
            arguments: Self.sendKeysCommand(
                session: target.session, pane: target.pane, keys: ["enter"]))
    }

    func sendKeys(paneId: String, keys: [String]) {
        guard
            let target = Self.splitPaneId(paneId),
            let url = zellijExecutableURL()
        else { return }
        ProcessRunner.launch(
            executableURL: url,
            arguments: Self.sendKeysCommand(
                session: target.session, pane: target.pane, keys: keys))
    }

    func approve(paneId: String) {
        sendKeys(paneId: paneId, keys: ["y", "enter"])
    }

    func deny(paneId: String) {
        sendKeys(paneId: paneId, keys: ["n", "enter"])
    }

    func stop(paneId: String) {
        sendKeys(paneId: paneId, keys: ["ctrl+c"])
    }

    func attachPane(paneId: String) {
        focusPane(paneId: paneId)
    }
}
