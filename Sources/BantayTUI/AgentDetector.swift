import Foundation

/// A coding-agent CLI process detected on the machine, independent of any
/// multiplexer. Lets Bantay surface agents running in plain terminals.
struct DetectedAgent: Equatable, Sendable {
    let pid: Int
    /// Canonical agent name, e.g. "claude", "codex", "gemini", "cursor".
    let name: String
    /// Latest human-readable activity (tail of the agent's transcript).
    let activity: String?
    /// Whether the agent was modified recently enough to be actively running work.
    let isWorking: Bool

    init(pid: Int, name: String, activity: String?, isWorking: Bool = false) {
        self.pid = pid
        self.name = name
        self.activity = activity
        self.isWorking = isWorking
    }
}

/// Pure process classification + transcript discovery for standalone agents.
/// The manager scans processes, this type decides what is an agent and where
/// its activity lives.
enum AgentDetector {
    /// Transcript files per agent family, newest-first. Used to peek the
    /// latest activity line without requiring a multiplexer.
    static func transcriptSearchPaths(home: String, name: String) -> [String] {
        let homePath = home.isEmpty ? NSHomeDirectory() : home
        switch name {
        case "claude", "claude-code":
            return [
                homePath + "/.claude/projects",
                homePath + "/.claude/transcripts",
                homePath + "/.claude/history",
            ]
        case "codex":
            return [
                homePath + "/.codex/sessions",
                homePath + "/.codex/transcripts",
            ]
        case "gemini", "gemini-cli":
            return [
                homePath + "/.gemini/sessions",
                homePath + "/.gemini/antigravity-ide/brain",
            ]
        case "antigravity", "antigravity-ide", "antigravity-cli", "agy":
            return [
                homePath + "/.gemini/antigravity-ide/brain",
                homePath + "/.gemini/sessions",
                homePath + "/.gemini/antigravity-ide",
                homePath + "/.gemini",
            ]
        case "cursor", "cursor-agent":
            return [homePath + "/.cursor-agent"]
        case "kilo", "kilocode":
            return [
                homePath + "/.local/share/kilo/log",
                homePath + "/.local/state/kilo",
                homePath + "/.config/kilo",
            ]
        case "freebuff":
            return [
                // Real freebuff activity lives in per-project JSONL logs under
                // the state dir — NOT ~/.config/manicode/freebuff (that path
                // is the binary itself).
                homePath + "/.local/state/manicode/projects",
                homePath + "/.local/state/manicode",
            ]
        case "pi":
            return [
                // Pi auto-saves every session as append-only JSONL under
                // ~/.pi/agent/sessions, one file per cwd tree. The parent
                // ~/.pi/agent dir holds settings/auth/trust files that aren't
                // transcripts, so sessions is the single authoritative root.
                homePath + "/.pi/agent/sessions"
            ]
        case "herdr":
            return [
                homePath + "/.config/herdr",
                homePath + "/.local/state/herdr",
            ]
        default:
            return []
        }
    }

    /// Maps a process name (basename) to a canonical agent name, or nil.
    static func canonicalName(forProcess processName: String) -> String? {
        let lower = processName.lowercased()
        if lower.contains("helper")
            || lower.contains("renderer")
            || lower.contains("gpu")
            || lower.contains("plugin")
            || lower.contains("crashpad")
            || lower.contains("utility")
        {
            return nil
        }
        if lower.contains("antigravity") || lower.contains("agy") {
            return "antigravity"
        }
        switch lower {
        case "claude", "claude-code", "claude-agent", "claude-ai":
            return "claude"
        case "codex", "codex-cli", "codex-exec":
            return "codex"
        case "gemini", "gemini-cli":
            return "gemini"
        case "cursor", "cursor-agent", "cursor-cli":
            return "cursor"
        case "kilo", "kilocode", "kilo-cli":
            return "kilo"
        case "freebuff", "freebuff-cli":
            return "freebuff"
        case "herdr", "herdr-cli", "herdr-server":
            return "herdr"
        case "opencode", "opencode-cli":
            return "opencode"
        case "grok", "grok-cli":
            return "grok"
        case "pi":
            return "pi"
        case "copilot":
            return "copilot"
        case "qoder", "qoder-cli":
            return "qoder"
        case "kimi":
            return "kimi"
        case "hermes":
            return "hermes"
        default:
            return nil
        }
    }

