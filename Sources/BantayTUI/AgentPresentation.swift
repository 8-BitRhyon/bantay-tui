import Foundation

/// Risk tier for an agent action shown in the notch.
enum AgentRisk: String, Sendable {
    case low
    case medium
    case high
}

/// Human readable rendering of one agent row.
struct HumanizedAgentStatus: Equatable, Sendable {
    let headline: String
    let detail: String?
    let risk: AgentRisk
    let tool: String?
}

/// One project group in the inbox. Subagents stay nested under their parent
/// workspace so N identical `project branch` rows collapse into one entry.
struct AgentRosterGroup: Equatable, Identifiable, Sendable {
    let id: String
    let project: String
    let branch: String?
    let lead: AgentSnapshot
    let subagents: [AgentSnapshot]
    let needsAttention: Bool
}

/// Pure presentation logic for the Agents inbox. No SwiftUI, no AppKit, no
/// disk access, so the logic harness compiles and tests all of it.
enum AgentPresentation {
    static func status(for agent: AgentSnapshot) -> HumanizedAgentStatus {
        let raw = agent.title ?? agent.message ?? ""
        let cleaned = clean(raw)
        let command = extractCommand(from: cleaned)
        let risk = classifyRisk(text: cleaned, command: command)

        switch agent.kind {
        case .accessRequest, .waiting:
            if let command {
                return HumanizedAgentStatus(
                    headline: "Wants to run \(humanizeCommand(command))",
                    detail: detailIfDifferent(cleaned, command.display),
                    risk: risk,
                    tool: command.base)
            }
            if isGenericInputText(cleaned) {
                return HumanizedAgentStatus(
                    headline: "Waiting for your approval",
                    detail: nil,
                    risk: risk,
                    tool: nil)
            }
            return HumanizedAgentStatus(
                headline: "Needs your input",
                detail: truncated(cleaned, limit: 140),
                risk: risk,
                tool: nil)
        case .progress, .started:
            if let command {
                return HumanizedAgentStatus(
                    headline: humanizeCommand(command).capitalizedFirst,
                    detail: detailIfDifferent(cleaned, command.display),
                    risk: risk,
                    tool: command.base)
            }
            if cleaned.isEmpty {
                return HumanizedAgentStatus(
                    headline: agent.kind.label,
                    detail: nil,
                    risk: .low,
                    tool: nil)
            }
            return HumanizedAgentStatus(
                headline: truncated(cleaned, limit: 96),
                detail: nil,
                risk: risk,
                tool: nil)
        case .failed:
            return HumanizedAgentStatus(
                headline: "Failed",
                detail: cleaned.isEmpty ? nil : truncated(cleaned, limit: 140),
                risk: .medium,
                tool: command?.base)
        case .completed:
            return HumanizedAgentStatus(
                headline: "Done",
                detail: cleaned.isEmpty ? nil : truncated(cleaned, limit: 140),
                risk: .low,
                tool: command?.base)
        case .idle, .cancelled, .clear:
            return HumanizedAgentStatus(
                headline: agent.kind.label.isEmpty ? "Idle" : agent.kind.label,
                detail: nil,
                risk: .low,
                tool: nil)
        }
    }

    static func groupRoster(_ agents: [AgentSnapshot]) -> [AgentRosterGroup] {
        var order: [String] = []
        var buckets: [String: [AgentSnapshot]] = [:]
        for agent in agents {
            let key = groupKey(for: agent)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(agent)
        }

        var groups: [AgentRosterGroup] = []
        for (index, key) in order.enumerated() {
            guard let members = buckets[key], !members.isEmpty else { continue }
            let ranked = members.sorted { rank($0) < rank($1) }
            let lead = ranked[0]
            let rest = Array(ranked.dropFirst())
            let needsAttention = members.contains {
                $0.kind == .accessRequest || $0.kind == .waiting
            }
            groups.append(
                AgentRosterGroup(
                    id: "\(index)-\(key)",
                    project: projectName(for: lead),
                    branch: lead.projectContext?.branch,
                    lead: lead,
                    subagents: rest,
                    needsAttention: needsAttention))
        }

        return groups.sorted {
            if $0.needsAttention != $1.needsAttention {
                return $0.needsAttention && !$1.needsAttention
            }
            let leftWorking = $0.lead.isWorking || $0.subagents.contains(where: \.isWorking)
            let rightWorking = $1.lead.isWorking || $1.subagents.contains(where: \.isWorking)
            if leftWorking != rightWorking {
                return leftWorking && !rightWorking
            }
            return $0.id < $1.id
        }
    }

    // MARK: - Ranking

    private static func rank(_ agent: AgentSnapshot) -> Int {
        switch agent.kind {
        case .accessRequest, .waiting: return 0
        case .failed: return 1
        case .progress, .started: return 2
        case .completed: return 3
        case .idle, .cancelled, .clear: return 4
        }
    }

    private static func groupKey(for agent: AgentSnapshot) -> String {
        let project = projectName(for: agent).lowercased()
        let workspace =
            agent.workspaceId ?? agent.cwd ?? agent.paneId ?? agent.source
        return "\(project)|\(workspace)"
    }

    private static func projectName(for agent: AgentSnapshot) -> String {
        if let project = agent.projectContext?.project, !project.isEmpty {
            return project
        }
        if let cwd = agent.cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return agent.source
    }

    // MARK: - Text

    private static func clean(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression)
        value = value.replacingOccurrences(of: "\r", with: " ")
        value = value.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        for pattern in [
            "timestamp=[^ ]+",
            "level=[^ ]+",
            "paneId=[^ ]+",
            "workspaceId=[^ ]+",
            "Created At:[^|]*",
        ] {
            value = value.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "..."
    }

