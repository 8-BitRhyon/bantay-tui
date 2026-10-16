import Foundation

/// Writes OpenCode decision files for the bantay-opencode plugin.
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
    static func writeDecision(paneId: String, approve: Bool, choiceIndex: Int? = nil) -> Bool {
        guard isOpenCodePane(paneId) else { return false }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI/opencode-decisions", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var payload: [String: Any] = [
                "response": approve,
                "ts": Date().timeIntervalSince1970,
            ]
            if let choiceIndex {
                payload["choice"] = choiceIndex
            }
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