    /// Fallback classification by inspecting command line arguments when the
    /// process name is generic (node, python, npx, bash). Word-boundary
    /// matching on known agent tokens, and never matches helper/browser
    /// processes (Cursor Helper (GPU), Renderer, Extension Host) so those
    /// don't become phantom agents.
    static func canonicalNameFromCommand(_ command: String) -> String? {
        let lower = command.lowercased()
        // Skip obvious helper/browser subprocesses, extension servers, and daemons first.
        if lower.contains("helper (gpu)")
            || lower.contains("helper (renderer)")
            || lower.contains("helper (plugin)")
            || lower.contains(" serve")
            || lower.contains("serve ")
            || lower.contains("--port")
            || lower.contains("/extensions/")
            || lower.contains("language-server")
            || lower.contains("lsp")
            || lower.contains("daemon")
        {
            return nil
        }
        let tokens: [(String, String)] = [
            ("antigravity", "antigravity"),
            ("antigravity-ide", "antigravity"),
            ("agy", "antigravity"),
            ("kilo", "kilo"),
            ("freebuff", "freebuff"),
            ("herdr", "herdr"),
            ("claude", "claude"),
            ("codex", "codex"),
            ("gemini", "gemini"),
            ("cursor", "cursor"),
            ("opencode", "opencode"),
            ("aider", "aider"),
            ("pi", "pi"),
        ]
        // Lookalike suffixes that are NOT the agent CLI (e.g. claude-searchd,
        // kilo-daemon, herdr-fs-watch) must not match.
        let skipSuffixes = ["search", "daemon", "fs-watch", "fs_watch", "watch", "ctl", "agent-"]
        for (needle, name) in tokens {
            // Word boundary both sides so "kilobytes" / "claude-searchd" /
            // "cursor" inside a path don't match unless it's the agent token.
            let pattern = "(?:^|[^a-z0-9])\(needle)(?:[^a-z0-9]|$)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                regex.firstMatch(
                    in: lower, options: [],
                    range: NSRange(location: 0, length: lower.utf16.count)) != nil
            {
                // Exclude when immediately followed by a known lookalike suffix.
                if let match = regex.firstMatch(
                    in: lower, options: [],
                    range: NSRange(location: 0, length: lower.utf16.count)),
                    let range = Range(match.range, in: lower),
                    range.upperBound < lower.endIndex
                {
                    // Strip leading non-alphanumerics so a lookalike like
                    // "herdr-fs-watch" leaves remainder "fs-watch" (not
                    // "-fs-watch") and still matches the skip suffix.
                    let remainder = String(lower[range.upperBound...]).lowercased()
                    let stripped = remainder.trimmingCharacters(
                        in: CharacterSet.alphanumerics.inverted)
                    if skipSuffixes.contains(where: { stripped.hasPrefix($0) }) {
                        continue
                    }
                }
                return name
            }
        }
        return nil
    }

    /// Whether the process's environment marks it as herdr-managed.
    static func isHerdrManaged(environmentLines: [String]) -> Bool {
        environmentLines.contains { $0.hasPrefix("HERDR_ENV=") || $0.hasPrefix("HERDR_PANE_ID=") }
    }

    /// Latest non-empty activity line from any transcript under `root`.
    /// Returns a trimmed, single-line snippet.
    static func latestActivity(root: String, maxBytes: Int = 4000) -> String? {
        latestActivityInfo(root: root, maxBytes: maxBytes)?.activity
    }

    /// Latest activity line and recency check from any transcript under `root`.
    static func latestActivityInfo(
        root: String, maxBytes: Int = 4000, recentThreshold: TimeInterval = 180
    ) -> (activity: String, isRecent: Bool)? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: []
            )
        else {
            return nil
        }
        var best: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            let path = url.path
            if path.contains("/.git/") || path.contains("/node_modules/")
                || path.contains("/.Trash/")
            {
                enumerator.skipDescendants()
                continue
            }
            let relPath = String(path.dropFirst(root.count))
            let relComponents = relPath.split(separator: "/")
            let hasHiddenSubdir = relComponents.dropLast().contains { comp in
                comp.hasPrefix(".") && comp != ".system_generated"
            }
            if hasHiddenSubdir {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent.lowercased()
            guard
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true,
                ext == "jsonl" || ext == "log" || ext == "json" || ext == "txt"
                    || name.contains("log")
            else {
                continue
            }
            let date = values.contentModificationDate ?? .distantPast
            if best == nil || date > best!.date {
                best = (url, date)
            }
        }
        guard let best else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: best.url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
        let isRecent = Date().timeIntervalSince(best.date) <= recentThreshold
        for line in lines.reversed() {
            if let readable = Self.readableLine(String(line)) {
                return (readable, isRecent)
            }
        }
        return nil
    }

    /// Whether an activity snippet indicates an ongoing, active agent task.
    static func isWorkingActivity(_ activity: String?) -> Bool {
        guard let act = activity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !act.isEmpty
        else { return false }
        if act == "idle" || act.contains("exiting loop") || act.contains("turn.close")
            || act.contains("turn close") || act.contains("session.turn.close")
            || act.hasPrefix("init") || act.contains("message=init") || act.contains("waiting")
            || act.contains("completed") || act.contains("done")
        {
            return false
        }
        return true
    }

    /// Extracts a readable one-line snippet from a transcript line.
    /// Prioritizes concise action summaries over rambling assistant text or long filenames,
    /// cleans paths down to basenames, and strips log envelopes.
    static func readableLine(_ line: String) -> String? {
        let lower = line.lowercased()
        // Skip log warnings, debug, and trace lines entirely - they are internal engine chatter
        if lower.contains("level=warn") || lower.contains("level=debug")
            || lower.contains("level=trace")
            || lower.contains("lvl=warn") || lower.contains("lvl=debug")
            || lower.contains("lvl=trace")
            || lower.contains("duplicate skill name")
        {
            return nil
        }
        if lower.contains("exiting loop") || lower.contains("turn.close")
            || lower.contains("session.turn.close") || lower.contains("message=init ")
            || lower.contains("message=\"init\"")
        {
            return "Idle"
        }

        if let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            // Prioritize concise tool summaries over full filenames or monologue
            if let toolCalls = obj["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                let summaries = toolCalls.compactMap { tc -> String? in
                    let summary =
                        (tc["toolSummary"] as? String)
                        ?? (tc["toolAction"] as? String)
                    if let summary, !summary.isEmpty {
                        return summary
                    }
                    let args =
                        (tc["args"] as? [String: Any])
                        ?? (tc["parameters"] as? [String: Any])
                    if args?["TargetFile"] != nil || args?["AbsolutePath"] != nil {
                        return "Editing file"
                    }
                    return nil
                }
                let joined = summaries.joined(separator: ", ").trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    return IslandMetrics.cleanHUDText(joined, maxCharacters: 40)
                }
            }
            if let message = obj["message"] as? [String: Any] {
                if let content = message["content"] as? [[String: Any]] {
                    let texts = content.compactMap { $0["text"] as? String }
                    let joined = texts.joined(separator: " ").trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !joined.isEmpty {
                        return IslandMetrics.cleanHUDText(joined, maxCharacters: 40)
                    }
                }
                if let contentStr = message["content"] as? String, !contentStr.isEmpty {
                    return IslandMetrics.cleanHUDText(contentStr, maxCharacters: 40)
                }
                if let text = message["text"] as? String, !text.isEmpty {
                    return IslandMetrics.cleanHUDText(text, maxCharacters: 40)
                }
                if let command = message["command"] as? String, !command.isEmpty {
                    return IslandMetrics.cleanHUDText(command, maxCharacters: 40)
                }
            }
            if let contentStr = obj["content"] as? String {
                let trimmed = contentStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return IslandMetrics.cleanHUDText(trimmed, maxCharacters: 40)
                }
            }
            if let thinkingStr = obj["thinking"] as? String {
                let trimmed = thinkingStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let firstLine =
                        trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
                    return IslandMetrics.cleanHUDText(firstLine, maxCharacters: 40)
                }
            }
            if let bash = obj["bashExecution"] as? [String: Any],
                let command = bash["command"] as? String,
                !command.isEmpty
            {
                return IslandMetrics.cleanHUDText(command, maxCharacters: 40)
            }
        }
        let snippet = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.isEmpty { return nil }
        if snippet.hasPrefix("{") {
            return String(snippet.prefix(160))
        }
        return IslandMetrics.cleanHUDText(snippet, maxCharacters: 40)
    }
}

