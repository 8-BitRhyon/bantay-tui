import Foundation

/// Pure Claude Code hook-config logic: settings.json merging, hook command
/// generation, and payload mapping from Claude's hook JSON to Bantay's event
/// payload shape. Kept free of file I/O so the harness can test it.
enum ClaudeHookInstaller {
    /// The hook command that streams the hook's stdin JSON to Bantay's local
    /// ingest server. `curl` ships with macOS.
    static func hookCommand(port: Int) -> String {
        "curl -s -X POST --data-binary @- http://127.0.0.1:\(port)/events"
    }

    /// The Claude settings.json `hooks` section Bantay installs. We only
    /// touch `PermissionPrompt` and `Stop` — everything else is preserved.
    static func hooksSection(port: Int) -> [String: Any] {
        let command = hookCommand(port: port)
        return [
            "hooks": [
                "PermissionPrompt": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": command]
                        ],
                    ]
                ],
                "Stop": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": command]
                        ],
                    ]
                ],
            ]
        ]
    }

    /// True when a hook's command targets the Bantay ingest server, regardless
    /// of which port Bantay used at install time.
    static func isBantayHook(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains("http://127.0.0.1:")
            && command.contains("/events")
    }

    /// True when an entry's hooks include at least one Bantay hook.
    static func isBantayEntry(_ entry: [String: Any]) -> Bool {
        guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
        return entryHooks.contains(where: isBantayHook)
    }

    /// Merge the Bantay hooks into an existing settings dictionary, preserving
    /// all unrelated keys. Existing entries for the same events are kept and
    /// Bantay's entries appended after any stale Bantay entries are removed,
    /// so foreign hooks (herdr, user config) are never overwritten and
    /// re-installs do not duplicate.
    static func mergedSettings(existing: [String: Any], port: Int) -> [String: Any] {
        var merged = existing
        var hooks = (existing["hooks"] as? [String: Any]) ?? [:]
        let bantayHooks = (hooksSection(port: port)["hooks"] as? [String: Any]) ?? [:]
        for (event, bantayEntries) in bantayHooks {
            guard let fresh = bantayEntries as? [[String: Any]] else { continue }
            var existingEntries = (hooks[event] as? [[String: Any]]) ?? []
            existingEntries.removeAll { isBantayEntry($0) }
            existingEntries.append(contentsOf: fresh)
            hooks[event] = existingEntries
        }
        merged["hooks"] = hooks
        return merged
    }

    /// Remove only the Bantay-owned hooks from a settings dictionary.
    /// Hooks are identified by command shape (`http://127.0.0.1:<port>/events`)
    /// and filtered individually, so a foreign hook that shares an entry with
    /// a Bantay hook survives. Entries that become hook-less are dropped and
    /// an empty `hooks` key is removed entirely.
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
                entryHooks.removeAll(where: isBantayHook)
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
        case "PermissionPrompt":
            var payload: [String: Any] = [
                "source": "claude",
                "type": "access_request",
                "title": title,
                "message": "Claude needs approval",
                "variance": "yes_no",
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
        default:
            return nil
        }
    }
}
