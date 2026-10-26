#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @MainActor
    @Suite("Session history records only attributable sessions", .serialized)
    struct SessionHistoryProofTests {
        private func store() throws -> (SessionHistoryStore, String) {
            let suite = "bantay-proof-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            return (SessionHistoryStore(defaults: defaults), suite)
        }

        private func cleanup(_ suite: String) {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }

        private func manager(store: SessionHistoryStore) throws -> AgentEventManager {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-session-proof-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("agent-events.jsonl")
            try Data().write(to: file, options: [.atomic])
            return AgentEventManager(
                eventsFileURL: file, capture: false, sessionStore: store)
        }

        private func agent(
            paneId: String, title: String? = nil, sessionPath: String? = nil
        ) -> AgentSnapshot {
            AgentSnapshot(
                id: "proof-session", source: "proofagent", kind: .accessRequest,
                title: title, message: nil, paneId: paneId,
                workspaceId: "w9", cwd: nil, variance: nil, choices: nil,
                startedAt: nil, projectContext: nil, sessionPath: sessionPath)
        }

        private func event(
            kind: AgentEventKind, paneId: String, title: String? = "Whatever"
        ) -> AgentEvent {
            AgentEvent(
                source: "proofagent", kind: kind, title: title,
                message: nil, paneId: paneId, workspaceId: nil,
                variance: nil, choices: nil, playSound: false, persistent: true)
        }

        @Test("baseless completed is not recorded as a session")
        func baselessCompletedIsNotRecorded() async throws {
            let (store, suite) = try store()
            defer { cleanup(suite) }
            let manager = try manager(store: store)
            defer { manager.stop() }
            manager.publishEventForTesting(event(kind: .completed, paneId: "w9:p9"))
            #expect(store.sessions.isEmpty)
        }

        @Test("zero-token completed is not recorded as a session")
        func zeroTokenCompletedIsNotRecorded() async throws {
            let (store, suite) = try store()
            defer { cleanup(suite) }
            let manager = try manager(store: store)
            defer { manager.stop() }
            manager.setAgentsForTesting([agent(paneId: "w9:p9")])
            manager.publishEventForTesting(event(kind: .progress, paneId: "w9:p9"))
            manager.publishEventForTesting(event(kind: .completed, paneId: "w9:p9"))
            #expect(store.sessions.isEmpty)
        }

        @Test("failed without baseline keeps its error signal honestly")
        func failedWithoutBaselineKeepsSignal() async throws {
            let (store, suite) = try store()
            defer { cleanup(suite) }
            let manager = try manager(store: store)
            defer { manager.stop() }
            manager.publishEventForTesting(event(kind: .failed, paneId: "w9:p9", title: "Boom"))
            let row = try #require(store.sessions.first)
            #expect(store.sessions.count == 1)
            #expect(row.totalTokens == 0)
            #expect(row.isDelta == false)
        }

        @Test("same-session pair records one row with the best numbers")
        func sameSessionPairRecordsOnce() async throws {
            let (store, suite) = try store()
            defer { cleanup(suite) }
            let manager = try manager(store: store)
            defer { manager.stop() }
            manager.setAgentsForTesting([
                agent(paneId: "w9:p9", title: "Proof Title", sessionPath: "ses_proofpair")
            ])
            manager.setLifetimeCounterForTesting(
                source: "proofagent", tokens: 1000, cost: 0.5)
            manager.publishEventForTesting(event(kind: .progress, paneId: "w9:p9"))
            manager.setLifetimeCounterForTesting(
                source: "proofagent", tokens: 1500, cost: 0.75)
            manager.publishEventForTesting(event(kind: .failed, paneId: "w9:p9", title: "A"))
            manager.setLifetimeCounterForTesting(
                source: "proofagent", tokens: 1900, cost: 0.9)
            manager.publishEventForTesting(event(kind: .failed, paneId: "w9:p9", title: "B"))
            #expect(store.sessions.count == 1)
            #expect(store.sessions.first?.totalTokens == 900)
        }

        @Test("titleless completion falls back to the roster title")
        func titlelessCompletionFallsBack() async throws {
            let (store, suite) = try store()
            defer { cleanup(suite) }
            let manager = try manager(store: store)
            defer { manager.stop() }
            manager.setAgentsForTesting([agent(paneId: "w9:p9", title: "Proof Title")])
            manager.setLifetimeCounterForTesting(
                source: "proofagent", tokens: 1000, cost: 0.5)
            manager.publishEventForTesting(event(kind: .progress, paneId: "w9:p9"))
            manager.setLifetimeCounterForTesting(
                source: "proofagent", tokens: 1500, cost: 0.75)
            manager.publishEventForTesting(event(kind: .completed, paneId: "w9:p9", title: nil))
            let row = try #require(store.sessions.first)
            #expect(row.title == "Proof Title")
            #expect(row.totalTokens == 500)
        }

        @Test("migration quarantines rows from before the metering fix")
        func migrationQuarantinesStaleRows() {
            let stale = AgentSessionRecord(
                agentName: "proofagent", title: "Old", isDelta: true)
            let fresh = AgentSessionRecord(
                agentName: "proofagent", title: "New", isDelta: true,
                buildTag: SessionHistoryStore.currentBuildTag)
            let rows = SessionHistoryStore.rebaselineStale(rows: [stale, fresh])
            #expect(rows[0].isDelta == false)
            #expect(rows[1].isDelta == true)
        }
    }
#endif