/// Process snapshot used by the standalone scanner (injected for tests).
struct ProcessSample: Equatable, Sendable {
    let pid: Int
    let name: String
    /// Raw command line, e.g. "claude -p fix tests".
    let command: String
    /// Environment lines (KEY=VALUE) if the platform exposes them.
    let environmentLines: [String]
}

/// Scans running processes for agent CLIs and resolves their latest activity.
enum StandaloneAgentScanner {
    /// Classify process samples into detected agents. Skips herdr-managed
    /// processes (they are already surfaced via the herdr adapter) and
    /// processes that are not known agent CLIs.
    static func detect(samples: [ProcessSample], home: String) -> [DetectedAgent] {
        let raw = samples.compactMap { sample -> DetectedAgent? in
            let procLower = sample.name.lowercased()
            let cmdLower = sample.command.lowercased()
            if procLower.contains("helper") || procLower.contains("renderer")
                || procLower.contains("gpu")
                || procLower.contains("plugin") || procLower.contains("crashpad")
                || procLower.contains("utility")
                || cmdLower.contains("helper") || cmdLower.contains("renderer")
                || cmdLower.contains("gpu")
                || cmdLower.contains("plugin") || cmdLower.contains("crashpad")
                || cmdLower.contains("utility")
                || cmdLower.contains(" serve") || cmdLower.contains("serve ")
                || cmdLower.contains("--port")
                || cmdLower.contains("/extensions/") || cmdLower.contains(".vscode/extensions")
                || cmdLower.contains(".antigravity-ide/extensions")
                || cmdLower.contains("language-server") || cmdLower.contains("daemon")
            {
                return nil
            }
            guard
                let name = AgentDetector.canonicalName(forProcess: sample.name)
                    ?? AgentDetector.canonicalNameFromCommand(sample.command)
            else {
                return nil
            }
            guard !AgentDetector.isHerdrManaged(environmentLines: sample.environmentLines) else {
                return nil
            }
            let roots = AgentDetector.transcriptSearchPaths(home: home, name: name)
            var activity: String? = nil
            var isWorking = false
            for root in roots where activity == nil {
                if let info = AgentDetector.latestActivityInfo(root: root) {
                    activity = info.activity
                    isWorking = info.isRecent && AgentDetector.isWorkingActivity(info.activity)
                }
            }
            return DetectedAgent(
                pid: sample.pid,
                name: name,
                activity: activity,
                isWorking: isWorking
            )
        }

        var seenKeys = Set<String>()
        return raw.filter { agent in
            let key = "\(agent.name):\(agent.activity ?? "")"
            guard !seenKeys.contains(key) else { return false }
            seenKeys.insert(key)
            return true
        }
    }

