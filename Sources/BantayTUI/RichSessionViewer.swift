import AppKit
import Foundation

/// Generates a rich, interactive HTML dashboard for an agent session and opens it
/// in the user's default browser (e.g. Chrome, Dia, Safari).
public enum RichSessionViewer {
    /// Represents a parsed turn in the agent's transcript.
    public struct Turn: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case userPrompt
            case toolCall
            case thought
            case assistant
            case raw
        }

        public let kind: Kind
        public let title: String
        public let detail: String?
        public let timestamp: String?
        public let toolName: String?
        public let commandOrArgs: String?

        public init(
            kind: Kind,
            title: String,
            detail: String? = nil,
            timestamp: String? = nil,
            toolName: String? = nil,
            commandOrArgs: String? = nil
        ) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.timestamp = timestamp
            self.toolName = toolName
            self.commandOrArgs = commandOrArgs
        }
    }

    /// Snapshot of git changes in the workspace.
    public struct GitContext: Equatable, Sendable {
        public let status: String?
        public let diffStat: String?
        public let unifiedDiff: String?
        public let branch: String?

        public init(
            status: String? = nil,
            diffStat: String? = nil,
            unifiedDiff: String? = nil,
            branch: String? = nil
        ) {
            self.status = status
            self.diffStat = diffStat
            self.unifiedDiff = unifiedDiff
            self.branch = branch
        }
    }

    /// Parse raw transcript / log lines into structured timeline turns.
    public static func parseTranscript(lines: [String]) -> [Turn] {
        var turns: [Turn] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("{"),
                let data = trimmed.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                let type = obj["type"] as? String ?? ""
                let source = obj["source"] as? String ?? ""
                let time = obj["created_at"] as? String

                if type == "EPHEMERAL_MESSAGE" || type == "CHECKPOINT" || type == "TASK_STATE" {
                    continue
                }

                if type == "USER_INPUT" || source == "USER" || source == "USER_EXPLICIT" {
                    let content =
                        AgentDetector.cleanUnquoted(obj["content"] as? String)
                        ?? "User Prompt"
                    turns.append(
                        Turn(
                            kind: .userPrompt,
                            title: "User Prompt",
                            detail: content,
                            timestamp: time
                        )
                    )
                    continue
                }

                if let toolCalls = obj["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    for tc in toolCalls {
                        let name = tc["name"] as? String ?? "tool"
                        var args =
                            (tc["args"] as? [String: Any]) ?? (tc["parameters"] as? [String: Any])
                        if args == nil,
                            let rawArgs = (tc["arguments"] as? String) ?? (tc["args"] as? String),
                            let argsData = rawArgs.data(using: .utf8),
                            let parsed =
                                try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            args = parsed
                        }
                        let summary =
                            AgentDetector.cleanUnquoted(
                                (tc["toolSummary"] as? String)
                                    ?? (args?["toolSummary"] as? String)
                                    ?? (tc["toolAction"] as? String)
                                    ?? (args?["toolAction"] as? String)
                            ) ?? name.replacingOccurrences(of: "_", with: " ").capitalized

                        var argDetail: String? = nil
                        if let cmd = AgentDetector.cleanUnquoted(
                            args?["CommandLine"] as? String ?? args?["command"] as? String)
                        {
                            argDetail = cmd
                        } else if let path = AgentDetector.cleanUnquoted(
                            args?["TargetFile"] as? String ?? args?["AbsolutePath"] as? String
                                ?? args?["path"] as? String ?? args?["DirectoryPath"] as? String)
                        {
                            argDetail = path
                        } else if let query = AgentDetector.cleanUnquoted(
                            args?["Query"] as? String ?? args?["query"] as? String)
                        {
                            argDetail = query
                        }

                        turns.append(
                            Turn(
                                kind: .toolCall,
                                title: summary,
                                detail: nil,
                                timestamp: time,
                                toolName: name,
                                commandOrArgs: argDetail
                            )
                        )
                    }
                    continue
                }

                if let thinking = obj["thinking"] as? String {
                    let clean = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        turns.append(
                            Turn(
                                kind: .thought,
                                title: "Thinking Process",
                                detail: clean,
                                timestamp: time
                            )
                        )
                    }
                    continue
                }

                if let content = obj["content"] as? String {
                    let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty && !clean.hasPrefix("{")
                        && !clean.hasPrefix("Created At:") && !clean.hasPrefix("File Path:")
                    {
                        turns.append(
                            Turn(
                                kind: .assistant,
                                title: "Agent Response",
                                detail: clean,
                                timestamp: time
                            )
                        )
                    }
                    continue
                }
            } else {
                let clean = LogFormatter.cleanAnsi(trimmed)
                if !clean.isEmpty {
                    turns.append(Turn(kind: .raw, title: clean))
                }
            }
        }
        return turns
    }

    /// Capture git context (status, diff stat, and unified diff) synchronously or off-actor.
    public static func captureGitContext(cwd: String?) -> GitContext {
        guard let cwd, !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else {
            return GitContext()
        }
        let gitPath = "/usr/bin/git"

        func runGit(_ args: [String]) -> String? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: gitPath)
            proc.arguments = ["-C", cwd] + args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else { return nil }
                return String(data: data, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines)
            } catch {
                return nil
            }
        }

        let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"])
        let status = runGit(["status", "--short"])
        let stat = runGit(["diff", "--stat"])
        let diff = runGit(["diff", "-U2"])
        return GitContext(
            status: status,
            diffStat: stat,
            unifiedDiff: diff,
            branch: branch
        )
    }

    /// Escape string for embedding safely inside HTML attributes and text nodes.
    public static func escapeHtml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Generates the self-contained HTML inspection page.
    public static func generateHtml(
        agentName: String,
        projectSlug: String,
        cwd: String?,
        isWorking: Bool,
        turns: [Turn],
        git: GitContext
    ) -> String {
        let safeName = escapeHtml(agentName.capitalized)
        let safeSlug = escapeHtml(projectSlug)
        let safeCwd = escapeHtml(cwd ?? "Standalone session")
        let safeBranch = escapeHtml(git.branch ?? "main")
        let statusBadge =
            isWorking
            ? "<span class=\"badge working\">● Working</span>"
            : "<span class=\"badge idle\">○ Idle</span>"

        var diffSection = ""
        if let stat = git.diffStat, !stat.isEmpty {
            diffSection += """
                <div class="card diff-card">
                  <div class="card-header">
                    <span class="card-title">Diff Statistics</span>
                    <span class="subtext">git diff --stat</span>
                  </div>
                  <pre class="stat-block">\(escapeHtml(stat))</pre>
                </div>
                """
        }

        if let diff = git.unifiedDiff, !diff.isEmpty {
            let highlighted = diff.split(whereSeparator: \.isNewline).map { rawLine -> String in
                let line = String(rawLine)
                let escaped = escapeHtml(line)
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    return "<span class=\"diff-add\">\(escaped)</span>"
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    return "<span class=\"diff-del\">\(escaped)</span>"
                } else if line.hasPrefix("@@") {
                    return "<span class=\"diff-hunk\">\(escaped)</span>"
                }
                return escaped
            }.joined(separator: "\n")

            diffSection += """
                <div class="card diff-card">
                  <div class="card-header">
                    <span class="card-title">Working Tree Changes</span>
                    <button class="btn copy-btn" onclick="copyDiff()">Copy Patch</button>
                  </div>
                  <pre class="diff-block" id="diffContent">\(highlighted)</pre>
                </div>
                """
        } else {
            diffSection += """
                <div class="card empty-card">
                  <span class="subtext">Working tree clean — no uncommitted changes.</span>
                </div>
                """
        }

        var timelineHtml = ""
        if turns.isEmpty {
            timelineHtml = "<div class=\"card empty-card\">No transcript turns recorded yet.</div>"
        } else {
            for turn in turns.reversed() {
                let kindClass = turn.kind.rawValue
                let title = escapeHtml(turn.title)
                let time = escapeHtml(turn.timestamp ?? "")
                let detail = turn.detail != nil ? escapeHtml(turn.detail!) : ""
                let args = turn.commandOrArgs != nil ? escapeHtml(turn.commandOrArgs!) : ""

                timelineHtml += """
                    <div class="turn-card \(kindClass)" data-kind="\(kindClass)">
                      <div class="turn-top">
                        <span class="turn-badge \(kindClass)">\(turn.kind.rawValue.uppercased())</span>
                        <span class="turn-title">\(title)</span>
                        <span class="turn-time">\(time)</span>
                      </div>
                    """
                if !args.isEmpty {
                    timelineHtml += """
                        <div class="turn-args"><code>\(args)</code></div>
                        """
                }
                if !detail.isEmpty {
                    timelineHtml += """
                        <div class="turn-body"><pre>\(detail)</pre></div>
                        """
                }
                timelineHtml += "</div>\n"
            }
        }

        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="UTF-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
              <title>\(safeName) · \(safeSlug) — Bantay Session</title>
              <style>
                :root {
                  --bg: #0b0d14;
                  --card: #131622;
                  --card-hover: #1a1e30;
                  --border: rgba(255, 255, 255, 0.08);
                  --border-focus: rgba(56, 189, 248, 0.4);
                  --text: #f1f5f9;
                  --text-muted: #94a3b8;
                  --cyan: #38bdf8;
                  --emerald: #34d399;
                  --rose: #f43f5e;
                  --purple: #a855f7;
                  --amber: #fbbf24;
                  --mono: "SF Mono", Monaco, Menlo, Consolas, monospace;
                  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                }
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                  background: var(--bg);
                  color: var(--text);
                  font-family: var(--sans);
                  line-height: 1.5;
                  padding: 24px;
                }
                header {
                  display: flex;
                  justify-content: space-between;
                  align-items: center;
                  padding-bottom: 20px;
                  border-bottom: 1px solid var(--border);
                  margin-bottom: 24px;
                }
                .brand-title {
                  display: flex;
                  align-items: center;
                  gap: 12px;
                }
                h1 { font-size: 20px; font-weight: 700; color: #fff; letter-spacing: -0.5px; }
                .subtitle { font-size: 12px; color: var(--text-muted); font-family: var(--mono); }
                .badge {
                  font-size: 11px;
                  font-weight: 600;
                  padding: 3px 8px;
                  border-radius: 9999px;
                  text-transform: uppercase;
                  letter-spacing: 0.5px;
                }
                .badge.working { background: rgba(52, 211, 153, 0.15); color: var(--emerald); border: 1px solid rgba(52, 211, 153, 0.3); }
                .badge.idle { background: rgba(148, 163, 184, 0.15); color: var(--text-muted); border: 1px solid var(--border); }
                .toolbar {
                  display: flex;
                  gap: 12px;
                  align-items: center;
                  margin-bottom: 20px;
                  flex-wrap: wrap;
                }
                .filter-group {
                  display: flex;
                  background: var(--card);
                  border: 1px solid var(--border);
                  border-radius: 8px;
                  overflow: hidden;
                }
                .filter-btn {
                  background: transparent;
                  border: none;
                  color: var(--text-muted);
                  padding: 6px 12px;
                  font-size: 12px;
                  font-weight: 500;
                  cursor: pointer;
                  transition: all 0.15s;
                }
                .filter-btn:hover { color: #fff; background: rgba(255, 255, 255, 0.04); }
                .filter-btn.active { color: #fff; background: rgba(56, 189, 248, 0.18); font-weight: 600; }
                .search-box {
                  flex: 1;
                  max-width: 320px;
                  background: var(--card);
                  border: 1px solid var(--border);
                  color: #fff;
                  font-size: 12px;
                  padding: 6px 12px;
                  border-radius: 8px;
                  outline: none;
                  font-family: var(--mono);
                }
                .search-box:focus { border-color: var(--cyan); }
                .grid {
                  display: grid;
                  grid-template-columns: 1fr 1fr;
                  gap: 24px;
                }
                @media (max-width: 1000px) {
                  .grid { grid-template-columns: 1fr; }
                }
                .section-header {
                  font-size: 13px;
                  font-weight: 600;
                  color: var(--text-muted);
                  text-transform: uppercase;
                  letter-spacing: 0.8px;
                  margin-bottom: 12px;
                  display: flex;
                  justify-content: space-between;
                }
                .card {
                  background: var(--card);
                  border: 1px solid var(--border);
                  border-radius: 10px;
                  padding: 14px;
                  margin-bottom: 12px;
                }
                .card-header {
                  display: flex;
                  justify-content: space-between;
                  align-items: center;
                  margin-bottom: 8px;
                }
                .card-title { font-size: 12px; font-weight: 600; color: #fff; }
                .subtext { font-size: 11px; color: var(--text-muted); font-family: var(--mono); }
                .stat-block, .diff-block {
                  font-family: var(--mono);
                  font-size: 11.5px;
                  overflow-x: auto;
                  white-space: pre;
                  padding: 8px;
                  border-radius: 6px;
                  background: rgba(0, 0, 0, 0.3);
                }
                .diff-add { color: var(--emerald); }
                .diff-del { color: var(--rose); }
                .diff-hunk { color: var(--cyan); opacity: 0.8; }
                .turn-card {
                  background: var(--card);
                  border: 1px solid var(--border);
                  border-radius: 10px;
                  padding: 12px 14px;
                  margin-bottom: 10px;
                  transition: transform 0.1s ease;
                }
                .turn-card:hover { border-color: rgba(255, 255, 255, 0.15); }
                .turn-card.userPrompt { border-left: 3px solid var(--purple); }
                .turn-card.toolCall { border-left: 3px solid var(--cyan); }
                .turn-card.thought { border-left: 3px solid var(--amber); }
                .turn-card.assistant { border-left: 3px solid var(--emerald); }
                .turn-top {
                  display: flex;
                  align-items: center;
                  gap: 8px;
                  margin-bottom: 6px;
                }
                .turn-badge {
                  font-size: 9px;
                  font-weight: 700;
                  padding: 2px 6px;
                  border-radius: 4px;
                  font-family: var(--mono);
                }
                .turn-badge.userPrompt { background: rgba(168, 85, 247, 0.2); color: var(--purple); }
                .turn-badge.toolCall { background: rgba(56, 189, 248, 0.2); color: var(--cyan); }
                .turn-badge.thought { background: rgba(251, 191, 36, 0.2); color: var(--amber); }
                .turn-badge.assistant { background: rgba(52, 211, 153, 0.2); color: var(--emerald); }
                .turn-title { font-size: 12px; font-weight: 600; color: #fff; }
                .turn-time { font-size: 10px; color: var(--text-muted); margin-left: auto; font-family: var(--mono); }
                .turn-args code {
                  font-family: var(--mono);
                  font-size: 11px;
                  color: var(--cyan);
                  background: rgba(56, 189, 248, 0.08);
                  padding: 2px 6px;
                  border-radius: 4px;
                  display: block;
                  margin-top: 4px;
                  word-break: break-all;
                }
                .turn-body pre {
                  font-family: var(--mono);
                  font-size: 11px;
                  color: #cbd5e1;
                  margin-top: 6px;
                  white-space: pre-wrap;
                  word-break: break-word;
                  max-height: 240px;
                  overflow-y: auto;
                  padding: 6px;
                  background: rgba(0, 0, 0, 0.2);
                  border-radius: 4px;
                }
                .btn {
                  background: rgba(255, 255, 255, 0.08);
                  border: 1px solid var(--border);
                  color: #fff;
                  font-size: 11px;
                  font-weight: 500;
                  padding: 4px 10px;
                  border-radius: 6px;
                  cursor: pointer;
                }
                .btn:hover { background: rgba(255, 255, 255, 0.16); }
              </style>
            </head>
            <body>
              <header>
                <div class="brand-title">
                  <h1>\(safeName) · \(safeSlug)</h1>
                  \(statusBadge)
                  <span class="subtitle">branch: \(safeBranch)</span>
                </div>
                <div class="subtitle">\(safeCwd)</div>
              </header>

              <div class="toolbar">
                <div class="filter-group">
                  <button class="filter-btn active" onclick="setFilter('all')">All Events</button>
                  <button class="filter-btn" onclick="setFilter('userPrompt')">Prompts</button>
                  <button class="filter-btn" onclick="setFilter('toolCall')">Tools</button>
                  <button class="filter-btn" onclick="setFilter('thought')">Thinking</button>
                  <button class="filter-btn" onclick="setFilter('assistant')">Responses</button>
                </div>
                <input type="text" class="search-box" id="searchBox" placeholder="Search transcript…" oninput="filterTurns()">
                <button class="btn" onclick="window.location.reload()">Refresh</button>
              </div>

              <div class="grid">
                <div>
                  <div class="section-header">
                    <span>Working Tree & Diffs</span>
                  </div>
                  \(diffSection)
                </div>
                <div>
                  <div class="section-header">
                    <span>Session Activity Timeline</span>
                    <span class="subtext">\(turns.count) total turns</span>
                  </div>
                  <div id="timelineContainer">
                    \(timelineHtml)
                  </div>
                </div>
              </div>

              <script>
                let currentFilter = 'all';
                function setFilter(filter) {
                  currentFilter = filter;
                  document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active'));
                  event.target.classList.add('active');
                  filterTurns();
                }

                function filterTurns() {
                  const query = document.getElementById('searchBox').value.toLowerCase();
                  const cards = document.querySelectorAll('.turn-card');
                  cards.forEach(card => {
                    const kind = card.getAttribute('data-kind');
                    const matchesFilter = (currentFilter === 'all' || kind === currentFilter);
                    const text = card.innerText.toLowerCase();
                    const matchesQuery = !query || text.includes(query);
                    card.style.display = (matchesFilter && matchesQuery) ? 'block' : 'none';
                  });
                }

                function copyDiff() {
                  const diff = document.getElementById('diffContent').innerText;
                  navigator.clipboard.writeText(diff).then(() => {
                    alert('Git patch copied to clipboard!');
                  });
                }
              </script>
            </body>
            </html>
            """
    }

    /// Primary entry point: generates the HTML page and opens it in the default browser.
    public static func openInBrowser(
        agentName: String,
        projectSlug: String,
        cwd: String?,
        isWorking: Bool,
        sessionPath: String? = nil,
        tailLines: [String]? = nil
    ) {
        let lines: [String] = {
            if let tailLines, !tailLines.isEmpty {
                return tailLines
            }
            return AgentDetector.recentTranscriptOutput(
                forAgent: agentName,
                sessionPath: sessionPath,
                cwd: cwd,
                maxLines: 200
            )
        }()

        let turns = parseTranscript(lines: lines)
        let git = captureGitContext(cwd: cwd)
        let html = generateHtml(
            agentName: agentName,
            projectSlug: projectSlug,
            cwd: cwd,
            isWorking: isWorking,
            turns: turns,
            git: git
        )

        let safeSlug = projectSlug.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let fileName = "bantay-session-\(safeSlug.isEmpty ? "main" : safeSlug).html"
        let tmpUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)

        do {
            try html.write(to: tmpUrl, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(tmpUrl)
        } catch {
            print("[RichSessionViewer] Failed to write HTML: \(error)")
        }
    }
}