    private static func isGenericInputText(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.isEmpty { return true }
        return lower == "blocked"
            || lower == "agent requires input"
            || lower == "needs input"
            || lower == "waiting"
    }

    private static func detailIfDifferent(_ cleaned: String, _ display: String) -> String? {
        guard !cleaned.isEmpty, cleaned != display else { return nil }
        return truncated(cleaned, limit: 140)
    }

    // MARK: - Commands

    struct ParsedCommand: Equatable {
        let base: String
        let args: [String]
        let display: String
    }

    static func extractCommand(from text: String) -> ParsedCommand? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        trimmed = trimmed.replacingOccurrences(
            of: "^(bash|shell|run|command)\\s*:\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive])

        if let command = matchGroup(
            pattern: "command=([^\\s,\\]]+)", in: trimmed, group: 1)
        {
            let rawArgs = matchGroup(pattern: "args=\\[([^\\]]*)\\]", in: trimmed, group: 1)
            let args = rawArgs.map { splitArgs($0) } ?? []
            return makeCommand(base: command, args: args)
        }

        let first = trimmed.components(separatedBy: .whitespaces).first ?? ""
        let candidate = first.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'("))
        let bases: Set<String> = [
            "git", "rm", "sudo", "ssh", "swift", "xcodebuild", "npm", "bun",
            "pnpm", "yarn", "pytest", "jest", "vitest", "cargo", "go",
            "curl", "wget", "make",
        ]
        let strippedBase = candidate.split(separator: "/").last.map(String.init) ?? candidate
        guard bases.contains(strippedBase) else { return nil }
        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let args = Array(tokens.dropFirst().prefix(4))
        return makeCommand(base: strippedBase, args: args)
    }

    private static func makeCommand(base: String, args: [String]) -> ParsedCommand {
        let shortBase = base.split(separator: "/").last.map(String.init) ?? base
        let display = ([shortBase] + args).joined(separator: " ")
        return ParsedCommand(base: shortBase, args: args, display: display)
    }

    private static func splitArgs(_ text: String) -> [String] {
        let trimmable = CharacterSet(charactersIn: "\"'")
        return
            text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(trimmable)) }
            .filter { !$0.isEmpty }
    }

    private static func matchGroup(pattern: String, in text: String, group: Int) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > group,
            let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    static func humanizeCommand(_ command: ParsedCommand) -> String {
        let args = command.args.joined(separator: " ")
        switch command.base {
        case "git":
            return humanizeGit(args: command.args)
        case "rm":
            let paths = command.args.filter { !$0.hasPrefix("-") }
            let target = paths.isEmpty ? args : paths.joined(separator: " ")
            return target.isEmpty ? "deleting files" : "deleting \(target)"
        case "sudo":
            if args.isEmpty { return "running with elevated permissions" }
            return "running \(args) with elevated permissions"
        case "npm", "bun", "pnpm", "yarn":
            if command.args.first == "test" { return "running tests" }
            if command.args.first == "build" { return "building the project" }
            return "running \(command.display)"
        case "swift":
            if command.args.first == "test" { return "running Swift tests" }
            if command.args.first == "build" { return "building the Swift package" }
            return "running \(command.display)"
        case "pytest", "jest", "vitest":
            return "running tests"
        case "cargo":
            if command.args.first == "test" { return "running tests" }
            return "running \(command.display)"
        case "go":
            if command.args.first == "test" { return "running Go tests" }
            return "running \(command.display)"
        case "xcodebuild":
            return "building in Xcode"
        case "ssh":
            return args.isEmpty ? "connecting over SSH" : "connecting to \(args)"
        case "curl", "wget":
            return "fetching a remote file"
        default:
            return "running \(command.display)"
        }
    }

    private static func humanizeGit(args: [String]) -> String {
        guard let sub = args.first else { return "running git" }
        let rest = args.dropFirst().joined(separator: " ")
        switch sub {
        case "status": return "checking git status"
        case "diff": return "reviewing git diff"
        case "log": return "reading git log"
        case "push": return rest.isEmpty ? "pushing to remote" : "pushing \(rest)"
        case "pull": return "pulling latest changes"
        case "fetch": return "fetching from remote"
        case "checkout", "switch": return rest.isEmpty ? "switching branch" : "switching to \(rest)"
        case "commit": return "committing changes"
        case "reset": return "resetting the branch"
        case "rebase": return "rebasing the branch"
        case "merge": return rest.isEmpty ? "merging branches" : "merging \(rest)"
        case "stash": return "stashing changes"
        default: return rest.isEmpty ? "running git \(sub)" : "running git \(sub) \(rest)"
        }
    }

    static func classifyRisk(text: String, command: ParsedCommand?) -> AgentRisk {
        let lower = text.lowercased()
        let destructive = [
            "rm -rf", "git reset --hard", "git push --force", "git push -f",
            ":(){", "mkfs", "dd if=", "drop database", "delete production",
            "sudo rm", "sudo ",
        ]
        if destructive.contains(where: { lower.contains($0) }) { return .high }
        if lower.contains("| sh") || lower.contains("| bash") { return .high }
        if lower.contains("deploy") || lower.contains("publish --prod") { return .high }

        if let command {
            switch command.base {
            case "rm", "sudo": return .medium
            case "git":
                let sub = command.args.first ?? ""
                if ["push", "commit", "reset", "rebase", "merge"].contains(sub) {
                    return .medium
                }
            default: break
            }
        }
        let mutating = [
            "write", "edit", "apply_patch", "apply patch", "chmod", "chown",
            "mv ", "cp ", "mkdir ", "git commit", "git push",
        ]
        if mutating.contains(where: { lower.contains($0) }) { return .medium }
        return .low
    }
}

extension String {
    fileprivate var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
