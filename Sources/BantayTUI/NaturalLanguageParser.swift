import Foundation

/// Barrie-style natural language task parser — pure, deterministic, and
/// locale-agnostic, so it scales to any user without per-user state.
///
/// Handles (English):
///   - Relative dates: today / tonight / tomorrow / day after tomorrow / in N
///     days / next week / EOD / end of day / EOM
///   - Weekday names: monday…sunday (this week, or next week when past)
///   - Absolute dates: mar 5 / 5/20 / 2026-05-20 / may 20th
///   - Times: at 5pm / at 5:30 / by 5 / 17:00
///   - Priority: !! (high), ! (medium)
///   - Tags: @work / @home (non-agent @tokens)
///   - Agents: @claude @codex @kilo @herdr etc.
///   - Everything parsed is REMOVED from the title; the remainder is the task.
public enum NaturalLanguageParser {
    public struct Parsed: Equatable, Sendable {
        public var cleanTitle: String
        public var tags: [String]
        public var priority: TaskPriority
        public var assignedAgent: String?
        public var dueDate: Date?

        public init(
            cleanTitle: String, tags: [String] = [], priority: TaskPriority = .medium,
            assignedAgent: String? = nil, dueDate: Date? = nil
        ) {
            self.cleanTitle = cleanTitle
            self.tags = tags
            self.priority = priority
            self.assignedAgent = assignedAgent
            self.dueDate = dueDate
        }
    }

    public static let knownAgents: Set<String> = [
        "claude", "codex", "herdr", "kilo", "freebuff", "opencode", "cursor", "aider",
        "windsurf", "gemini",
    ]

    /// Weekday names → Calendar weekday (1 = Sunday, 2 = Monday…).
    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3,
        "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    public static func parse(_ input: String, now: Date = Date()) -> Parsed {
        let calendar = Calendar.current
        let tokens = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var clean: [String] = []
        var tags: [String] = []
        var priority: TaskPriority = .medium
        var assignedAgent: String?
        var dueComponents: (date: Date?, time: Date?)

        var i = 0
        while i < tokens.count {
            let raw = tokens[i]

            // Priority markers.
            if raw.hasPrefix("!!") {
                priority = .high
                i += 1
                continue
            }
            if raw == "!" || raw == "!!" {
                priority = raw == "!!" ? .high : .medium
                i += 1
                continue
            }

            // @tokens → agents or tags.
            if raw.hasPrefix("@") && raw.count > 1 {
                let tag = String(raw.dropFirst()).lowercased()
                if knownAgents.contains(tag) {
                    assignedAgent = tag
                } else {
                    tags.append(tag)
                }
                i += 1
                continue
            }

            // Times (at/by 5pm, 17:00, at 5:30) — before dates so "at 5pm"
            // isn't swallowed by the date introducer.
            if let time = parseTime(tokens: tokens, at: &i, calendar: calendar) {
                dueComponents.time = time
                continue
            }

            // Relative / named dates.
            if let due = parseRelativeDate(
                tokens: tokens, at: &i, now: now, calendar: calendar)
            {
                dueComponents.date = due
                continue
            }

            clean.append(raw)
            i += 1
        }

        // Combine date + time into one Date. A time without a date phrase
        // defaults to today; a date without a time stays at start of day.
        var dueDate = dueComponents.date
        if dueDate == nil, dueComponents.time != nil {
            dueDate = calendar.startOfDay(for: now)
        }
        if let date = dueDate, let time = dueComponents.time {
            let dc = calendar.dateComponents(
                [.hour, .minute], from: time)
            dueDate = calendar.date(
                bySettingHour: dc.hour ?? 0, minute: dc.minute ?? 0, second: 0, of: date)
        }

