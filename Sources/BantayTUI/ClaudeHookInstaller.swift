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

    /// Merge the Bantay hooks into an existing settings dictionary, preserving
    /// all unrelated keys and any pre-existing hook entries.
    static func mergedSettings(existing: [String: Any], port: Int) -> [String: Any] {
        var merged = existing
        var hooks = (existing["hooks"] as? [String: Any]) ?? [:]
        let bantayHooks = (hooksSection(port: port)["hooks"] as? [String: Any]) ?? [:]
        for (event, entries) in bantayHooks {
            hooks[event] = entries
        }
        merged["hooks"] = hooks
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
