import Foundation

/// Universal hook SDK payload mapping and config installer.
enum HookSdk {
    /// Supported agent tool families.
    enum AgentTool: String, CaseIterable {
        case aider, codex, windsurf, cursor, antigravity
    }

    /// Repo-relative path to the generic emitter script.
    static let emitterPath = "scripts/hook-emit.sh"

    /// Codex CLI hook events installed into ~/.codex/config.toml.
    static let codexHookEvents: [String] = ["PromptStart", "PromptFinish"]

    /// Whether the tool has a verified hook mechanism.
    static func isHookVerified(_ tool: AgentTool) -> Bool {
        switch tool {
        case .aider, .codex, .antigravity: return true
        case .windsurf, .cursor: return false
        }
    }

    /// Canonical payload source name for the tool.
    static func sourceName(for tool: AgentTool) -> String { tool.rawValue }

    /// Command a verified tool's hook executes to signal Bantay.
    static func hookCommand(for tool: AgentTool, port: Int, token: String?) -> String? {
        guard isHookVerified(tool) else { return nil }
        let envPrefix = token.map { "BANTAY_INGEST_TOKEN=\($0) " } ?? ""
        switch tool {
        case .aider:
            return "\(envPrefix)\(emitterPath) --source aider --type progress --title \"aider\""
        case .codex:
            return
                "\(envPrefix)\(emitterPath) --source codex --type \"$([ \"$CODEX_HOOK_EVENT\" = \"PromptStart\" ] && echo progress || echo completed)\" --title \"codex\""
        case .antigravity:
            return
                "\(envPrefix)\(emitterPath) --source antigravity --type progress --title \"antigravity\""
        case .windsurf, .cursor:
            return nil
        }
    }

    /// Maps a tool's hook payload (the JSON the hook receives on stdin) to
    /// the canonical Bantay event payload dictionary, or nil when the event
    /// is not one Bantay acts on.
    static func mapToEventPayload(_ input: [String: Any], tool: AgentTool) -> [String: Any]? {
        switch tool {
        case .aider: return mapAider(input)
        case .codex: return mapCodex(input)
        case .antigravity: return mapAntigravity(input)
        case .windsurf, .cursor: return nil
        }
    }

    private static func mapAntigravity(_ input: [String: Any]) -> [String: Any]? {
        let type = (input["type"] as? String) ?? (input["event"] as? String) ?? "progress"
        let title = (input["title"] as? String) ?? (input["tool"] as? String) ?? "antigravity"
        let kind: String
        switch type.lowercased() {
        case "start", "promptstart", "progress":
            kind = "progress"
        case "finish", "promptfinish", "completed", "done":
            kind = "completed"
        case "error", "failed":
            kind = "failed"
        case "approval", "waiting", "accessrequest":
            kind = "accessRequest"
        default:
            kind = "progress"
        }
        var payload: [String: Any] = [
            "source": "antigravity",
            "type": kind,
            "title": title,
        ]
        if let paneId = input["pane_id"] as? String ?? input["paneId"] as? String {
            payload["pane_id"] = paneId
        }
        return payload
    }

    /// Merge Bantay's hooks into an existing tool config dictionary.
    static func mergeHooks(
        existing: [String: Any], tool: AgentTool, port: Int
    ) -> [String: Any] {
        guard isHookVerified(tool) else { return existing }
        switch tool {
        case .codex:
            return mergeCodexHooks(existing: existing, port: port)
        case .aider, .antigravity:
            // Aider / Antigravity direct hook merges
            return existing
        case .windsurf, .cursor:
            return existing
        }
    }

    /// Remove only Bantay-owned hooks from a tool config dictionary.
    static func removingHooks(from settings: [String: Any], tool: AgentTool) -> [String: Any] {
        guard isHookVerified(tool) else { return settings }
        switch tool {
        case .aider, .antigravity, .windsurf, .cursor:
            return settings
        case .codex:
            guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
            var changed = false
            for event in codexHookEvents {
                guard let entry = hooks[event] as? [String: Any],
                    isOwnedCodexEntry(entry)
                else {
                    continue
                }
                hooks.removeValue(forKey: event)
                changed = true
            }
            guard changed else { return settings }
            var merged = settings
            if hooks.isEmpty {
                merged.removeValue(forKey: "hooks")
            } else {
                merged["hooks"] = hooks
            }
            return merged
        }
    }

