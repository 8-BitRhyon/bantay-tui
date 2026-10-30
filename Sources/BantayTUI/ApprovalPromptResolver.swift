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
    /// Parallel to `choices`: the option's second line when the prompt has
    /// one, otherwise an empty string. The card shows it under the label.
    let choiceDetails: [String]
    /// 1-based rows the terminal already shows checked.
    let selectedChoices: [Int]
    /// 1-based row under the terminal cursor, when the prompt prints one.
    let focusedChoice: Int?
    let variance: ApprovalVariance?
    let actionable: Bool
    let risk: AgentRisk

    static let empty = ApprovalPrompt(
        kind: .unknown, detail: nil, choices: [], choiceDetails: [], selectedChoices: [],
        focusedChoice: nil, variance: nil, actionable: false, risk: .low)

    /// 1-based row for a free-text answer when the prompt offers one
    /// ("Type your own answer", "Other", ...). Nil when typing goes straight
    /// into the prompt.
    var customChoiceNumber: Int? {
        IslandMetrics.ApprovalControls.customChoiceNumber(in: choices)
    }

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
        "context:", "shift+tab", "tab to", "↑/↓", "↑↓", "⇆", "esc ",
        "⏎", "enter to", "running…", "working…", "thinking…", "waiting…",
        "up/down", "arrow keys", "space ",
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

    /// OpenCode and other boxed TUI prompts put every line behind a vertical
    /// gutter. Strip the gutter before classification so `1. Option` and
    /// `[ ] Option` stay visible to the choice extractor.
    private static let boxGutterCharacters: Set<Character> = [
        "│", "┃", "║", "╎", "╏", "┆", "┇", "┊", "┋", "|",
        "▏", "▎", "▍", "▌", "▋", "▊", "▉",
    ]

    private static let boxBorderCharacters: Set<Character> = [
        "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘",
        "├", "┤", "┬", "┴", "┼",
    ]

    static func strippingBoxGutter(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.first, boxGutterCharacters.contains(first) {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

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
        let choiceDetails = extracted.map { $0.detail ?? "" }
        let selectedChoices =
            extracted.enumerated()
            .filter { $0.element.isSelected }
            .map { $0.offset + 1 }
        let focusedChoice =
            extracted.enumerated()
            .first { $0.element.isFocused }
            .map { $0.offset + 1 }
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
                    || $0.contains("[✓]") || $0.contains("[✔]")
                    || $0.contains("( )") || $0.contains("(x)") || $0.contains("(X)")
                    || $0.contains("☐") || $0.contains("☑")
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

        let detail =
            questionDetail(block: block, choiceCount: choices.count)
            ?? detailText(block: block, fallback: fallback)
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
            choiceDetails: choiceDetails,
            selectedChoices: selectedChoices,
            focusedChoice: focusedChoice,
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
            let content = strippingBoxGutter(line)
            guard !content.isEmpty else { continue }
            let lower = content.lowercased()
            if chromePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            if content.count <= 2 { continue }
            if content.allSatisfy({
                "─━═╌╍▁▔▀▄█▌▐░▒▓_=- ".contains($0)
            }) {
                continue
            }
            if let first = content.first, boxBorderCharacters.contains(first) {
                continue
            }
            // Keep the indent after the gutter: the choice extractor uses it
            // to tell an option's description apart from the next option.
            let indent = ChoiceExtractor.gutterSplit(line).indent
            let rendered = String(repeating: " ", count: indent) + content
            if result.last == rendered { continue }
            result.append(rendered)
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
        // A question can carry six options plus one description line each.
        // Ten lines cut the prompt in half; keep the whole block so every
        // choice and its context survives.
        return Array(lines[start...].suffix(24))
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
            if (isCommand || isQuestion) && !isJSONPayload(line) {
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

    /// A pane transcript can echo the raw form payload as JSON. That line
    /// contains the question text but is not the question: the rendered form
    /// repeats it cleanly below.
    private static func isJSONPayload(_ line: String) -> Bool {
        line.contains("{\"") || line.contains("\"options\":")
            || (line.contains("\":") && line.contains("\",\""))
    }

    /// For a choice prompt the question is the line directly above the first
    /// option. Taking every line that contains "?" merges transcript echoes
    /// and tool output into the headline; the structural position is the
    /// reliable signal.
    private static func questionDetail(block: [String], choiceCount: Int) -> String? {
        guard choiceCount >= 2,
            let firstOption = block.firstIndex(where: {
                isOptionLine(ChoiceExtractor.gutterSplit($0).content)
            })
        else { return nil }
        let candidates =
            block[..<firstOption]
            .map { ChoiceExtractor.gutterSplit($0).content }
            .filter { !$0.isEmpty && !isJSONPayload($0) }
        guard
            var picked = candidates.last(where: { $0.contains("?") }) ?? candidates.last
        else { return nil }
        picked = picked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !picked.isEmpty else { return nil }
        if picked.count > 320 {
            picked = String(picked.prefix(317)).trimmingCharacters(in: .whitespaces) + "..."
        }
        return picked
    }

    private static func isOptionLine(_ content: String) -> Bool {
        if let first = content.first, first.isNumber {
            let rest = content.drop(while: { $0.isNumber })
            if let marker = rest.first, marker == "." || marker == ")" || marker == ":" {
                return true
            }
        }
        // Bracketed and radio rows only: "[1]", "[ ]", "(x)". A log prefix
        // such as "[bantay]" must never count as an option.
        if content.hasPrefix("[") || content.hasPrefix("(") {
            guard let marker = content.dropFirst().first else { return false }
            return marker.isNumber || marker == " " || marker == "x" || marker == "X"
                || marker == "*" || marker == "✓" || marker == "✔"
        }
        return content.hasPrefix("☐") || content.hasPrefix("☑")
    }

    /// Whether a pane tail shows a form's review step: no selectable rows,
    /// a Submit control in the header, and at least one `Field: answer`
    /// summary line. Submitting from here takes one final Enter.
    static func isReviewState(_ rawTail: String) -> Bool {
        let lines = meaningfulLines(rawTail)
        guard ChoiceExtractor.extractChoices(fromLines: lines).isEmpty else { return false }
        let contents = lines.map { ChoiceExtractor.gutterSplit($0).content }
        guard contents.contains(where: { $0.lowercased().contains("submit") }) else {
            return false
        }
        let summaries = contents.filter { content in
            guard let colon = content.firstIndex(of: ":") else { return false }
            let label = content[..<colon].trimmingCharacters(in: .whitespaces)
            let value = content[content.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            return label.count >= 2 && label.count <= 80 && !value.isEmpty
                && !label.lowercased().contains("http")
        }
        return !summaries.isEmpty
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