    /// Live process scan via `ps`. Returns process samples for classification.
    /// Reads the pipe concurrently with process exit to avoid the classic
    /// pipe-fill deadlock (waitUntilExit before draining the pipe).
    static func runningProcesses() -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(where: { $0.isWhitespace }),
                let pid = Int(trimmed[..<firstSpace])
            else { return nil }
            let fullCommand = String(trimmed[firstSpace...]).trimmingCharacters(in: .whitespaces)
            let binaryPath =
                fullCommand.split(whereSeparator: \.isWhitespace).first.map(String.init)
                ?? fullCommand
            let procName = URL(fileURLWithPath: binaryPath).lastPathComponent
            return ProcessSample(
                pid: pid,
                name: procName,
                command: fullCommand,
                environmentLines: [])
        }
    }

    /// Live scan: classify everything currently running on the machine.
    static func scan(home: String = NSHomeDirectory()) -> [DetectedAgent] {
        detect(samples: runningProcesses(), home: home)
    }

    /// PERF-2: whether the standalone scan should run now. The `/bin/ps`
    /// spawn + `~/.claude/projects` enumeration is heavy; throttle it to
    /// `minInterval` even though the roster poll runs every few seconds.
    static func shouldRescan(lastScan: Date?, now: Date, minInterval: TimeInterval = 30)
        -> Bool
    {
        guard let lastScan else { return true }
        return now.timeIntervalSince(lastScan) >= minInterval
    }

    /// PERF-2: pure listing of transcript project roots under a base dir.
    /// Empty base → empty result (no I/O).
    static func projectRoots(_ base: String) -> [String] {
        guard !base.isEmpty else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        return entries.map { base + "/" + $0 }
    }

    /// PERF-2: a transcript root's content mtime (or nil when unreadable).
    /// Memoized per root so unchanged trees are skipped on the next poll.
    static func contentModificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date
    }
}
