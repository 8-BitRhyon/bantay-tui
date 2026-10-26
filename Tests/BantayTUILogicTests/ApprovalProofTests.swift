#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    /// Transport stub: confirmed sends succeed or fail on instruction, so the
    /// approval path can be tested without a live multiplexer.
    final class StubPlexerAdapter: PlexerAdapter {
        let kind: PlexerKind
        let confirmedResult: Bool

        init(kind: PlexerKind = .tmux, confirmedResult: Bool = true) {
            self.kind = kind
            self.confirmedResult = confirmedResult
        }

        func listPanes() -> [PaneInfo] { [] }
        func captureTail(paneId: String, lines: Int) async -> String { "" }
        func focusPane(paneId: String) {}
        func sendLine(paneId: String, text: String) {}
        func sendKeys(paneId: String, keys: [String]) {}
        func sendLineConfirmed(paneId: String, text: String) async -> Bool {
            confirmedResult
        }
        func sendKeysConfirmed(paneId: String, keys: [String]) async -> Bool {
            confirmedResult
        }
        func stop(paneId: String) {}
        func attachPane(paneId: String) {}
        func agentPrompt(paneId: String, text: String) async {}
        func captureDiff(cwd: String, pathLimit: Int) async -> String? { nil }
    }

    @MainActor
    @Suite("Approval proof: confirmed sends, receipts, observe-only", .serialized)
    struct ApprovalProofTests {
        private func tempDir() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-approval-proof-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        private func manager(
            receipts: ApprovalReceiptStore, adapter: any PlexerAdapter
        ) throws -> AgentEventManager {
            let dir = try tempDir()
            let file = dir.appendingPathComponent("agent-events.jsonl")
            try Data().write(to: file, options: [.atomic])
            let manager = AgentEventManager(
                eventsFileURL: file, capture: false, receiptStore: receipts)
            manager.activeAdapter = adapter
            return manager
        }

        private func receipts() throws -> (ApprovalReceiptStore, URL) {
            let dir = try tempDir()
            let store = ApprovalReceiptStore(
                fileURL: dir.appendingPathComponent("receipts.jsonl"))
            return (store, dir)
        }

        private func blockedAgent(paneId: String) -> AgentSnapshot {
            AgentSnapshot(
                id: "test-agent", source: "claude", kind: .accessRequest,
                title: "Run tests?", message: nil, paneId: paneId,
                workspaceId: "dev", cwd: nil, variance: .yesNo, choices: nil,
                startedAt: nil, projectContext: nil)
        }

        private func blockedEvent(paneId: String) -> AgentEvent {
            AgentEvent(
                source: "claude", kind: .accessRequest, title: "Run tests?",
                message: nil, paneId: paneId, workspaceId: nil,
                variance: .yesNo, choices: nil, playSound: false, persistent: true)
        }

        // MARK: - Routing: unsupported agents are observe-only

        @Test("mcp panes cannot receive a decision")
        func mcpPanesCannotReceiveDecision() {
            #expect(
                ApprovalRouting.supportsDecision(
                    paneId: "mcp:claude", inputSynthesisEnabled: true) == false)
            if case .observeOnly = ApprovalRouting.route(
                paneId: "mcp:claude", adapterKind: .tmux,
                inputSynthesisEnabled: true, paneAlive: true)
            {
            } else {
                Issue.record("mcp pane must route to observe-only")
            }
        }

        @Test("app panes cannot receive a decision")
        func appPanesCannotReceiveDecision() {
            #expect(
                ApprovalRouting.supportsDecision(
                    paneId: "app:claude", inputSynthesisEnabled: true) == false)
        }

        @Test("empty pane ids cannot receive a decision")
        func emptyPaneIdsCannotReceiveDecision() {
            #expect(
                ApprovalRouting.supportsDecision(
                    paneId: "  ", inputSynthesisEnabled: true) == false)
        }

        @Test("standalone panes follow the input-synthesis gate")
        func standalonePanesFollowInputSynthesisGate() {
            #expect(
                ApprovalRouting.supportsDecision(
                    paneId: "standalone:claude",
                    inputSynthesisEnabled: true) == true)
            #expect(
                ApprovalRouting.supportsDecision(
                    paneId: "standalone:claude",
                    inputSynthesisEnabled: false) == false)
        }

        @Test("multiplexer panes route to their adapter")
        func multiplexerPanesRouteToAdapter() {
            #expect(
                ApprovalRouting.route(
                    paneId: "dev:1.2", adapterKind: .tmux,
                    inputSynthesisEnabled: true, paneAlive: true)
                    == .multiplexer(.tmux))
        }

        @Test("opencode panes route to the decision file")
        func opencodePanesRouteToDecisionFile() {
            #expect(
                ApprovalRouting.route(
                    paneId: "opencode:proj", adapterKind: .herdr,
                    inputSynthesisEnabled: true, paneAlive: true)
                    == .openCodeDecisionFile)
        }

        // MARK: - Manager: failures never report success

        @Test("mcp approval fails unsupported and keeps the request visible")
        func mcpApprovalFailsUnsupported() async throws {
            let (store, dir) = try receipts()
            defer { try? FileManager.default.removeItem(at: dir) }
            let manager = try manager(
                receipts: store, adapter: StubPlexerAdapter(confirmedResult: true))
            defer { manager.stop() }
            manager.publishEventForTesting(blockedEvent(paneId: "mcp:claude"))
            #expect(manager.pendingApprovals["mcp:claude"]?.actionable == false)
            let outcome = await manager.approve(paneId: "mcp:claude")
            #expect(outcome == .failed(.unsupported))
            #expect(manager.pendingApprovals["mcp:claude"] != nil)
            #expect(store.recent().count == 1)
            #expect(store.recent().first?.outcome == "failed")
        }

        @Test("approval for a dead pane fails without touching transport")
        func deadPaneApprovalFails() async throws {
            let (store, dir) = try receipts()
            defer { try? FileManager.default.removeItem(at: dir) }
            let manager = try manager(
                receipts: store, adapter: StubPlexerAdapter(confirmedResult: true))
            defer { manager.stop() }
            let outcome = await manager.approve(paneId: "gone:9.9")
            #expect(outcome == .failed(.deadPane))
            #expect(store.recent().isEmpty)
        }

        @Test("failed transport keeps the request and writes a failed receipt")
        func failedTransportKeepsRequest() async throws {
            let (store, dir) = try receipts()
            defer { try? FileManager.default.removeItem(at: dir) }
            let manager = try manager(
                receipts: store, adapter: StubPlexerAdapter(confirmedResult: false))
            defer { manager.stop() }
            manager.setAgentsForTesting([blockedAgent(paneId: "dev:1.2")])
            manager.publishEventForTesting(blockedEvent(paneId: "dev:1.2"))
            let outcome = await manager.approve(paneId: "dev:1.2")
            #expect(outcome == .failed(.transport))
            #expect(manager.pendingApprovals["dev:1.2"] != nil)
            let receipt = try #require(store.recent().first)
            #expect(receipt.outcome == "failed")
            #expect(receipt.failure == "transport")
            #expect(receipt.agentAck == "not_available")
        }

        @Test("confirmed transport sends, receipts, and clears the request")
        func confirmedTransportSendsAndReceipts() async throws {
            let (store, dir) = try receipts()
            defer { try? FileManager.default.removeItem(at: dir) }
            let manager = try manager(
                receipts: store, adapter: StubPlexerAdapter(confirmedResult: true))
            defer { manager.stop() }
            manager.setAgentsForTesting([blockedAgent(paneId: "dev:1.2")])
            manager.publishEventForTesting(blockedEvent(paneId: "dev:1.2"))
            let outcome = await manager.approve(paneId: "dev:1.2")
            #expect(outcome == .sent)
            #expect(manager.pendingApprovals["dev:1.2"] == nil)
            let receipt = try #require(store.recent().first)
            #expect(receipt.outcome == "sent")
            #expect(receipt.action == "approve")
            #expect(receipt.agentAck == "not_available")
            #expect(receipt.requestHash.count == 64)
        }

        @Test("empty free text fails without a receipt")
        func emptyFreeTextFails() async throws {
            let (store, dir) = try receipts()
            defer { try? FileManager.default.removeItem(at: dir) }
            let manager = try manager(
                receipts: store, adapter: StubPlexerAdapter(confirmedResult: true))
            defer { manager.stop() }
            let outcome = await manager.sendText(paneId: "dev:1.2", text: "   ")
            #expect(outcome == .failed(.emptyText))
            #expect(store.recent().isEmpty)
        }

        @Test("retries share one idempotency key")
        func retriesShareIdempotencyKey() async throws {
            let (store, dir) = try receipts()
            defer { try? FileManager.default.removeItem(at: dir) }
            let manager = try manager(
                receipts: store, adapter: StubPlexerAdapter(confirmedResult: false))
            defer { manager.stop() }
            manager.setAgentsForTesting([blockedAgent(paneId: "dev:1.2")])
            manager.publishEventForTesting(blockedEvent(paneId: "dev:1.2"))
            // Let approval enrichment settle so both attempts hash the same
            // visible request.
            try await Task.sleep(for: .seconds(1))
            #expect(await manager.approve(paneId: "dev:1.2") == .failed(.transport))
            #expect(await manager.approve(paneId: "dev:1.2") == .failed(.transport))
            let keys = store.recent().map(\.idempotencyKey)
            #expect(keys.count == 2)
            #expect(Set(keys).count == 1)
        }

        // MARK: - Receipts

        @Test("request hashes are stable and 64 hex chars")
        func requestHashesAreStable() {
            let first = ApprovalReceiptStore.requestHash("dev:1.2|run tests?")
            let second = ApprovalReceiptStore.requestHash("dev:1.2|run tests?")
            #expect(first == second)
            #expect(first.count == 64)
            #expect(
                ApprovalReceiptStore.requestHash("dev:1.2|other") != first)
        }

        @Test("receipt store round-trips through JSONL")
        func receiptStoreRoundTrips() throws {
            let (store, dir) = try receipts()
            defer { try? FileManager.default.removeItem(at: dir) }
            store.append(
                ApprovalReceipt(
                    paneId: "dev:1.2", source: "claude", eventKind: "access_request",
                    action: "approve", requestHash: ApprovalReceiptStore.requestHash("x"),
                    idempotencyKey: "key-1", route: "tmux_send_keys", outcome: "sent"))
            let read = store.recent()
            #expect(read.count == 1)
            #expect(read.first?.paneId == "dev:1.2")
            #expect(read.first?.agentAck == "not_available")
        }

        // MARK: - Transport honesty

        @Test("disabled input synthesis cannot approve")
        func disabledInputSynthesisCannotApprove() {
            let previous = StandaloneAgentDispatcher.enableInputSynthesis
            StandaloneAgentDispatcher.enableInputSynthesis = false
            defer { StandaloneAgentDispatcher.enableInputSynthesis = previous }
            #expect(
                StandaloneAgentDispatcher.dispatchApproval(
                    agentName: "claude", approved: true) == false)
        }

        @Test("missing tmux binary reports transport failure")
        func missingTmuxBinaryReportsFailure() async {
            let adapter = TmuxAdapter(tmuxBinPath: "bantay-no-such-binary-xyz")
            #expect(
                await adapter.sendKeysConfirmed(paneId: "dev:1.2", keys: ["y"])
                    == false)
        }
    }
#endif
