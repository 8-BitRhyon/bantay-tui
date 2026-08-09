import Foundation

/// Writes openCode decision files for the bantay-opencode.js plugin. When the
/// user approves/denies an opencode agent on the notch, the action must reach
/// the opencode server — but opencode is a separate process with no reverse
/// channel, so Bantay drops a small JSON file in
/// `~/Library/Application Support/Bantay-TUI/opencode-decisions/<project>.json`
/// that the plugin polls and answers via the opencode SDK client.
enum OpenCodeActionWriter {
    /// The pane id prefix Bantay uses for opencode agents ("opencode:<project>").
    static let panePrefix = "opencode:"

    /// Whether a pane id refers to an opencode agent (handled by the plugin,
    /// not by herdr keystrokes).
    static func isOpenCodePane(_ paneId: String) -> Bool {
        paneId.hasPrefix(panePrefix)
    }

    /// The project key (everything after the prefix) for a pane id.
    static func projectKey(for paneId: String) -> String {
        String(paneId.dropFirst(panePrefix.count))
    }

    /// Drop a decision file the plugin will pick up. Returns false on write
    /// failure. Best-effort: the plugin polls and retries; a failed write is
    /// logged, never fatal.
    @discardableResult
    static func writeDecision(paneId: String, approve: Bool) -> Bool {
        guard isOpenCodePane(paneId) else { return false }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI/opencode-decisions", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "response": approve,
                "ts": Date().timeIntervalSince1970,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(
                to: dir.appendingPathComponent("\(projectKey(for: paneId)).json"),
                options: .atomic)
            return true
        } catch {
            NSLog(
                "bantay: opencode decision write failed for %@: %@", paneId,
                String(describing: error))
            return false
        }
    }
}
