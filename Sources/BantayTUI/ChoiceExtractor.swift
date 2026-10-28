import Foundation

public struct ChoiceOption: Identifiable, Equatable, Sendable {
    public let id: Int
    public let label: String
    public let fullText: String
    /// Optional second line shown under the label. OpenCode forms put the
    /// option's consequence here, which is the context the user needs to
    /// choose well. Nil when the prompt has no description.
    public let detail: String?

    public init(id: Int, label: String, fullText: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.fullText = fullText
        self.detail = detail
    }
}

public enum ChoiceExtractor {
    /// Compile the three regexes once (they were rebuilt per line per call).
    private static let numberedRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^(\\d+)[\\.\\):]\\s+(.+)$", options: [])
    }()
    private static let bracketedRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^\\[(\\d+)\\]\\s+(.+)$", options: [])
    }()
    private static let radioRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "^(?:\\([x\\s\\*✓✔]\\)|\\[[x\\s\\*✓✔]\\]|[☐☑✓✔])\\s+(.+)$",
            options: .caseInsensitive)
    }()
    private static let checkboxPrefixRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "^(?:\\([x\\s\\*✓✔]\\)|\\[[x\\s\\*✓✔]\\])\\s*",
            options: .caseInsensitive)
    }()

    /// Boxed TUI prompts prefix every line with a gutter such as `┃` or `│`.
    /// Strip it before matching numbered and checkbox options.
    private static let gutterCharacters: Set<Character> = [
        "│", "┃", "║", "╎", "╏", "┆", "┇", "┊", "┋", "|",
        "▏", "▎", "▍", "▌", "▋", "▊", "▉",
    ]

    static func strippingGutter(_ line: String) -> String {
        gutterSplit(line).content
    }

    /// Strips a box gutter while keeping the indentation that follows it.
    /// OpenCode puts descriptions under an option with a deeper indent than
    /// the option row, so the indent is the only signal that separates
    /// "Remove backpass and firstmate..." from the next choice.
    static func gutterSplit(_ line: String) -> (content: String, indent: Int) {
        var rest = Substring(line.trimmingCharacters(in: .newlines))
        while rest.last?.isWhitespace == true { rest.removeLast() }

        var leading = 0
        var cursor = rest.startIndex
        while cursor < rest.endIndex, rest[cursor] == " " || rest[cursor] == "\t" {
            leading += rest[cursor] == "\t" ? 4 : 1
            cursor = rest.index(after: cursor)
        }
        var after = rest[cursor...]
        if let first = after.first, gutterCharacters.contains(first) {
            while let next = after.first, gutterCharacters.contains(next) {
                after = after.dropFirst()
            }
            leading = 0
            while let next = after.first, next == " " || next == "\t" {
                leading += next == "\t" ? 4 : 1
                after = after.dropFirst()
            }
        }
        return (
            after.trimmingCharacters(in: .whitespacesAndNewlines),
            leading
        )
    }

    /// Extracts numbered or radio-style choice options from raw text or log lines.
    public static func extractChoices(from text: String) -> [ChoiceOption] {
        let lines = text.components(separatedBy: .newlines)
        return extractChoices(fromLines: lines)
    }

    public static func extractChoices(fromLines lines: [String]) -> [ChoiceOption] {
        var options: [ChoiceOption] = []
        // The last parsed number we saw, to detect a NEW prompt restarting at 1.
        var lastNumber = 0
        // Index of the option that a deeper-indented line belongs to.
        var detailTarget: Int?
        var detailIndent = 0

        for rawLine in lines {
            let (line, indent) = gutterSplit(rawLine)
            guard !line.isEmpty else { continue }

            // Clean leading prompt symbols (▸, >, *, bullet)
            var cleanLine = line
            if cleanLine.hasPrefix("▸") || cleanLine.hasPrefix(">") || cleanLine.hasPrefix("*") {
                cleanLine = String(cleanLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            // Pattern 1: Digits followed by dot, paren, or colon (e.g. "1. Option", "1) Option")
            if let match = matchNumbered(cleanLine) {
                if match.number <= lastNumber {
                    // A new prompt started: reset so we only ever surface the
                    // most recent prompt's contiguous options.
                    options.removeAll()
                }
                options.append(
                    ChoiceOption(id: match.number, label: match.label, fullText: cleanLine))
                lastNumber = match.number
                detailTarget = options.count - 1
                detailIndent = indent
                continue
            }

            // Pattern 2: Bracketed number (e.g. "[1] Option")
            if let match = matchBracketed(cleanLine) {
                if match.number <= lastNumber {
                    options.removeAll()
                }
                options.append(
                    ChoiceOption(id: match.number, label: match.label, fullText: cleanLine))
                lastNumber = match.number
                detailTarget = options.count - 1
                detailIndent = indent
                continue
            }

            // Pattern 3: Radio button or checkbox (e.g. "( ) Option", "(x) Option", "[ ] Option")
            if let label = matchRadio(cleanLine) {
                options.append(
                    ChoiceOption(id: options.count + 1, label: label, fullText: cleanLine))
                lastNumber = options.count
                detailTarget = options.count - 1
                detailIndent = indent
                continue
            }

            guard let target = detailTarget else { continue }
            guard indent > detailIndent, !isHintLine(cleanLine) else {
                detailTarget = nil
                continue
            }
            options[target] = withDetail(cleanLine, at: target, in: options)
        }

        // A custom option can appear twice: once declared by the form and once
        // added by the TUI. Keep the first so the numbered rows match what the
        // user sees.
        while options.count >= 2, options.last?.label == options[options.count - 2].label {
            options.removeLast()
        }

        // Only return if we found at least 2 distinct choice options
        return options.count >= 2 ? options : []
    }

    private static func withDetail(
        _ line: String, at index: Int, in options: [ChoiceOption]
    ) -> ChoiceOption {
        let existing = options[index].detail ?? ""
        let merged = existing.isEmpty ? line : existing + " " + line
        let capped = merged.count > 240 ? String(merged.prefix(240)) : merged
        return ChoiceOption(
            id: options[index].id,
            label: options[index].label,
            fullText: options[index].fullText,
            detail: capped)
    }

    /// Footer and key-hint rows can sit under an option without being part of
    /// its description. They must not leak into the card as context.
    private static func isHintLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let prefixes = [
            "↑", "↓", "⇆", "esc ", "esc to", "tab ", "tab to", "enter ",
            "enter to", "ctrl+", "ctrl-", "space ", "shift+", "press ",
            "select ", "toggle ",
        ]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    private static func matchNumbered(_ line: String) -> (number: Int, label: String)? {
        guard
            let match = numberedRegex.firstMatch(
                in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)),
            let idRange = Range(match.range(at: 1), in: line),
            let labelRange = Range(match.range(at: 2), in: line),
            let number = Int(line[idRange])
        else { return nil }
        let label = cleanedLabel(String(line[labelRange]))
        guard !label.isEmpty else { return nil }
        return (number, label)
    }

    private static func matchBracketed(_ line: String) -> (number: Int, label: String)? {
        guard
            let match = bracketedRegex.firstMatch(
                in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)),
            let idRange = Range(match.range(at: 1), in: line),
            let labelRange = Range(match.range(at: 2), in: line),
            let number = Int(line[idRange])
        else { return nil }
        let label = cleanedLabel(String(line[labelRange]))
        guard !label.isEmpty else { return nil }
        return (number, label)
    }

    private static func matchRadio(_ line: String) -> String? {
        guard
            let match = radioRegex.firstMatch(
                in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)),
            let labelRange = Range(match.range(at: 1), in: line)
        else { return nil }
        let label = cleanedLabel(String(line[labelRange]))
        guard !label.isEmpty else { return nil }
        return label
    }

    /// `1. [ ] Cheese` describes a multi-select row, not a choice whose label
    /// starts with brackets. Drop the toggle marker so the card shows the
    /// option name and keeps its own selection state.
    private static func cleanedLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard
            let match = checkboxPrefixRegex.firstMatch(
                in: trimmed, options: [],
                range: NSRange(location: 0, length: trimmed.utf16.count)),
            let range = Range(match.range, in: trimmed)
        else { return trimmed }
        return String(trimmed[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
