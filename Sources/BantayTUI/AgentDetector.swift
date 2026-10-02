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
    /// Active working directory if discovered from transcripts/processes.
    let cwd: String?
    /// Root path of the agent's conversation/session directory on disk.
    let sessionPath: String?

    init(
        pid: Int,
        name: String,
        activity: String?,
        isWorking: Bool = false,
        cwd: String? = nil,
        sessionPath: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.activity = activity
        self.isWorking = isWorking
        self.cwd = cwd
        self.sessionPath = sessionPath
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
        case "codex", "codex-cli", "codex-exec":
            return [
                homePath + "/.codex/sessions",
                homePath + "/.codex/transcripts",
                homePath + "/.codex/history",
                homePath + "/.codex",
                homePath + "/.config/codex",
            ]
        case "cloudcode", "cloud-code", "google-cloud-code":
            return [
                homePath + "/.cloudcode",
                homePath + "/.config/cloud-code",
                homePath + "/.google-cloud-code",
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
        case "cursor", "cursor-agent", "cursor-cli":
            return [
                homePath + "/.cursor-agent",
                homePath + "/.cursor",
                homePath + "/Library/Application Support/Cursor/User/workspaceStorage",
                homePath + "/Library/Application Support/Cursor/User/globalStorage",
                homePath + "/Library/Application Support/Cursor/logs",
            ]
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
                // Pi sessions are saved under ~/.pi/agent/sessions.
                homePath + "/.pi/agent/sessions"
            ]
        case "herdr":
            return [
                homePath + "/.config/herdr",
                homePath + "/.local/state/herdr",
            ]
        case "windsurf", "cascade":
            return [
                homePath + "/.codeium/windsurf/memories",
                homePath + "/.codeium/windsurf",
            ]
        case "goose":
            return [
                homePath + "/.local/share/goose/sessions",
                homePath + "/.goose/sessions",
                homePath + "/.config/goose",
            ]
        case "aider":
            return [
                homePath + "/.aider",
                homePath + "/.aider.chat.history.md",
            ]
        case "cline":
            return [
                homePath
                    + "/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks",
                homePath + "/.cline",
            ]
        case "roo-code", "roocode":
            return [
                homePath
                    + "/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks",
                homePath + "/.roo-code",
            ]
        case "openhands":
            return [
                homePath + "/.openhands/conversations",
                homePath + "/.openhands",
            ]
        case "opencode":
            return [
                homePath + "/.opencode",
                homePath + "/.local/share/opencode",
            ]
        case "continue":
            return [
                homePath + "/.continue/sessions",
                homePath + "/.continue",
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
        case "cloudcode", "cloud-code", "google-cloud-code":
            return "cloudcode"
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
        case "windsurf", "windsurf-agent", "cascade", "cascade-cli":
            return "windsurf"
        case "goose", "goose-cli", "goose-agent":
            return "goose"
        case "aider", "aider-chat":
            return "aider"
        case "cline", "cline-cli":
            return "cline"
        case "roo-code", "roo-cline", "roocode":
            return "roo-code"
        case "cody", "cody-agent":
            return "cody"
        case "openhands", "openhands-cli":
            return "openhands"
        case "continue", "continue-cli":
            return "continue"
        default:
            return nil
        }
    }

    /// Classifies agent name from command line arguments.
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
            ("cloudcode", "cloudcode"),
            ("cloud-code", "cloudcode"),
            ("google-cloud-code", "cloudcode"),
            ("gemini", "gemini"),
            ("cursor", "cursor"),
            ("opencode", "opencode"),
            ("aider", "aider"),
            ("pi", "pi"),
            ("windsurf", "windsurf"),
            ("cascade", "windsurf"),
            ("goose", "goose"),
            ("cline", "cline"),
            ("roo-code", "roo-code"),
            ("roocode", "roo-code"),
            ("cody", "cody"),
            ("openhands", "openhands"),
            ("continue", "continue"),
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
    /// Strip enclosing quotes and whitespace from transcript argument strings.
    static func cleanUnquoted(_ text: String?) -> String? {
        guard var str = text?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return nil
        }
        // Normalize escaped quotes first (e.g. \"text\" -> "text")
        if str.contains("\\\"") {
            str = str.replacingOccurrences(of: "\\\"", with: "\"")
        }
        if str.contains("\\'") {
            str = str.replacingOccurrences(of: "\\'", with: "'")
        }
        while (str.hasPrefix("\"") && str.hasSuffix("\"") && str.count >= 2)
            || (str.hasPrefix("'") && str.hasSuffix("'") && str.count >= 2)
            || (str.hasPrefix("`") && str.hasSuffix("`") && str.count >= 2)
        {
            str.removeFirst()
            str.removeLast()
            str = str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return str.isEmpty ? nil : str
    }

    /// Extract active workspace directory from transcript line if present.
    static func extractCwd(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let cwd = cleanUnquoted(obj["cwd"] as? String ?? obj["Cwd"] as? String) {
            return cwd
        }
        if let toolCalls = obj["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                var args = (tc["args"] as? [String: Any]) ?? (tc["parameters"] as? [String: Any])
                if args == nil,
                    let rawArgs = (tc["arguments"] as? String) ?? (tc["args"] as? String),
                    let argsData = rawArgs.data(using: .utf8),
                    let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                {
                    args = parsed
                }
                if let cwd = cleanUnquoted(args?["Cwd"] as? String ?? args?["cwd"] as? String) {
                    return cwd
                }
                if let dir = cleanUnquoted(
                    args?["DirectoryPath"] as? String ?? args?["SearchPath"] as? String)
                {
                    return dir
                }
            }
        }
        if let content = obj["content"] as? String {
            if let match = content.range(of: "Active Document: ") {
                let after = content[match.upperBound...]
                let docPath =
                    after.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                if let cleanDoc = cleanUnquoted(docPath), cleanDoc.hasPrefix("/") {
                    let parent = URL(fileURLWithPath: cleanDoc).deletingLastPathComponent().path
                    if !parent.isEmpty && parent != "/" {
                        return parent
                    }
                }
            }
        }
        return nil
    }

    /// Latest activity line from any transcript under `root`.
    /// Returns a trimmed, single-line snippet.
    static func latestActivity(root: String, maxBytes: Int = 4000) -> String? {
        latestActivityInfo(root: root, maxBytes: maxBytes)?.activity
    }

    /// Structured session snapshot representing an active or recent agent conversation.
    struct ActiveSession: Equatable, Sendable {
        let sessionPath: String
        let activity: String
        let isRecent: Bool
        let isWorking: Bool
        let cwd: String?
        let date: Date
    }

    /// Discovers all active agent sessions under `root` modified recently.
    /// Groups transcripts by their top-level conversation directory (e.g. Antigravity brain UUID,
    /// Claude project hash, or Goose session folder) so multi-window sessions are not collapsed.
    static func activeSessionsInfo(
        root: String, maxBytes: Int = 32768, recentThreshold: TimeInterval = 600
    ) -> [ActiveSession] {
        let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let rootComps = canonicalRoot.pathComponents
        guard
            let enumerator = FileManager.default.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: []
            )
        else {
            return []
        }
        var sessionFiles: [String: (url: URL, date: Date)] = [:]
        for case let url as URL in enumerator {
            let path = url.path
            if path.contains("/.git/") || path.contains("/node_modules/")
                || path.contains("/.Trash/")
            {
                enumerator.skipDescendants()
                continue
            }
            let canonicalFile = url.resolvingSymlinksInPath()
            let fileComps = canonicalFile.pathComponents
            guard fileComps.count > rootComps.count else { continue }
            let relComponents = Array(fileComps[rootComps.count...])
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
            let sessionKey: String
            if relComponents.count > 1, let firstComp = relComponents.first {
                sessionKey = canonicalRoot.appendingPathComponent(firstComp).path
            } else {
                sessionKey = canonicalFile.path
            }

            if let existing = sessionFiles[sessionKey] {
                if date > existing.date {
                    sessionFiles[sessionKey] = (url, date)
                }
            } else {
                sessionFiles[sessionKey] = (url, date)
            }
        }

        guard !sessionFiles.isEmpty else { return [] }
        let now = Date()
        var activeEntries = sessionFiles.filter {
            now.timeIntervalSince($0.value.date) <= recentThreshold
        }
        if activeEntries.isEmpty {
            if let newest = sessionFiles.max(by: { $0.value.date < $1.value.date }) {
                activeEntries = [newest.key: newest.value]
            }
        }

        var results: [ActiveSession] = []
        for (sessionPath, fileInfo) in activeEntries {
            guard let handle = try? FileHandle(forReadingFrom: fileInfo.url) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            try? handle.seek(toOffset: start)
            let data = handle.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline)
            let isRecent = now.timeIntervalSince(fileInfo.date) <= recentThreshold
            var foundActivity: String? = nil
            var fallbackActivity: String? = nil
            var foundCwd: String? = nil
            for line in lines.reversed() {
                let lineStr = String(line)
                if foundCwd == nil {
                    foundCwd = Self.extractCwd(lineStr)
                }
                if let readable = Self.readableLine(lineStr) {
                    if !readable.hasPrefix("{") {
                        if foundActivity == nil {
                            foundActivity = readable
                        }
                    } else if fallbackActivity == nil {
                        fallbackActivity = readable
                    }
                }
                if foundActivity != nil && foundCwd != nil {
                    break
                }
            }
            guard let activity = foundActivity ?? fallbackActivity else { continue }
            results.append(
                ActiveSession(
                    sessionPath: sessionPath,
                    activity: activity,
                    isRecent: isRecent,
                    isWorking: isRecent && Self.isWorkingActivity(activity),
                    cwd: foundCwd,
                    date: fileInfo.date
                )
            )
        }
        return results.sorted(by: { $0.date > $1.date })
    }

    /// Latest activity line, recency check, and detected cwd from any transcript under `root`.
    static func latestActivityInfo(
        root: String, maxBytes: Int = 4000, recentThreshold: TimeInterval = 180
    ) -> (activity: String, isRecent: Bool, cwd: String?)? {
        if let session = activeSessionsInfo(
            root: root, maxBytes: maxBytes, recentThreshold: recentThreshold
        ).first {
            return (session.activity, session.isRecent, session.cwd)
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

    /// Translates raw terminal commands into clean, human-readable action phrases.
    static func summarizeCommand(_ rawCmd: String) -> String {
        let trimmed = rawCmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Running command" }
        let firstWord =
            trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        let basename = URL(fileURLWithPath: firstWord).lastPathComponent
        if !basename.isEmpty && !IslandMetrics.isSuppressedGarbage(basename) {
            return "Running \(basename)"
        }
        return "Running command"
    }

    /// Summarizes a tool call into a concise, human-readable action phrase.
    static func summarizeToolCall(
        name: String, args: [String: Any]?, tc: [String: Any]? = nil
    ) -> String? {
        let rawSummary =
            (tc?["toolSummary"] as? String)
            ?? (args?["toolSummary"] as? String)
            ?? (tc?["toolAction"] as? String)
            ?? (args?["toolAction"] as? String)
            ?? (args?["summary"] as? String)
            ?? (args?["action"] as? String)
        if let cleanSummary = cleanUnquoted(rawSummary),
            !cleanSummary.isEmpty,
            !IslandMetrics.isSuppressedGarbage(cleanSummary)
        {
            return cleanSummary
        }

        let lowerName = name.lowercased()
        switch lowerName {
        case "run_command", "bash", "execute_command", "exec", "terminal":
            if let cmd = cleanUnquoted(
                args?["CommandLine"] as? String ?? args?["command"] as? String
                    ?? args?["cmd"] as? String)
            {
                return summarizeCommand(cmd)
            }
            return "Running command"
        case "view_file", "read_file", "read", "open":
            if let path = cleanUnquoted(
                args?["AbsolutePath"] as? String ?? args?["TargetFile"] as? String
                    ?? args?["path"] as? String ?? args?["file_path"] as? String)
            {
                let fname = URL(fileURLWithPath: path).lastPathComponent
                return "Viewing \(fname)"
            }
            return "Viewing file"
        case "replace_file_content", "multi_replace_file_content", "write_to_file",
            "edit_file", "edit", "strreplaceedit":
            if let path = cleanUnquoted(
                args?["TargetFile"] as? String ?? args?["AbsolutePath"] as? String
                    ?? args?["path"] as? String ?? args?["file_path"] as? String)
            {
                let fname = URL(fileURLWithPath: path).lastPathComponent
                return "Editing \(fname)"
            }
            return "Editing file"
        case "grep_search", "search_web", "file_search", "glob":
            if let query = cleanUnquoted(
                args?["Query"] as? String ?? args?["query"] as? String
                    ?? args?["pattern"] as? String)
            {
                return "Searching: \(query)"
            }
            return "Searching code"
        case "list_dir", "list_directory", "ls":
            return "Listing directory"
        case "ask_question", "askquestion", "question":
            return "Waiting for input"
        default:
            let humanized = name.replacingOccurrences(of: "_", with: " ").capitalized
            return humanized
        }
    }

    /// Extracts a readable one-line snippet from a transcript line.
    /// Prioritizes concise action summaries over rambling assistant text or long filenames,
    /// cleans paths down to basenames, and strips log envelopes.
    static func readableLine(_ line: String) -> String? {
        let lower = line.lowercased()
        // Skip log warnings, debug, trace lines, and daemon chatter entirely
        if lower.contains("level=warn") || lower.contains("level=debug")
            || lower.contains("level=trace")
            || lower.contains("lvl=warn") || lower.contains("lvl=debug")
            || lower.contains("lvl=trace")
            || lower.contains("duplicate skill name")
            || lower.contains("service=marketplace")
            || lower.contains("cleanup prune=")
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
            // 1. Tool calls (Antigravity / OpenAI schema)
            if let toolCalls = obj["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                let summaries = toolCalls.compactMap { tc -> String? in
                    var args =
                        (tc["args"] as? [String: Any]) ?? (tc["parameters"] as? [String: Any])
                    if args == nil,
                        let rawArgs = (tc["arguments"] as? String) ?? (tc["args"] as? String),
                        let argsData = rawArgs.data(using: .utf8),
                        let parsed = try? JSONSerialization.jsonObject(with: argsData)
                            as? [String: Any]
                    {
                        args = parsed
                    }
                    let name = tc["name"] as? String ?? "tool"
                    return summarizeToolCall(name: name, args: args, tc: tc)
                }
                let joined = summaries.joined(separator: ", ").trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    let cleaned = IslandMetrics.cleanHUDText(joined, maxCharacters: 40)
                    if !cleaned.isEmpty { return cleaned }
                }
            }

            // 2. Claude Code tool_use (e.g. {"type": "tool_use", "name": "Bash", "input": {...}})
            let objType = obj["type"] as? String ?? ""
            if objType == "tool_use", let toolName = obj["name"] as? String {
                let inputArgs = obj["input"] as? [String: Any]
                if let summary = summarizeToolCall(name: toolName, args: inputArgs) {
                    let cleaned = IslandMetrics.cleanHUDText(summary, maxCharacters: 40)
                    if !cleaned.isEmpty { return cleaned }
                }
            }

            // 3. Goose / Custom event action (e.g. {"action": {"tool": "edit", ...}})
            if let action = obj["action"] as? [String: Any],
                let toolName = action["tool"] as? String ?? action["name"] as? String
            {
                let args = action["args"] as? [String: Any]
                if let summary = summarizeToolCall(name: toolName, args: args) {
                    let cleaned = IslandMetrics.cleanHUDText(summary, maxCharacters: 40)
                    if !cleaned.isEmpty { return cleaned }
                }
            }

            // 4. Message content / command
            if let message = obj["message"] as? [String: Any] {
                if let content = message["content"] as? [[String: Any]] {
                    let texts = content.compactMap { cleanUnquoted($0["text"] as? String) }
                    let joined = texts.joined(separator: " ").trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !joined.isEmpty {
                        let cleaned = IslandMetrics.cleanHUDText(joined, maxCharacters: 40)
                        if !cleaned.isEmpty { return cleaned }
                    }
                }
                if let contentStr = cleanUnquoted(message["content"] as? String),
                    !contentStr.isEmpty
                {
                    let cleaned = IslandMetrics.cleanHUDText(contentStr, maxCharacters: 40)
                    if !cleaned.isEmpty { return cleaned }
                }
                if let text = cleanUnquoted(message["text"] as? String), !text.isEmpty {
                    let cleaned = IslandMetrics.cleanHUDText(text, maxCharacters: 40)
                    if !cleaned.isEmpty { return cleaned }
                }
                if let command = cleanUnquoted(message["command"] as? String), !command.isEmpty {
                    let cleaned = IslandMetrics.cleanHUDText(command, maxCharacters: 40)
                    if !cleaned.isEmpty { return cleaned }
                }
            }

            // 5. Internal protocol checkpoints and noise to skip entirely
            let objSource = obj["source"] as? String ?? ""
            if objType == "CHECKPOINT" || objType == "EPHEMERAL_MESSAGE" || objType == "TASK_STATE"
                || objSource == "SYSTEM" || objSource == "SYSTEM_MESSAGE"
                || objType == "VIEW_FILE" || objType == "RUN_COMMAND" || objType == "LIST_DIR"
                || objType == "LIST_DIRECTORY" || objType == "GREP_SEARCH"
                || objType == "SEARCH_WEB" || objType == "CODE_ACTION"
                || objType == "CONVERSATION_HISTORY" || objType == "KNOWLEDGE_ARTIFACTS"
                || objType == "ERROR_MESSAGE" || objType == "SYSTEM_MESSAGE"
                || objType == "STATUS_UPDATE"
            {
                return nil
            }

            // 6. User prompt
            if objType == "USER_INPUT" || objSource == "USER" || objSource == "USER_EXPLICIT" {
                if let content = cleanUnquoted(obj["content"] as? String), !content.isEmpty {
                    let cleaned = IslandMetrics.cleanHUDText(content, maxCharacters: 40)
                    if !cleaned.isEmpty { return cleaned }
                }
            }

            // 7. Direct assistant content
            if let contentStr = obj["content"] as? String {
                let trimmed = contentStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("Created At:") || trimmed.hasPrefix("File Path:")
                    || IslandMetrics.isSuppressedGarbage(trimmed)
                {
                    return nil
                }
                if !trimmed.isEmpty && !trimmed.hasPrefix("{") {
                    let firstLine =
                        trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
                    let clean =
                        firstLine
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#*` \t\r\n"))
                        .replacingOccurrences(of: "**", with: "")
                        .replacingOccurrences(of: "`", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        let cleaned = IslandMetrics.cleanHUDText(clean, maxCharacters: 40)
                        if !cleaned.isEmpty { return cleaned }
                    }
                }
            }

            // 8. Thinking / reasoning monologue
            if let thinkingStr = obj["thinking"] as? String {
                let trimmed = thinkingStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if IslandMetrics.isSuppressedGarbage(trimmed) {
                    return nil
                }
                if !trimmed.isEmpty && !trimmed.hasPrefix("{") {
                    let firstLine =
                        trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
                    let clean =
                        firstLine
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#*` \t\r\n"))
                        .replacingOccurrences(of: "**", with: "")
                        .replacingOccurrences(of: "`", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        let cleaned = IslandMetrics.cleanHUDText(clean, maxCharacters: 40)
                        if !cleaned.isEmpty { return cleaned }
                    }
                }
            }

            // 9. Bash execution
            if let bash = obj["bashExecution"] as? [String: Any],
                let command = cleanUnquoted(bash["command"] as? String),
                !command.isEmpty
            {
                let summary = summarizeCommand(command)
                let cleaned = IslandMetrics.cleanHUDText(summary, maxCharacters: 40)
                if !cleaned.isEmpty { return cleaned }
            }
        }

        // Plain text fallback: strip control codes and suppress garbage
        let snippet = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.isEmpty { return nil }
        if snippet.hasPrefix("{") {
            return String(snippet.prefix(160))
        }
        return IslandMetrics.cleanHUDText(snippet, maxCharacters: 40)
    }

    /// Read and format the latest transcript/log lines for an agent, feeding the Peek overlay.
    static func recentTranscriptOutput(
        forAgent name: String,
        sessionPath: String? = nil,
        cwd: String? = nil,
        maxLines: Int = 100,
        home: String = NSHomeDirectory()
    ) -> [String] {
        var best: (url: URL, date: Date)?
        let searchRoots: [String] = {
            if let sessionPath, !sessionPath.isEmpty {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: sessionPath, isDirectory: &isDir) {
                    return [sessionPath]
                }
            }
            return transcriptSearchPaths(home: home, name: name)
        }()
        guard !searchRoots.isEmpty else { return [] }

        for root in searchRoots {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root, isDirectory: &isDir), !isDir.boolValue {
                let url = URL(fileURLWithPath: root)
                let date =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if best == nil || date > best!.date {
                    best = (url, date)
                }
                continue
            }
            guard
                let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: []
                )
            else { continue }

            for case let url as URL in enumerator {
                let path = url.path
                if path.contains("/.git/") || path.contains("/node_modules/")
                    || path.contains("/.Trash/")
                {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let fileName = url.lastPathComponent.lowercased()
                guard
                    let values = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                    values.isRegularFile == true,
                    ext == "jsonl" || ext == "log" || ext == "json" || ext == "txt"
                        || fileName.contains("log")
                else { continue }
                let date = values.contentModificationDate ?? .distantPast
                if best == nil || date > best!.date {
                    best = (url, date)
                }
            }
        }

        guard let bestFile = best else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: bestFile.url) else { return [] }
        defer { try? handle.close() }

        let maxBytes: UInt64 = 131072
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > maxBytes ? end - maxBytes : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return [] }

        let rawLines = text.split(whereSeparator: \.isNewline)
        var formatted: [String] = []

        for line in rawLines {
            let lineStr = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineStr.isEmpty else { continue }

            if lineStr.hasPrefix("{"),
                let lineData = lineStr.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            {
                let type = obj["type"] as? String ?? ""
                let source = obj["source"] as? String ?? ""

                // Skip internal protocol checkpoints and tool outputs
                if type == "EPHEMERAL_MESSAGE" || type == "CHECKPOINT" || type == "TASK_STATE"
                    || type == "VIEW_FILE" || type == "RUN_COMMAND" || type == "LIST_DIR"
                    || type == "LIST_DIRECTORY" || type == "GREP_SEARCH"
                    || type == "SEARCH_WEB" || type == "CODE_ACTION"
                    || type == "CONVERSATION_HISTORY" || type == "KNOWLEDGE_ARTIFACTS"
                    || type == "ERROR_MESSAGE" || type == "SYSTEM_MESSAGE"
                    || type == "STATUS_UPDATE" || source == "SYSTEM"
                {
                    continue
                }

                // User prompt
                if type == "USER_INPUT" || source == "USER" || source == "USER_EXPLICIT" {
                    if let content = cleanUnquoted(obj["content"] as? String) {
                        formatted.append("❯ User: \(content.prefix(120))")
                    }
                    continue
                }

                // Tool calls (Antigravity / OpenAI schema)
                if let toolCalls = obj["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    for tc in toolCalls {
                        let name = tc["name"] as? String ?? "tool"
                        var args =
                            (tc["args"] as? [String: Any]) ?? (tc["parameters"] as? [String: Any])
                        if args == nil,
                            let rawArgs = (tc["arguments"] as? String) ?? (tc["args"] as? String),
                            let argsData = rawArgs.data(using: .utf8),
                            let parsed = try? JSONSerialization.jsonObject(with: argsData)
                                as? [String: Any]
                        {
                            args = parsed
                        }
                        if let summary = summarizeToolCall(name: name, args: args) {
                            formatted.append("→ \(summary)")
                        }
                    }
                    continue
                }

                // Claude Code tool_use
                if type == "tool_use", let toolName = obj["name"] as? String {
                    let inputArgs = obj["input"] as? [String: Any]
                    if let summary = summarizeToolCall(name: toolName, args: inputArgs) {
                        formatted.append("→ \(summary)")
                    }
                    continue
                }

                // Assistant monologue / content
                if let content = obj["content"] as? String {
                    let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty && !cleaned.hasPrefix("{")
                        && !cleaned.hasPrefix("Created At:") && !cleaned.hasPrefix("File Path:")
                    {
                        let first =
                            cleaned.split(whereSeparator: \.isNewline).first.map(String.init)
                            ?? cleaned
                        let clean = first.replacingOccurrences(of: "**", with: "")
                            .replacingOccurrences(of: "#", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty {
                            formatted.append("● \(clean.prefix(120))")
                        }
                    }
                    continue
                }

                if let message = obj["message"] as? [String: Any] {
                    if let content = message["content"] as? [[String: Any]] {
                        let texts = content.compactMap { cleanUnquoted($0["text"] as? String) }
                        let joined = texts.joined(separator: " ").trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        if !joined.isEmpty {
                            formatted.append("● \(joined.prefix(120))")
                        }
                    } else if let contentStr = cleanUnquoted(message["content"] as? String),
                        !contentStr.isEmpty
                    {
                        formatted.append("● \(contentStr.prefix(120))")
                    } else if let text = cleanUnquoted(message["text"] as? String), !text.isEmpty {
                        formatted.append("● \(text.prefix(120))")
                    }
                    continue
                }

                // Thinking
                if let thinking = obj["thinking"] as? String {
                    let cleaned = thinking.replacingOccurrences(of: "**", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        let first =
                            cleaned.split(whereSeparator: \.isNewline).first.map(String.init)
                            ?? cleaned
                        formatted.append("💭 \(first.prefix(120))")
                    }
                    continue
                }
            } else {
                let cleaned = LogFormatter.cleanAnsi(lineStr)
                if !cleaned.isEmpty && !cleaned.hasPrefix("{") {
                    formatted.append(String(cleaned.prefix(160)))
                }
            }
        }

        return Array(formatted.suffix(maxLines))
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
        var raw: [DetectedAgent] = []
        for sample in samples {
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
                continue
            }
            guard
                let name = AgentDetector.canonicalName(forProcess: sample.name)
                    ?? AgentDetector.canonicalNameFromCommand(sample.command)
            else {
                continue
            }
            guard !AgentDetector.isHerdrManaged(environmentLines: sample.environmentLines) else {
                continue
            }
            let roots = AgentDetector.transcriptSearchPaths(home: home, name: name)
            var sessions: [AgentDetector.ActiveSession] = []
            for root in roots {
                let found = AgentDetector.activeSessionsInfo(root: root)
                if !found.isEmpty {
                    sessions.append(contentsOf: found)
                }
            }
            sessions.sort(by: { $0.date > $1.date })
            if !sessions.isEmpty {
                for session in sessions {
                    raw.append(
                        DetectedAgent(
                            pid: sample.pid,
                            name: name,
                            activity: session.activity,
                            isWorking: session.isWorking,
                            cwd: session.cwd,
                            sessionPath: session.sessionPath
                        )
                    )
                }
            } else {
                raw.append(
                    DetectedAgent(
                        pid: sample.pid,
                        name: name,
                        activity: nil,
                        isWorking: false,
                        cwd: nil,
                        sessionPath: nil
                    )
                )
            }
        }

        var seenKeys = Set<String>()
        return raw.filter { agent in
            let key = "\(agent.name):\(agent.cwd ?? "default")"
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
