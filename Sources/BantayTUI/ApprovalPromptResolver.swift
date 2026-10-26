import Foundation

/// What a blocked agent is actually asking for, distilled from the live pane
/// or transcript. This is the source of truth for approval cards: exact
/// detail, real choices, whether the request is actionable, and its risk.
struct ApprovalPrompt: Equatable, Sendable {
    enum Kind: String, Sendable {
        case permission
        case question
        case waiting
        case unknown
    }

    let kind: Kind
    let detail: String?
    let choices: [String]
    let variance: ApprovalVariance?
    let actionable: Bool
    let risk: AgentRisk

    static let empty = ApprovalPrompt(
        kind: .unknown, detail: nil, choices: [], variance: nil,
        actionable: false, risk: .low)

    var isEmpty: Bool {
        detail == nil && choices.isEmpty
    }

    var fingerprint: String {
        "\(kind.rawValue)|\(detail ?? "")|\(choices.joined(separator: "|"))"
    }
}

/// Pure parser for terminal approval prompts. It must be conservative:
/// showing Allow and Deny on a prompt that is not a permission request is
/// worse than showing Review only.
enum ApprovalPromptResolver {
    /// Ignore terminal chrome and TUI status rows so they never become the
    /// "request" the user is asked to approve.
    private static let chromePrefixes: [String] = [
        "esc to interrupt", "ctrl+c", "ctrl-c", "press ", "tokens:",
        "context:", "shift+tab", "tab to", "↑/↓", "⏎", "enter to",
        "running…", "working…", "thinking…", "waiting…",
    ]

    private static let permissionWords: [String] = [
        "allow", "approve", "permission", "proceed", "run command",
        "execute", "would you like", "do you want", "may i", "ok to",
        "confirm", "authorize", "write to", "edit file", "create file",
        "delete", "overwrite", "install", "wants to use", "wants to run",
        "needs permission", "requires permission",
    ]

    private static let commandPrefixes: [String] = [
        "$ ", "bash:", "command:", "command=", "tool:", "run:", "exec:",
        "git ", "npm ", "bun ", "pnpm ", "yarn ", "swift ", "cargo ",
        "go ", "rm ", "sudo ", "ssh ", "curl ", "wget ", "make ",
        "edit ", "write ", "read ", "file_path", "path:",
    ]

    static func resolve(
        rawTail: String,
        fallbackTitle: String? = nil,
        fallbackMessage: String? = nil,
        fallbackVariance: ApprovalVariance? = nil,
        kind: AgentEventKind
    ) -> ApprovalPrompt {
        let lines = meaningfulLines(rawTail)
        let fallback = fallbackText(title: fallbackTitle, message: fallbackMessage)
        let block = promptBlock(lines) ?? fallback.map { [$0] } ?? []
        guard !block.isEmpty else { return .empty }

        let text = block.joined(separator: "\n")
        let lower = text.lowercased()
        let extracted = ChoiceExtractor.extractChoices(fromLines: block)
        let choices = extracted.map(\.label)
        let hasPermission = permissionWords.contains { lower.contains($0) }
        let hasQuestion =
            text.contains("?") || lower.contains("[y/n]") || lower.contains("(y/n)")
            || lower.contains("yes or no") || lower.contains("choose")
        let hasYesNo =
            lower.contains("[y/n]") || lower.contains("(y/n)")
            || lower.contains("yes or no") || lower.contains("y or n")
        let isMulti =
            block.contains {
                $0.contains("[ ]") || $0.contains("[x]") || $0.contains("[X]")
                    || $0.contains("( )") || $0.contains("(x)") || $0.contains("(X)")
            } || lower.contains("select all") || lower.contains("select one or more")

        let variance: ApprovalVariance? = {
            if choices.count >= 2 { return isMulti ? .multi : .choices }
            if hasYesNo || (hasPermission && hasQuestion) { return .yesNo }
            return fallbackVariance
        }()

        let promptKind: ApprovalPrompt.Kind = {
            if hasPermission { return .permission }
            if hasQuestion || choices.count >= 2 { return .question }
            if kind == .waiting { return .waiting }
            return .unknown
        }()

        let detail = detailText(block: block, fallback: fallback)
        let actionable =
            kind == .accessRequest
            && (choices.count >= 2
                || (promptKind == .permission && variance != nil))
        let risk = AgentPresentation.classifyRisk(
            text: text,
            command: detail.flatMap { AgentPresentation.extractCommand(from: $0) })

        return ApprovalPrompt(
            kind: promptKind,
            detail: detail,
            choices: choices,
            variance: variance,
            actionable: actionable,
            risk: risk)
    }

    static func fingerprint(for event: AgentEvent, prompt: ApprovalPrompt?) -> String {
        if let prompt, !prompt.isEmpty { return prompt.fingerprint }
        let base = [
            event.kind.rawValue,
            event.title ?? "",
            event.message ?? "",
            (event.choices ?? []).joined(separator: "|"),
        ].joined(separator: "|")
        return base
    }

    private static func meaningfulLines(_ raw: String) -> [String] {
        let cleaned = LogFormatter.cleanedTail(raw, maxLines: 30, maxLineLength: 240)
        var result: [String] = []
        for line in cleaned {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            if chromePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            if trimmed.count <= 2 { continue }
            if trimmed.allSatisfy({ "─━═╌╍▁▔_=- ".contains($0) }) { continue }
            if trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰")
                || trimmed.hasPrefix("│") || trimmed.hasPrefix("┌")
                || trimmed.hasPrefix("└") || trimmed.hasPrefix("├")
            {
                continue
            }
            if result.last == trimmed { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func promptBlock(_ lines: [String]) -> [String]? {
        guard !lines.isEmpty else { return nil }
        let markers = [
            "?", "[y/n]", "(y/n)", "allow", "approve", "permission",
            "proceed", "would you like", "do you want", "confirm",
            "choose", "select", "run command", "execute",
        ]
        let index = lines.lastIndex { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) }
        }
        guard let index else {
            return Array(lines.suffix(4))
        }
        let start = max(index - 3, 0)
        return Array(lines[start...].suffix(10))
    }

    private static func detailText(block: [String], fallback: String?) -> String? {
        var picked: [String] = []
        for line in block {
            let lower = line.lowercased()
            let isCommand = commandPrefixes.contains { lower.hasPrefix($0) }
            let isQuestion =
                lower.contains("?") || lower.contains("[y/n]")
                || lower.contains("(y/n)") || lower.hasPrefix("allow")
                || lower.hasPrefix("approve") || lower.hasPrefix("permission")
            if isCommand || isQuestion {
                picked.append(line)
            }
        }
        if picked.isEmpty {
            picked = Array(block.suffix(3))
        }
        var text = picked.joined(separator: "\n")
        if text.isEmpty { text = fallback ?? "" }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > 320 {
            text = String(text.prefix(317)).trimmingCharacters(in: .whitespaces) + "..."
        }
        return text
    }

    private static func fallbackText(title: String?, message: String?) -> String? {
        var parts: [String] = []
        for candidate in [title, message] {
            guard let candidate else { continue }
            if IslandMetrics.isGenericApprovalText(candidate) { continue }
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !parts.contains(cleaned) {
                parts.append(cleaned)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