    /// Validates required arguments for hook-emit.sh (--source, --type, --title).
    static func emitterExitCodeFor(args: [String]) -> Int {
        var source = false
        var type = false
        var title = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--source":
                if index + 1 < args.count { source = true }
                index += 2
            case "--type":
                if index + 1 < args.count { type = true }
                index += 2
            case "--title":
                if index + 1 < args.count { title = true }
                index += 2
            default:
                index += 1
            }
        }
        guard source, type, title else { return 2 }
        return 0
    }

    // MARK: - codex hooks

    private static func mapCodex(_ input: [String: Any]) -> [String: Any]? {
        guard let event = (input["event_type"] as? String) ?? (input["eventType"] as? String)
        else {
            return nil
        }
        let title = (input["prompt"] as? String) ?? "codex"
        switch event {
        case "PromptStart":
            return payload(
                source: "codex", type: "progress", title: title, message: "Codex working")
        case "PromptFinish":
            let result = input["result"] as? String
            let type = (result == "error" || result == "failed") ? "failed" : "completed"
            return payload(source: "codex", type: type, title: title, message: "Codex finished")
        case "SessionStart":
            return payload(
                source: "codex", type: "started", title: title, message: "Codex session started")
        case "SessionEnd":
            return payload(
                source: "codex", type: "completed", title: title, message: "Codex session ended")
        default:
            return nil
        }
    }

    private static func mergeCodexHooks(existing: [String: Any], port: Int) -> [String: Any] {
        guard existing["hooks"] == nil || existing["hooks"] is [String: Any] else {
            return existing
        }
        var merged = existing
        var hooks = (existing["hooks"] as? [String: Any]) ?? [:]
        for event in codexHookEvents {
            // Only add when unclaimed; preserve foreign hooks.
            guard hooks[event] == nil else { continue }
            hooks[event] = codexHookEntry(port: port)
        }
        merged["hooks"] = hooks
        return merged
    }

    /// Hook entry running the emitter via sh -lc.
    private static func codexHookEntry(port: Int) -> [String: Any] {
        guard let command = hookCommand(for: .codex, port: port, token: nil) else {
            return [:]
        }
        return ["command": ["sh", "-lc", command]]
    }

    /// Whether a config.toml hook entry invokes Bantay's emitter for codex.
    static func isOwnedCodexEntry(_ entry: [String: Any]) -> Bool {
        guard let commandList = entry["command"] as? [String] else { return false }
        return commandList.contains { isBantayCommand($0, tool: .codex) }
    }

    /// Whether a hook command string invokes Bantay's emitter for tool.
    static func isBantayCommand(_ command: String, tool: AgentTool) -> Bool {
        guard isHookVerified(tool) else { return false }
        return command.contains("\(emitterPath) --source \(tool.rawValue)")
    }

    // MARK: - aider hooks (documented shape; config install is P2)

    /// Map documented aider hook payload to canonical payload.
    private static func mapAider(_ input: [String: Any]) -> [String: Any]? {
        guard let event = input["event"] as? String else { return nil }
        let title = (input["path"] as? String) ?? "aider"
        switch event {
        case "post-edit":
            return payload(source: "aider", type: "progress", title: title, message: "Aider edited")
        case "post-commit", "pre-commit", "commit":
            return payload(
                source: "aider", type: "completed", title: title, message: "Aider finished")
        case "rejected", "error":
            return payload(source: "aider", type: "failed", title: title, message: "Aider failed")
        default:
            return nil
        }
    }

    // MARK: - canonical payload

    /// Build canonical AgentEventPayload dictionary.
    private static func payload(
        source: String, type: String, title: String, message: String?
    ) -> [String: Any] {
        var result: [String: Any] = [
            "v": 1,
            "source": source,
            "type": type,
            "title": title,
            "paneId": NSNull(),
            "workspaceId": NSNull(),
            "variance": NSNull(),
            "choices": NSNull(),
        ]
        if let message {
            result["message"] = message
        } else {
            result["message"] = NSNull()
        }
        return result
    }
}
