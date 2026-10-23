#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @Suite("Redesign phase 1 foundations")
    struct RedesignPhase1Tests {
        private func snapshot(
            id: String, source: String, kind: AgentEventKind, title: String? = nil,
            paneId: String? = nil, workspaceId: String? = nil, cwd: String? = nil
        ) -> AgentSnapshot {
            AgentSnapshot(
                id: id, source: source, kind: kind, title: title, message: nil,
                paneId: paneId, workspaceId: workspaceId, cwd: cwd, variance: nil,
                choices: nil, startedAt: nil, projectContext: nil)
        }

        @Test("raw tool text humanizes")
        func humanizesRawToolText() {
            let status = AgentPresentation.status(
                for: snapshot(
                    id: "1", source: "claude", kind: .progress,
                    title: "spawning process command=git args=[status, --short]",
                    paneId: "w:p", workspaceId: "w", cwd: "/Users/test/proj"))
            #expect(status.headline == "Checking git status")
            #expect(status.tool == "git")
        }

        @Test("destructive commands classify high risk")
        func destructiveRisk() {
            let status = AgentPresentation.status(
                for: snapshot(
                    id: "2", source: "claude", kind: .accessRequest,
                    title: "Bash: rm -rf /tmp/build", paneId: "w:p", workspaceId: "w"))
            #expect(status.risk == .high)
        }

        @Test("subagents group with approval hoisted")
        func subagentGrouping() {
            let groups = AgentPresentation.groupRoster([
                snapshot(
                    id: "a", source: "opencode", kind: .progress, paneId: "w:p1",
                    workspaceId: "w", cwd: "/Users/test/proj"),
                snapshot(
                    id: "b", source: "opencode", kind: .accessRequest,
                    title: "Edit file", paneId: "w:p2", workspaceId: "w",
                    cwd: "/Users/test/proj"),
            ])
            #expect(groups.count == 1)
            #expect(groups.first?.lead.kind == .accessRequest)
            #expect(groups.first?.needsAttention == true)
        }

        @Test("settings routes resolve")
        func settingsRoutes() {
            #expect(SettingsRoute.resolve(cliArgument: "desktop") == .desktop)
            #expect(SettingsRoute.resolve(cliArgument: "approvals") == .approvals)
            #expect(SettingsRoute.resolve(cliArgument: "nope") == nil)
        }

        @Test("opencode ledger adapter")
        func opencodeAdapter() {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-opencode-\(UUID().uuidString)").path
            #expect(OpenCodeUsageAdapter.detect(home: home) == false)
        }

        @Test("desktop HUD gateway route")
        func desktopHudRoute() {
            #expect(ControlGateway.route(method: "strip.hud") == .stripHud)
            #expect(ControlGateway.GatewayRoute.stripCatalog.contains("strip.hud"))
        }

        @Test("approval prompt resolver refuses blind approvals")
        func approvalPromptResolution() {
            let permission = ApprovalPromptResolver.resolve(
                rawTail: """
                    Do you want to proceed?
                    1. Yes
                    2. No
                    """,
                kind: .accessRequest)
            #expect(permission.actionable)
            #expect(permission.choices.count == 2)

            let generic = ApprovalPromptResolver.resolve(
                rawTail: "", fallbackTitle: "blocked", kind: .accessRequest)
            #expect(!generic.actionable)

            let waiting = ApprovalPromptResolver.resolve(
                rawTail: "Which environment?\n1. Staging\n2. Production",
                kind: .waiting)
            #expect(!waiting.actionable)
            #expect(waiting.choices.count == 2)
        }

        @Test("structured roster height grows and caps")
        func rosterHeight() {
            let metrics = IslandMetrics.RosterLayoutMetrics(
                approvalCardCount: 1, workingRowCount: 2, idleRowCount: 1,
                groupCount: 2)
            let height = IslandMetrics.rosterHeight(metrics)
            var expected = IslandMetrics.approvalCardHeight
            expected += IslandMetrics.workingRowHeight * 2
            expected += IslandMetrics.idleRowHeight
            expected += IslandMetrics.sectionHeaderHeight * 2
            #expect(abs(height - expected) < 0.001)
            let size = IslandMetrics.expandedSize(topInset: 47, roster: metrics)
            #expect(size.height <= IslandMetrics.maxExpandedHeight)
        }
    }
#endif
