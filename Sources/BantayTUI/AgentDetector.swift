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
            // ~/.claude/projects/<encoded-path>/<session-id>.jsonl
            return [homePath + "/.claude/projects"]
        case "codex":
            // ~/.codex/sessions/<session-id>/rollout.jsonl
            return [homePath + "/.codex/sessions"]
        case "gemini", "gemini-cli":
            // ~/.gemini/sessions/<session-id>.jsonl
            return [homePath + "/.gemini/sessions"]
        case "cursor", "cursor-agent":
            return [homePath + "/.cursor-agent"]
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
            guard
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true,
                url.pathExtension == "jsonl" || url.lastPathComponent == "rollout.jsonl"
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
            guard let name = AgentDetector.canonicalName(forProcess: sample.name) else {
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
}
