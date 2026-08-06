import Foundation

/// Pure mapping layer for the universal hook SDK (plan 017 W4).
///
/// Mirrors `ClaudeHookInstaller`'s discipline: no file I/O, non-destructive
/// merge/remove that preserves foreign hooks, and payload mapping from
/// tool-specific hook JSON to the canonical `AgentEventPayload` shape. The
/// only runtime surface is the generic emitter (`scripts/hook-emit.sh`),
/// which resolves the UDS ingest socket + token itself; config-file
/// installers for each verified tool are thin adapters fed by these pure
/// functions.
enum HookSdk {
    /// Agent families the SDK knows. Only `aider` and `codex` expose a
    /// verified hook mechanism; `windsurf` and `cursor` have no stable hook
    /// surface documented, so they fall back to the standalone scan +
    /// transcript tailing and the W2 emit recipe — a hook is never
    /// fabricated for them.
    enum AgentTool: String, CaseIterable {
        case aider, codex, windsurf, cursor
    }

    /// Repo-relative path to the generic emitter script.
    static let emitterPath = "scripts/hook-emit.sh"

    /// Codex CLI hook events Bantay installs into `~/.codex/config.toml`
    /// (`[hooks.<Event>]`). Verified against the installed config on this
    /// machine: `[features] hooks = true` and a hook entry is a single
    /// `command = ["sh", "-lc", …]` array.
    static let codexHookEvents: [String] = ["PromptStart", "PromptFinish"]

    /// True when the tool has a verified hook mechanism Bantay can install
    /// into. aider + codex: verified. windsurf + cursor: false — no stable
    /// hook surface documented (they rely on the standalone scan instead).
    static func isHookVerified(_ tool: AgentTool) -> Bool {
        switch tool {
        case .aider, .codex: return true
        case .windsurf, .cursor: return false
        }
    }

    /// The `source` value the canonical payload carries for a tool.
    static func sourceName(for tool: AgentTool) -> String { tool.rawValue }

    /// The command a verified tool's hook runs to signal Bantay, or nil for
    /// tools without a verified hook surface. Both verified tools emit
    /// through `scripts/hook-emit.sh`, which resolves the UDS ingest socket
    /// and token itself; `port` is reserved for a future HTTP-ingest variant
    /// and `token` — when supplied — is embedded as `BANTAY_INGEST_TOKEN`
    /// so the hook carries the secret explicitly.
    static func hookCommand(for tool: AgentTool, port: Int, token: String?) -> String? {
        guard isHookVerified(tool) else { return nil }
        let envPrefix = token.map { "BANTAY_INGEST_TOKEN=\($0) " } ?? ""
        switch tool {
        case .aider:
            // Aider's hook config-file surface is NOT verified against an
            // installed aider (config install is P2). The command shape is
            // the documented, testable emitter invocation a post-edit /
            // pre-commit script would run.
            return "\(envPrefix)\(emitterPath) --source aider --type progress --title \"aider\""
        case .codex:
            // Codex CLI hooks run with $CODEX_HOOK_EVENT set: PromptStart
            // signals work, PromptFinish signals completion. Coarse by
            // design — finer per-payload mapping lives in
            // `mapToEventPayload`.
            return
                "\(envPrefix)\(emitterPath) --source codex --type \"$([ \"$CODEX_HOOK_EVENT\" = \"PromptStart\" ] && echo progress || echo completed)\" --title \"codex\""
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
        case .windsurf, .cursor: return nil
        }
    }

    /// Merge Bantay's hooks into an existing tool config dictionary,
    /// preserving all unrelated keys and foreign hooks. Mirrors
    /// ClaudeHookInstaller's guard: a `hooks` value that exists but is not a
    /// `[String: Any]` (a String, an Array, any foreign shape) is opaque and
    /// returned unchanged. Unverified tools are never given hooks.
    static func mergeHooks(
        existing: [String: Any], tool: AgentTool, port: Int
    ) -> [String: Any] {
        guard isHookVerified(tool) else { return existing }
        switch tool {
        case .codex:
            return mergeCodexHooks(existing: existing, port: port)
        case .aider:
            // Aider's config-file install is P2 (hook section unverified);
            // the merge is deliberately a non-destructive identity.
            return existing
        case .windsurf, .cursor:
            return existing
        }
    }

    /// Remove only Bantay-owned hooks from a tool config dictionary. Foreign
    /// hooks that share an event are preserved, entries that become
    /// hook-less are dropped, and an empty `hooks` key is removed entirely.
    /// Unverified tools are returned unchanged.
    static func removingHooks(from settings: [String: Any], tool: AgentTool) -> [String: Any] {
        guard isHookVerified(tool) else { return settings }
        switch tool {
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
        case .aider, .windsurf, .cursor:
            return settings
        }
    }

    /// Pure mirror of `hook-emit.sh`'s required-args contract: `--source`,
    /// `--type` and `--title` are each required with a value; any usage
    /// error exits 2. Returns the exit code for the argument vector.
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
            // config.toml allows one command per event table, so Bantay's
            // entry is only added when the slot is unclaimed — a foreign
            // command for the same event is preserved untouched, and a
            // re-install never duplicates.
            guard hooks[event] == nil else { continue }
            hooks[event] = codexHookEntry(port: port)
        }
        merged["hooks"] = hooks
        return merged
    }

    /// One `[hooks.<Event>]` entry for config.toml: a single `command` array
    /// running the emitter via `sh -lc` (the same wrapper Codex's own
    /// examples use).
    private static func codexHookEntry(port: Int) -> [String: Any] {
        guard let command = hookCommand(for: .codex, port: port, token: nil) else {
            return [:]
        }
        return ["command": ["sh", "-lc", command]]
    }

    /// True when a config.toml hook entry's command invokes Bantay's emitter
    /// for codex — matched by command shape, never by foreign content.
    static func isOwnedCodexEntry(_ entry: [String: Any]) -> Bool {
        guard let commandList = entry["command"] as? [String] else { return false }
        return commandList.contains { isBantayCommand($0, tool: .codex) }
    }

    /// True when a hook command string invokes Bantay's emitter for `tool`.
    static func isBantayCommand(_ command: String, tool: AgentTool) -> Bool {
        guard isHookVerified(tool) else { return false }
        return command.contains("\(emitterPath) --source \(tool.rawValue)")
    }

    // MARK: - aider hooks (documented shape; config install is P2)

    /// Maps the documented aider hook payload shape (`event` + `path`) to a
    /// canonical payload. The exact hook config-file surface is not verified
    /// against an installed aider (P2), so this maps the shape the emitter
    /// recipe documents.
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

    /// The canonical AgentEventPayload shape (W2): `v` + the fields the
    /// ingest validator decodes. Nulls are explicit so the emitted line
    /// matches the wire example and optional fields decode identically.
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
