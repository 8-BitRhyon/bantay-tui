import Foundation

/// A coding-agent CLI process detected on the machine, independent of any
/// multiplexer. Lets Bantay surface agents running in plain terminals.
struct DetectedAgent: Equatable, Sendable {
    let pid: Int
    /// Canonical agent name, e.g. "claude", "codex", "gemini", "cursor".
    let name: String
    /// Latest human-readable activity (tail of the agent's transcript).
    let activity: String?
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
        case "agy", "antigravity":
            return "antigravity"
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
        // Skip obvious helper/browser subprocesses first.
        if lower.contains("helper")
            || lower.contains("renderer")
            || lower.contains("gpu")
            || lower.contains("extension host")
            || lower.contains(".app/contents")
        {
            return nil
        }
        let tokens: [(String, String)] = [
            ("kilo", "kilo"),
            ("freebuff", "freebuff"),
            ("herdr", "herdr"),
            ("claude", "claude"),
            ("codex", "codex"),
            ("gemini", "gemini"),
            ("cursor", "cursor"),
            ("opencode", "opencode"),
            ("aider", "aider"),
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
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        var best: (url: URL, date: Date)?
        for case let url as URL in enumerator {
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
        guard let last = lines.last else { return nil }
        let snippet = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : String(snippet.prefix(160))
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
        samples.compactMap { sample in
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
            for root in roots where activity == nil {
                activity = AgentDetector.latestActivity(root: root)
            }
            return DetectedAgent(pid: sample.pid, name: name, activity: activity)
        }
    }

    /// Live process scan via `ps`. Returns process samples for classification.
    /// Reads the pipe concurrently with process exit to avoid the classic
    /// pipe-fill deadlock (waitUntilExit before draining the pipe).
    static func runningProcesses() -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]
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
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let pid = Int(parts[0]) else { return nil }
            return ProcessSample(
                pid: pid,
                name: String(parts[1]),
                command: String(line),
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
