import Foundation
import SQLite3

/// Read-only view over Antigravity's CLI/hub conversation registry.
///
/// The hub persists one row per conversation in
/// `~/.gemini/antigravity/conversation_summaries.db`. The row carries the
/// live run status, the subagent role, the parent conversation, the nesting
/// depth, and the workspace. The Antigravity webview builds its active agent
/// list from the same fields (`notFullyIdle`, `parentConversationId`,
/// `subagentSpec`, `waitingSteps`), so this is the authoritative local
/// source for individual agent activity.
///
/// The table is live WAL data. It must be opened with `mode=ro` so SQLite
/// reads the WAL; `immutable=1` sees only the stale checkpoint.
enum AntigravitySummaryStore {
    struct Agent: Equatable, Sendable {
        let id: String
        let title: String?
        let preview: String?
        let stepCount: Int
        let workspacePath: String?
        let status: String
        let agentName: String?
        let parentID: String?
        let depth: Int
        let notFullyIdle: Bool
        let killed: Bool
        let conversationPath: String

        var isWorking: Bool {
            !killed && (notFullyIdle || status == "CASCADE_RUN_STATUS_RUNNING")
        }

        /// Short row label: the conversation title for a root chat, the
        /// humanized subagent role for a child, or the source name.
        var label: String {
            if let title, !title.isEmpty { return title }
            if let agentName, !agentName.isEmpty { return Self.humanize(agentName) }
            return "Antigravity"
        }

        private static func humanize(_ raw: String) -> String {
            let words = raw.split(separator: "_").map(String.init)
            guard let first = words.first else { return raw }
            let rest = words.dropFirst().map { $0.lowercased() }
            return ([first.capitalized] + rest).joined(separator: " ")
        }
    }

    static func databaseURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(
                ".gemini/antigravity/conversation_summaries.db")
    }

    /// Active conversations: the same set the Antigravity workbench calls
    /// active. Parents stay active while a child runs (`not_fully_idle`).
    static func activeAgents(
        home: String = NSHomeDirectory(), limit: Int = 8
    ) -> [Agent] {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = "mode=ro"
        guard let uri = components?.string else { return [] }

        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
                == SQLITE_OK,
            let handle
        else {
            if handle != nil { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)

        let sql =
            "SELECT conversation_id, title, preview, step_count, workspace_uris,"
            + " status, agent_name, parent_conversation_id, nesting_depth,"
            + " not_fully_idle, killed"
            + " FROM conversation_summaries"
            + " WHERE killed = 0"
            + " AND (not_fully_idle = 1 OR status = 'CASCADE_RUN_STATUS_RUNNING')"
            + " ORDER BY nesting_depth ASC, last_modified_time DESC"
            + " LIMIT \(max(limit, 1))"
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
            let stmt
        else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var agents: [Agent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(stmt, 0), !id.isEmpty else { continue }
            let workspace = workspacePath(from: text(stmt, 4))
            let depth = Int(sqlite3_column_int(stmt, 8))
            let agent = Agent(
                id: id,
                title: clean(text(stmt, 1)),
                preview: clean(text(stmt, 2)),
                stepCount: Int(sqlite3_column_int(stmt, 3)),
                workspacePath: workspace,
                status: text(stmt, 5) ?? "",
                agentName: clean(text(stmt, 6)),
                parentID: clean(text(stmt, 7)),
                depth: depth,
                notFullyIdle: sqlite3_column_int(stmt, 9) != 0,
                killed: sqlite3_column_int(stmt, 10) != 0,
                conversationPath: URL(fileURLWithPath: home)
                    .appendingPathComponent(
                        ".gemini/antigravity/conversations/\(id).db"
                    )
                    .path)
            if agent.isWorking { agents.append(agent) }
        }
        return agents
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
            let raw = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: raw)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func workspacePath(from raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
            let uris = try? JSONSerialization.jsonObject(with: data) as? [String],
            let first = uris.first,
            let url = URL(string: first)
        else { return nil }
        return url.path
    }
}
