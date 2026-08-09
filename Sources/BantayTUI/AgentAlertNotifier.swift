import Foundation

/// ntfy.sh push notifications for agent-state events that need your
/// attention even when you're away from the terminal: blocked / approval
/// requests and completions. Pure request-building is split from the POST so
/// the harness can test the payload; posting is a detached fire-and-forget
/// task so a slow/offline ntfy server never blocks the island.
enum AgentAlertNotifier {
    /// Redact a title for push: titles carry tool commands / file paths
    /// (Claude hook sends `tool_input.command`), which shouldn't be stored
    /// on a third-party ntfy server in full. Truncate and strip $HOME.
    static func redactedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        var t = title.replacingOccurrences(
            of: NSHomeDirectory(), with: "~", options: [.anchored])
        if t.count > 120 {
            t = String(t.prefix(120)) + "…"
        }
        return t
    }

    /// ntfy message body for an agent event (title redacted).
    static func messageBody(
        source: String, kind: AgentEventKind, title: String?
    ) -> String {
        let safeTitle = redactedTitle(title)
        switch kind {
        case .accessRequest, .waiting:
            return "\(source) needs your approval\(safeTitle.map { ": \($0)" } ?? "")"
        case .failed:
            return "\(source) failed\(safeTitle.map { ": \($0)" } ?? "")"
        case .completed:
            return "\(source) finished\(safeTitle.map { ": \($0)" } ?? "")"
        default:
            return "\(source): \(kind.label)\(safeTitle.map { ": \($0)" } ?? "")"
        }
    }

    /// ntfy topic / server from config; nil when push is disabled.
    @MainActor
    static func target() -> (topic: String, server: String)? {
        let config = NotchHUDConfig.shared
        guard config.ntfyEnabled else { return nil }
        return (config.ntfyTopic, config.ntfyServer)
    }

    /// Push a notification for `kind`, if a topic is configured and the kind
    /// is worth pinging for (blocked/approval/failed/completed). Honors quiet
    /// hours for sound-bearing events; the push itself is non-blocking.
    @MainActor
    static func notify(
        source: String, kind: AgentEventKind, title: String?,
        paneId: String? = nil
    ) {
        // Only kinds worth a phone ping — progress/started/idle would turn
        // a busy agent into a notification stream.
        guard
            kind == .accessRequest || kind == .waiting
                || kind == .failed || kind == .completed
        else {
            return
        }
        guard let (topic, server) = target() else { return }
        let body = messageBody(source: source, kind: kind, title: title)
        let serverURL = server.hasSuffix("/") ? String(server.dropLast()) : server
        var urlString = "\(serverURL)/\(topic)"
        if let paneId, !paneId.isEmpty {
            urlString += "?x-target=\(paneId)"
        }
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("Bantay-TUI", forHTTPHeaderField: "Title")
        request.setValue(
            kind == .accessRequest || kind == .waiting ? "high" : "default",
            forHTTPHeaderField: "Priority")
        if kind == .accessRequest || kind == .waiting {
            request.setValue("rotating_light", forHTTPHeaderField: "Tags")
        } else if kind == .failed {
            request.setValue("warning", forHTTPHeaderField: "Tags")
        } else {
            request.setValue("white_check_mark", forHTTPHeaderField: "Tags")
        }
        request.httpBody = Data(body.utf8)
        Task.detached(priority: .utility) {
            do {
                _ = try await URLSession.shared.data(for: request)
            } catch {
                // Best-effort: a failed push is never fatal.
            }
        }
    }
}
