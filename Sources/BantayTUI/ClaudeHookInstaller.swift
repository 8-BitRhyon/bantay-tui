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

    /// True when a hook's command has the Bantay command SHAPE: a `curl`
    /// invocation that pipes the hook's stdin to the local ingest server on
    /// any port. The port is matched as port-agnostic digits so old installs
    /// stay removable after `ingestPort` changes. A foreign command that merely
    /// mentions a localhost URL (e.g. `myagent --url http://127.0.0.1:8080/events`)
    /// is not matched and is never deleted. A Bantay command wrapped in a
    /// launcher (e.g. `sh -c 'curl ...'`) is also not matched — it survives
    /// removal untouched, never corrupted.
    static func isBantayHook(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        let pattern =
            #"^\s*curl\b.*\s--data-binary\s+@-\s+http://127\.0\.0\.1:\d+/events\b\s*$"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    /// Legacy matcher for hooks installed by older Bantay builds whose curl
    /// invocation did not use `--data-binary @-` (e.g. `-d @-` or `--data
    /// @-`). `removingBantayHooks` must still remove them, but the matcher
    /// keeps the safety bar of the current shape: a `curl` command whose
    /// argument is stdin (`@-`) targeting the localhost ingest path. A foreign
    /// command that merely mentions a localhost URL still never matches.
    static func isLegacyBantayHook(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        let pattern =
            #"^\s*curl\b.*\s-{1,2}(?:d|data(?:-binary)?)\s+@-\s+http://127\.0\.0\.1:\d+/events\b"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    /// True when an entry's hooks include at least one Bantay hook (current or
    /// legacy shape). Used for merge de-dup and removal so old-format installs
    /// stay removable.
    static func isBantayEntry(_ entry: [String: Any]) -> Bool {
        guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
        return entryHooks.contains(where: { isBantayHook($0) || isLegacyBantayHook($0) })
    }

    /// True when a single hook command is Bantay-owned in either the current or
    /// the legacy shape.
    static func isOwnedBantayHook(_ hook: [String: Any]) -> Bool {
        isBantayHook(hook) || isLegacyBantayHook(hook)
    }

    /// Merge the Bantay hooks into an existing settings dictionary, preserving
    /// all unrelated keys. Existing entries for the same events are kept and
    /// Bantay's entries appended after any stale Bantay entries are removed,
    /// so foreign hooks (herdr, user config) are never overwritten and
    /// re-installs do not duplicate. A `hooks` value that exists but is not a
    /// `[String: Any]` (a String, an Array, or any other foreign shape) is
    /// opaque and returned unchanged — never fabricated or replaced. A
    /// non-conforming value for a single event is preserved untouched too,
    /// even at the cost of skipping that event's Bantay hook.
    static func mergedSettings(existing: [String: Any], port: Int) -> [String: Any] {
        guard existing["hooks"] == nil || existing["hooks"] is [String: Any] else {
            return existing
        }
        var merged = existing
        var hooks = (existing["hooks"] as? [String: Any]) ?? [:]
        let bantayHooks = (hooksSection(port: port)["hooks"] as? [String: Any]) ?? [:]
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

/// Decides whether the I/O layer may write `~/.claude/settings.json` after a
/// read. Writing over a file that exists but failed to parse would destroy the
/// user's Claude Code configuration (a truncated write, a permission hiccup,
/// or foreign JSON5/comment-laden content all produce `parsed == false`), so
/// the caller must `abort` — never write — in that case.
enum ClaudeHookWriteDecision {
    case write([String: Any])
    case abort

    /// `abort` whenever `fileExists && !parsed`; otherwise `write(merged)`.
    /// The decision is independent of install vs removal intent: writing over
    /// a file that exists but could not be parsed is never safe.
    static func decide(
        fileExists: Bool, parsed: Bool, merged: [String: Any]
    ) -> ClaudeHookWriteDecision {
        guard !(fileExists && !parsed) else { return .abort }
        return .write(merged)
    }
}
