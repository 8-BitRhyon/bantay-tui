import Foundation

/// Pure Claude Code hook configuration logic and payload mapping.
enum ClaudeHookInstaller {
    /// Builds the curl command that streams Claude hook stdin to Bantay's ingest server.
    static func hookCommand(port: Int, token: String? = nil) -> String {
        if let token {
            return
                "curl -s -X POST --data-binary @- http://127.0.0.1:\(port)/events?token=\(token)"
        }
        return "curl -s -X POST --data-binary @- http://127.0.0.1:\(port)/events"
    }

    /// Generates the Claude settings.json `hooks` dictionary for Bantay events.
    static func hooksSection(port: Int, token: String? = nil) -> [String: Any] {
        let command = hookCommand(port: port, token: token)
        let eventEntry: [[String: Any]] = [
            [
                "matcher": "",
                "hooks": [
                    ["type": "command", "command": command]
                ],
            ]
        ]
        let notificationEntry: [[String: Any]] = [
            [
                "matcher": "agent_needs_input|agent_completed|permission_prompt|idle_prompt",
                "hooks": [
                    ["type": "command", "command": command]
                ],
            ]
        ]
        return [
            "hooks": [
                "PermissionPrompt": eventEntry,
                "PermissionRequest": eventEntry,
                "Stop": eventEntry,
                "StopFailure": eventEntry,
                "Notification": notificationEntry,
            ]
        ]
    }

    /// Determines whether a hook command matches Bantay's current curl pattern.
    static func isBantayHook(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        let pattern =
            #"^\s*curl\b.*\s--data-binary\s+@-\s+http://127\.0\.0\.1:\d+/events(?:\?[^\s]*)?\s*$"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    /// Matches hooks installed by older Bantay versions for backwards compatibility.
    static func isLegacyBantayHook(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        let pattern =
            #"^\s*curl\b.*\s-{1,2}(?:d|data(?:-binary)?)\s+@-\s+http://127\.0\.0\.1:\d+/events(?:\?[^\s]*)?\b"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    /// True when an entry's hooks include at least one Bantay hook.
    static func isBantayEntry(_ entry: [String: Any]) -> Bool {
        guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
        return entryHooks.contains(where: { isBantayHook($0) || isLegacyBantayHook($0) })
    }

    /// True when a single hook command is Bantay-owned.
    static func isOwnedBantayHook(_ hook: [String: Any]) -> Bool {
        isBantayHook(hook) || isLegacyBantayHook(hook)
    }

    /// Merges Bantay hooks into an existing settings dictionary, preserving foreign hooks.
    static func mergedSettings(
        existing: [String: Any], port: Int, token: String? = nil
    ) -> [String: Any] {
        guard existing["hooks"] == nil || existing["hooks"] is [String: Any] else {
            return existing
        }
        var merged = existing
        var hooks = (existing["hooks"] as? [String: Any]) ?? [:]
        let bantayHooks =
            (hooksSection(port: port, token: token)["hooks"] as? [String: Any]) ?? [:]
        for (event, bantayEntries) in bantayHooks {
            guard let fresh = bantayEntries as? [[String: Any]] else { continue }
            guard let existingEntries = hooks[event] as? [[String: Any]] else {
                if hooks[event] != nil {
                    continue
                }
                hooks[event] = fresh
                continue
            }
            var entries = existingEntries
            entries.removeAll { isBantayEntry($0) }
            entries.append(contentsOf: fresh)
            hooks[event] = entries
        }
        merged["hooks"] = hooks
        return merged
    }

    /// Removes Bantay-owned hooks from a settings dictionary.
    static func removingBantayHooks(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var changed = false
        var emptyEvents: [String] = []
        for (event, entries) in hooks {
            guard let list = entries as? [[String: Any]] else { continue }
            let filtered = list.compactMap { entry -> [String: Any]? in
                guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
                    return entry
                }
                let before = entryHooks.count
                entryHooks.removeAll(where: isOwnedBantayHook)
                guard entryHooks.count != before else { return entry }
                changed = true
                guard !entryHooks.isEmpty else { return nil }
                var partial = entry
                partial["hooks"] = entryHooks
                return partial
            }
            if filtered.isEmpty {
                emptyEvents.append(event)
            } else {
                hooks[event] = filtered
            }
        }
        guard changed else { return settings }
        for event in emptyEvents {
            hooks.removeValue(forKey: event)
        }
        var merged = settings
        if hooks.isEmpty {
            merged.removeValue(forKey: "hooks")
        } else {
            merged["hooks"] = hooks
        }
        return merged
    }

    /// Maps a Claude Code hook payload (stdin JSON) to a Bantay event payload
    /// dictionary, or nil when the event is not one we act on.
    static func mapToEventPayload(_ json: [String: Any]) -> [String: Any]? {
        guard let eventName = json["hook_event_name"] as? String else { return nil }
        let toolName = json["tool_name"] as? String ?? "agent"
        let mode = json["permission_prompt_mode"] as? String
        let toolInput = json["tool_input"] as? [String: Any]
        let title: String =
            toolInput.flatMap {
                ($0["command"] as? String) ?? ($0["file_path"] as? String)
                    ?? ($0["description"] as? String)
            } ?? toolName

        switch eventName {
        case "PermissionPrompt", "PermissionRequest":
            var payload: [String: Any] = [
                "source": "claude",
                "type": "access_request",
                "title": title,
                "message": "Claude needs approval",
                "variance": "yes-no",
            ]
            if let mode, mode == "bypassPermissions" {
                payload["message"] = "Claude (bypass-permissions mode)"
            }
            return payload
        case "Stop", "SubagentStop":
            return [
                "source": "claude",
                "type": "completed",
                "title": title,
                "message": "Claude finished",
            ]
        case "StopFailure":
            let reason =
                json["error"] as? String ?? json["stop_hook_active"] as? String
                ?? json["transcript_path"] as? String
            var payload: [String: Any] = [
                "source": "claude",
                "type": "failed",
                "title": title,
                "message": reason ?? "Claude stopped with an error",
            ]
            if let stopReason = json["stop_reason"] as? String {
                payload["message"] = "Claude failed: \(stopReason)"
            }
            return payload
        case "Notification":
            let matcher = json["matcher"] as? String ?? json["message"] as? String ?? ""
            if matcher.contains("agent_completed") {
                return [
                    "source": "claude",
                    "type": "completed",
                    "title": title,
                    "message": "Claude finished",
                ]
            }
            if matcher.contains("agent_needs_input")
                || matcher.contains("permission_prompt") || matcher.contains("idle_prompt")
            {
                return [
                    "source": "claude",
                    "type": "access_request",
                    "title": title,
                    "message": "Claude needs your input",
                    "variance": "yes-no",
                ]
            }
            return nil
        default:
            return nil
        }
    }
}

/// Validates safety before persisting modified Claude settings.json files.
enum ClaudeHookWriteDecision {
    case write([String: Any])
    case abort

    /// Aborts write if the file exists but failed to parse safely.
    static func decide(
        fileExists: Bool, parsed: Bool, merged: [String: Any]
    ) -> ClaudeHookWriteDecision {
        guard !(fileExists && !parsed) else { return .abort }
        return .write(merged)
    }
}
