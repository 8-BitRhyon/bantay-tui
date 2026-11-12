#if canImport(Testing)
    import Foundation
    import SQLite3
    import Testing

    @testable import BantayTUI

    private enum AgySummaryFixtureError: Error {
        case sqlite(String)
    }

    private enum AgySummaryFixture {
        static func makeHome() throws -> URL {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-agy-summary-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: true)
            let db = home.appendingPathComponent(
                ".gemini/antigravity/conversation_summaries.db")
            try FileManager.default.createDirectory(
                at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
            var handle: OpaquePointer?
            guard sqlite3_open(db.path, &handle) == SQLITE_OK, let handle else {
                throw AgySummaryFixtureError.sqlite("open")
            }
            let sql = """
                CREATE TABLE conversation_summaries(
                    conversation_id TEXT PRIMARY KEY,
                    title TEXT, preview TEXT, step_count INTEGER,
                    last_modified_time TEXT, workspace_uris TEXT, status TEXT,
                    agent_name TEXT, parent_conversation_id TEXT,
                    nesting_depth INTEGER, not_fully_idle NUMERIC, killed NUMERIC
                );
                INSERT INTO conversation_summaries VALUES(
                    'root', 'Root task', 'Root task', 10,
                    '2026-11-04 23:09:32', '["file:///tmp/bantay-project"]',
                    'CASCADE_RUN_STATUS_IDLE', '', '', 0, 1, 0);
                INSERT INTO conversation_summaries VALUES(
                    'teamwork', '', '', 47,
                    '2026-11-04 23:09:35', '["file:///tmp/bantay-project"]',
                    'CASCADE_RUN_STATUS_IDLE', 'teamwork', 'root', 1, 1, 0);
                INSERT INTO conversation_summaries VALUES(
                    'worker', '', '', 0,
                    '0001-01-01 00:00:00', '["file:///tmp/bantay-project"]',
                    'CASCADE_RUN_STATUS_RUNNING', 'teamwork_worker', 'teamwork', 2, 1, 0);
                INSERT INTO conversation_summaries VALUES(
                    'idle', 'Idle chat', '', 5,
                    '2026-11-04 22:00:00', '["file:///tmp/bantay-project"]',
                    'CASCADE_RUN_STATUS_IDLE', '', '', 0, 0, 0);
                INSERT INTO conversation_summaries VALUES(
                    'killed', 'Killed chat', '', 5,
                    '2026-11-04 22:00:00', '["file:///tmp/bantay-project"]',
                    'CASCADE_RUN_STATUS_RUNNING', '', '', 0, 1, 1);
                """
            let result = sqlite3_exec(handle, sql, nil, nil, nil)
            sqlite3_close(handle)
            guard result == SQLITE_OK else {
                throw AgySummaryFixtureError.sqlite("seed")
            }
            return home
        }
    }

    @Suite("Antigravity summary registry", .serialized)
    struct AntigravitySummaryStoreTests {
        @Test("active rows keep status, role, depth, and workspace")
        func activeRows() throws {
            let home = try AgySummaryFixture.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let agents = AntigravitySummaryStore.activeAgents(home: home.path)
            #expect(agents.count == 3)
            #expect(agents.map(\.id) == ["root", "teamwork", "worker"])
            #expect(agents[0].label == "Root task")
            #expect(agents[1].label == "Teamwork")
            #expect(agents[2].label == "Teamwork worker")
            #expect(agents.allSatisfy { $0.isWorking })
            #expect(agents[2].status == "CASCADE_RUN_STATUS_RUNNING")
            #expect(agents[2].parentID == "teamwork")
            #expect(agents[2].depth == 2)
            #expect(agents[2].workspacePath == "/tmp/bantay-project")
            #expect(agents[2].conversationPath.hasSuffix("/worker.db"))
        }

        @Test("killed and fully idle rows are excluded")
        func excludesInactive() throws {
            let home = try AgySummaryFixture.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let ids = AntigravitySummaryStore.activeAgents(home: home.path).map(\.id)
            #expect(!ids.contains("idle"))
            #expect(!ids.contains("killed"))
        }

        @Test("missing summary database returns no agents")
        func missingDatabase() {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-agy-missing-\(UUID().uuidString)")
            #expect(AntigravitySummaryStore.activeAgents(home: home.path).isEmpty)
        }
    }

    @MainActor
    @Suite("Antigravity roster identity", .serialized)
    struct AntigravityRosterTests {
        private func agent(
            _ title: String, session: String?, cwd: String = "/tmp/project"
        ) -> HerdrAgentInfo {
            HerdrAgentInfo(
                agent: "antigravity",
                agentStatus: "working",
                paneId: nil,
                workspaceId: nil,
                terminalTitle: title,
                cwd: cwd,
                agentSession: session.map {
                    HerdrAgentSession(agent: "antigravity", kind: "path", value: $0)
                })
        }

        @Test("pane-less agents with the same cwd get distinct ids")
        func distinctIDs() {
            let first = AgentEventManager.snapshot(
                for: agent("Root", session: "/tmp/root.db"))
            let second = AgentEventManager.snapshot(
                for: agent("Worker", session: "/tmp/worker.db"))
            #expect(first?.id != second?.id)
        }

        @Test("detected conversations replace the single herdr antigravity row")
        func mergeReplacesHerdrRow() {
            let herdr = [agent("Antigravity", session: nil)]
            let detected = [
                DetectedAgent(
                    pid: 1, name: "antigravity", activity: "Root",
                    isWorking: true, cwd: "/tmp/project",
                    sessionPath: "/tmp/root.db"),
                DetectedAgent(
                    pid: 1, name: "antigravity", activity: "Worker",
                    isWorking: true, cwd: "/tmp/project",
                    sessionPath: "/tmp/worker.db"),
            ]
            let merged = AgentEventManager.shared.mergeStandalone(
                into: herdr, detected: detected)
            #expect(merged.count == 2)
            #expect(
                Set(merged.compactMap { $0.agentSession?.value })
                    == ["/tmp/root.db", "/tmp/worker.db"])
        }
    }
#endif