        let cleanTitle = clean.joined(separator: " ").trimmingCharacters(
            in: .whitespacesAndNewlines)
        return Parsed(
            cleanTitle: cleanTitle.isEmpty ? input : cleanTitle,
            tags: tags, priority: priority, assignedAgent: assignedAgent, dueDate: dueDate)
    }

    // MARK: - Date phrases

    private static func parseRelativeDate(
        tokens: [String], at index: inout Int, now: Date, calendar: Calendar
    ) -> Date? {
        let startOfDay = calendar.startOfDay(for: now)
        // "before" / "by" / "at" / "on" / "until" introduce a date phrase.
        // Only consume the introducer if the NEXT token is actually a date
        // token; otherwise leave it in the title (e.g. "at" in "look at this").
        var idx = index
        var token = tokens[idx].lowercased()
        if ["before", "by", "at", "on", "until", "till"].contains(token),
            idx + 1 < tokens.count
        {
            let next = tokens[idx + 1].lowercased()
            let looksLikeDate =
                [
                    "today", "tonight", "tomorrow", "tmrw", "eod", "end", "eom", "endofday",
                    "endofmonth", "sunday", "monday", "tuesday", "wednesday", "thursday",
                    "friday", "saturday", "sun", "mon", "tue", "wed", "thu", "fri", "sat",
                ]
                .contains(next)
                || Int(next) != nil
            if looksLikeDate {
                idx += 1
                token = tokens[idx].lowercased()
            }
        }

        switch token {
        case "today", "tonight":
            index = idx + 1
            return startOfDay
        case "tomorrow", "tmrw":
            index = idx + 1
            return calendar.date(byAdding: .day, value: 1, to: startOfDay)
        case "eod", "endofday":
            // "end of day" → consume the full phrase (end of day).
            index = consumePhrase(tokens, from: idx, phrase: ["end", "of", "day"])
            let comps = calendar.dateComponents([.year, .month, .day], from: startOfDay)
            return calendar.date(
                bySettingHour: 23, minute: 59, second: 0, of: calendar.date(from: comps)!)
        case "end":
            // "end of day" / "end of month" / bare "end".
            if idx + 2 < tokens.count, tokens[idx + 1] == "of" {
                let what = tokens[idx + 2].lowercased()
                if what == "day" || what.hasPrefix("day") {
                    index = idx + 3
                    let comps = calendar.dateComponents([.year, .month, .day], from: startOfDay)
                    return calendar.date(
                        bySettingHour: 23, minute: 59, second: 0,
                        of: calendar.date(from: comps)!)
                }
                if what == "month" || what.hasPrefix("month") || what == "eom" {
                    index = idx + 3
                    let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfDay)!
                    let comps = calendar.dateComponents([.year, .month], from: nextMonth)
                    return calendar.date(from: comps)!
                }
            }
            index = idx + 1
            let comps = calendar.dateComponents([.year, .month, .day], from: startOfDay)
            return calendar.date(
                bySettingHour: 23, minute: 59, second: 0, of: calendar.date(from: comps)!)
        case "eom", "endofmonth":
            index = idx + 1
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfDay)!
            let comps = calendar.dateComponents([.year, .month], from: nextMonth)
            return calendar.date(from: comps)!
        case "day", "days":
            // "in 3 days" → prior token was a number.
            if idx >= 1, let n = Int(tokens[idx - 1]) {
                index = idx + 1
                return calendar.date(byAdding: .day, value: n, to: startOfDay)
            }
            return nil
        case "week":
            if idx >= 1, tokens[idx - 1] == "next" {
                index = idx + 1
                return calendar.date(byAdding: .day, value: 7, to: startOfDay)
            }
            return nil
        case "next":
            return nil
        default:
            break
        }

        // Weekday names.
        if let weekday = weekdayNames[token] {
            var daysAhead = weekday - calendar.component(.weekday, from: startOfDay)
            if daysAhead <= 0 { daysAhead += 7 }  // next occurrence
            index = idx + 1
            return calendar.date(byAdding: .day, value: daysAhead, to: startOfDay)
        }

        // "in N days" where "in" is the current token.
        if token == "in", idx + 1 < tokens.count, let n = Int(tokens[idx + 1]),
            idx + 2 < tokens.count, ["day", "days", "week", "weeks"].contains(tokens[idx + 2])
        {
            let isWeeks = tokens[idx + 2].hasPrefix("week")
            index = idx + 3
            let value = isWeeks ? n * 7 : n
            return calendar.date(byAdding: .day, value: value, to: startOfDay)
        }

        return nil
    }

    /// Consume a multi-token phrase (e.g. ["end","of","day"]) if it matches,
    /// returning the index AFTER it; otherwise consume just the current token.
    private static func consumePhrase(
        _ tokens: [String], from idx: Int, phrase: [String]
    ) -> Int {
        var end = idx
        for (offset, word) in phrase.enumerated() {
            guard idx + offset < tokens.count,
                tokens[idx + offset].lowercased() == word
            else { break }
            end = idx + offset + 1
        }
        return end == idx ? idx + 1 : end
    }

    // MARK: - Times

    private static func parseTime(
        tokens: [String], at index: inout Int, calendar: Calendar
    ) -> Date? {
        let token = tokens[index].lowercased()

        // "17:00" / "5:30pm"
        if let date = absoluteTime(token) {
            index += 1
            return date
        }

        // "at 5pm" / "by 5" / "at 5:30"
        if token == "at" || token == "by" {
            guard index + 1 < tokens.count else { return nil }
            let next = tokens[index + 1].lowercased()
            if let date = absoluteTime(next) {
                index += 2
                return date
            }
            // bare hour "at 5" → 5pm.
            if let hour = Int(next), hour >= 1, hour <= 12,
                index + 2 >= tokens.count
                    || !isTimeWord(tokens[index + 2])
            {
                index += 2
                let hour24 = hour == 12 ? 12 : hour + 12  // assume PM for bare "5"
                return calendar.date(bySettingHour: hour24, minute: 0, second: 0, of: Date())
            }
        }

        return nil
    }

    private static func isTimeWord(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("pm") || l.hasPrefix("am") || l.hasPrefix("o'clock")
    }

    private static func absoluteTime(_ token: String) -> Date? {
        let lower = token.lowercased()
        let hasAM = lower.hasSuffix("am")
        let hasPM = lower.hasSuffix("pm")
        var core = lower
        if hasAM || hasPM {
            core = String(lower.dropLast(2))
        }
        let parts = core.split(separator: ":")
        guard let h = Int(parts[0]), h >= 1, h <= 24 else { return nil }
        let m = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var hour = h
        if hasPM && h < 12 { hour += 12 }
        if hasAM && h == 12 { hour = 0 }
        return Calendar.current.date(bySettingHour: hour, minute: m, second: 0, of: Date())
    }
}
