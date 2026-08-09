import Foundation

public struct ChoiceOption: Identifiable, Equatable, Sendable {
    public let id: Int
    public let label: String
    public let fullText: String

    public init(id: Int, label: String, fullText: String) {
        self.id = id
        self.label = label
        self.fullText = fullText
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
            pattern: "^(?:\\([x\\s\\*]\\)|\\[[x\\s\\*]\\])\\s+(.+)$",
            options: .caseInsensitive)
    }()

    /// Extracts numbered or radio-style choice options from raw text or log lines.
    /// Supports patterns like:
    /// - "1. Vintage star chart"
    /// - "▸ 1. Vintage star chart"
    /// - "( ) Painted brush stars"
    /// - "[1] Cartoon/illustration stars"
    public static func extractChoices(from text: String) -> [ChoiceOption] {
        let lines = text.components(separatedBy: .newlines)
        return extractChoices(fromLines: lines)
    }

    public static func extractChoices(fromLines lines: [String]) -> [ChoiceOption] {
        var options: [ChoiceOption] = []
        // The last parsed number we saw, to detect a NEW prompt restarting at 1.
        var lastNumber = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Clean leading prompt symbols (▸, >, *, bullet)
            var cleanLine = line
            if cleanLine.hasPrefix("▸") || cleanLine.hasPrefix(">") || cleanLine.hasPrefix("*") {
                cleanLine = String(cleanLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            // Pattern 1: Digits followed by dot, paren, or colon (e.g. "1. Option", "1) Option")
            if let match = matchNumbered(cleanLine) {
                if match.number < lastNumber {
                    // A new prompt started: reset so we only ever surface the
                    // most recent prompt's contiguous options.
                    options.removeAll()
                }
                options.append(
                    ChoiceOption(id: match.number, label: match.label, fullText: cleanLine))
                lastNumber = match.number
                continue
            }

            // Pattern 2: Bracketed number (e.g. "[1] Option")
            if let match = matchBracketed(cleanLine) {
                if match.number < lastNumber {
                    options.removeAll()
                }
                options.append(
                    ChoiceOption(id: match.number, label: match.label, fullText: cleanLine))
                lastNumber = match.number
                continue
            }

            // Pattern 3: Radio button or checkbox (e.g. "( ) Option", "(x) Option", "[ ] Option")
            if let label = matchRadio(cleanLine) {
                options.append(
                    ChoiceOption(id: options.count + 1, label: label, fullText: cleanLine))
                lastNumber = options.count
            }
        }

        // Only return if we found at least 2 distinct choice options
        return options.count >= 2 ? options : []
    }

    private static func matchNumbered(_ line: String) -> (number: Int, label: String)? {
        guard
            let match = numberedRegex.firstMatch(
                in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)),
            let idRange = Range(match.range(at: 1), in: line),
            let labelRange = Range(match.range(at: 2), in: line),
            let number = Int(line[idRange])
        else { return nil }
        let label = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
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
        let label = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (number, label)
    }

    private static func matchRadio(_ line: String) -> String? {
        guard
            let match = radioRegex.firstMatch(
                in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)),
            let labelRange = Range(match.range(at: 1), in: line)
        else { return nil }
        let label = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return label
    }
}
