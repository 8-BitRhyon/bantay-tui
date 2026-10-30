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

        @Test("boxed OpenCode question keeps its choices")
        func boxedOpenCodeQuestion() {
            let single = ApprovalPromptResolver.resolve(
                rawTail: """
                    ┃  Pick a fruit
                    ┃
                    ┃  Which fruit?
                    ┃
                    ┃  1. Apple
                    ┃  2. Banana
                    ┃  3. Cherry
                    ┃  4. Type your own answer
                    ┃
                    ┃  ↑↓ select  enter submit  esc dismiss
                    """,
                kind: .waiting)
            #expect(single.choices == ["Apple", "Banana", "Cherry", "Type your own answer"])
            #expect(single.variance == .choices)

            let multi = ApprovalPromptResolver.resolve(
                rawTail: """
                    ┃  Pick toppings
                    ┃
                    ┃  Which toppings?  Submit
                    ┃
                    ┃  1. [ ] Cheese
                    ┃  2. [ ] Olives
                    ┃  3. [ ] Mushrooms
                    ┃
                    ┃  ⇆ tab  ↑↓ select  enter toggle  esc dismiss
                    """,
                kind: .waiting)
            #expect(multi.choices == ["Cheese", "Olives", "Mushrooms"])
            #expect(multi.variance == .multi)
        }

        @Test("boxed question descriptions and custom row")
        func boxedQuestionDescriptions() {
            let prompt = ApprovalPromptResolver.resolve(
                rawTail: """
                    ┃  {"title":"Should I execute the audit, and at what scope?","options":[{"value":"phase1"}]}
                    ┃  [bantay] variance=choices choices=4 [Phase 1 | Full] Should I execute the audit, and at what scope?
                    ┃  Questions
                    ┃
                    ┃  Should I execute the audit, and at what scope?
                    ┃
                    ┃  1. Phase 1 (Recommended)
                    ┃     Remove backpass and firstmate, demote the loops. One commit.
                    ┃  2. Full audit plan
                    ┃     All three phases: 24 skills, 4 rewrites, 4 trims.
                    ┃  3. Report only
                    ┃     Keep the report only. I will make no file changes.
                    ┃  4. Type your own answer
                    ┃  5. Type your own answer
                    ┃
                    ┃  ↑↓ select  enter submit  esc dismiss
                    """,
                kind: .waiting)
            #expect(
                prompt.choices == [
                    "Phase 1 (Recommended)", "Full audit plan", "Report only",
                    "Type your own answer",
                ])
            #expect(prompt.choiceDetails.first?.contains("Remove backpass") == true)
            #expect(prompt.choiceDetails[1].contains("24 skills"))
            #expect(prompt.customChoiceNumber == 4)
            #expect(prompt.detail == "Should I execute the audit, and at what scope?")
            #expect(prompt.variance == .choices)

            let tall = IslandMetrics.notificationCardHeight(
                for: .waiting, choices: prompt.choices,
                details: prompt.choiceDetails, hasFreeText: true)
            let plain = IslandMetrics.notificationCardHeight(for: .waiting)
            #expect(tall > plain + 80)
        }

        @Test("multi-select state and review state survive parsing")
        func multiSelectStateAndReview() {
            let prompt = ApprovalPromptResolver.resolve(
                rawTail: """
                    ┃  Pick B
                    ┃
                    ┃  ❯ 1. [✓] B1
                    ┃    2. [ ] B2
                    ┃    3. [x] B3
                    ┃
                    ┃  ⇆ tab  ↑↓ select  enter toggle  esc dismiss
                    """,
                kind: .waiting)
            #expect(prompt.choices == ["B1", "B2", "B3"])
            #expect(prompt.variance == .multi)
            #expect(prompt.selectedChoices == [1, 3])
            #expect(prompt.focusedChoice == 1)

            let review = """
                ┃  Sequence check
                ┃
                ┃  Pick A  Pick B  Pick C  Submit
                ┃
                ┃  Pick A: A2
                ┃  Pick B: B1, B3
                ┃  Pick C: C2
                ┃
                ┃  ⇆ tab  enter submit  esc dismiss
                """
            #expect(ApprovalPromptResolver.isReviewState(review))
            #expect(!ApprovalPromptResolver.isReviewState("Which one?\n1. Yes\n2. No"))
        }

        @Test("generic checkbox prompt keeps every option")
        func genericCheckboxPrompt() {
            let prompt = ApprovalPromptResolver.resolve(
                rawTail: """
                    Pick items
                    ❯ 1. [ ] Alpha
                      2. [ ] Beta
                      3. [ ] Gamma
                      4. [ ] Delta
                    up/down select  space toggle  enter confirm
                    """,
                kind: .waiting)
            #expect(prompt.choices == ["Alpha", "Beta", "Gamma", "Delta"])
            #expect(prompt.variance == .multi)
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
