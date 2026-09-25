#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @MainActor
    @Suite("AgentEventManager event parsing and roster management", .serialized)
    struct AgentEventManagerTests {
        private func withTempFile(
            _ body: (URL, AgentEventManager) throws -> Void
        ) throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-tui-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("agent-events.jsonl")
            try Data().write(to: file, options: [.atomic])
            let manager = AgentEventManager(eventsFileURL: file, capture: false)
            defer { manager.stop() }
            try body(file, manager)
        }

        private func write(_ lines: [String], to file: URL) throws {
            guard !lines.isEmpty else {
                try Data().write(to: file, options: [.atomic])
                return
            }
            let text = lines.joined(separator: "\n") + "\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        private func append(_ line: String, to file: URL) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(Data((line + "\n").utf8))
        }

        private func event(
            _ type: String,
            title: String? = nil,
            paneId: String? = nil,
            variance: String? = nil,
            choices: [String]? = nil
        ) -> String {
            let titleJSON = title.map { "\"title\":\"\($0)\"" } ?? "\"title\":null"
            let paneJSON = paneId.map { "\"paneId\":\"\($0)\"" } ?? "\"paneId\":null"
            let varianceJSON = variance.map { "\"variance\":\"\($0)\"" } ?? "\"variance\":null"
            let choicesJSON: String
            if let choices {
                let items = choices.map { "\"\($0)\"" }.joined(separator: ",")
                choicesJSON = "\"choices\":[\(items)]"
            } else {
                choicesJSON = "\"choices\":null"
            }
            return
                "{\"source\":\"herdr\",\"type\":\"\(type)\",\(titleJSON),\"message\":null,\(paneJSON),\"workspaceId\":null,\(varianceJSON),\(choicesJSON)}"
        }

        private func agent(_ name: String, _ status: String, pane: String) -> HerdrAgentInfo {
            HerdrAgentInfo(
                agent: name,
                agentStatus: status,
                paneId: pane,
                workspaceId: String(pane.split(separator: ":").first ?? ""),
                terminalTitle: "\(name) | \(status)",
                cwd: nil,
                agentSession: nil)
        }

        @Test("pre-existing events are skipped on launch")
        func preExistingEventsSkippedOnLaunch() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-tui-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("agent-events.jsonl")
            let text = event("completed", title: "old") + "\n"
            try text.write(to: file, atomically: true, encoding: .utf8)

            let manager = AgentEventManager(eventsFileURL: file, capture: false)
            defer { manager.stop() }
            manager.poll()
            #expect(manager.currentEvent == nil)
        }

        @Test("appended events are shown in order")
        func appendedEventsShownInOrder() throws {
            try withTempFile { file, manager in
                try append(event("progress", title: "working"), to: file)
                manager.poll()
                #expect(manager.currentEvent?.kind == .progress)
                #expect(manager.currentEvent?.title == "working")

                try append(event("completed", title: "done"), to: file)
                manager.poll()
                #expect(manager.currentEvent?.kind == .completed)
            }
        }

        @Test("duplicate active event is ignored")
        func duplicateActiveEventIgnored() throws {
            try withTempFile { file, manager in
                try append(event("progress", title: "working", paneId: "p1"), to: file)
                manager.poll()
                #expect(manager.currentEvent?.kind == .progress)

                try append(event("progress", title: "still working", paneId: "p1"), to: file)
                manager.poll()
                #expect(manager.currentEvent?.title == "working")

                try append(event("completed", title: "done", paneId: "p1"), to: file)
                manager.poll()
                #expect(manager.currentEvent?.kind == .completed)
            }
        }

        @Test("clear dismisses current event")
        func clearDismissesCurrentEvent() throws {
            try withTempFile { file, manager in
                try append(event("access_request", title: "approve me", paneId: "p2"), to: file)
                manager.poll()
                #expect(manager.currentEvent?.kind == .accessRequest)

                try append(event("clear"), to: file)
                manager.poll()
                #expect(manager.currentEvent == nil)
            }
        }

        @Test("approval variance parsed from event file")
        func approvalVarianceParsedFromEventFile() throws {
            try withTempFile { file, manager in
                try append(
                    event(
                        "access_request",
                        title: "Pick one",
                        paneId: "p1",
                        variance: "choices",
                        choices: ["Read file", "Write file", "Exit"]),
                    to: file)
                manager.poll()

                let ev = manager.currentEvent
                #expect(ev?.kind == .accessRequest)
                #expect(ev?.variance == .choices)
                #expect(ev?.choices == ["Read file", "Write file", "Exit"])
                #expect(ev?.effectiveVariance == .choices)
            }
        }

        @Test("multi-select variance parsed from event file")
        func multiSelectVarianceParsedFromEventFile() throws {
            try withTempFile { file, manager in
                try append(
                    event(
                        "access_request",
                        title: "Select all",
                        paneId: "p2",
                        variance: "multi",
                        choices: ["option-a", "option-b", "option-c"]),
                    to: file)
                manager.poll()

                let ev = manager.currentEvent
                #expect(ev?.kind == .accessRequest)
                #expect(ev?.variance == .multi)
                #expect(ev?.choices?.count == 3)
            }
        }

        @Test("yes-no variance defaults when absent")
        func yesNoVarianceDefaultsWhenAbsent() throws {
            try withTempFile { file, manager in
                try append(event("access_request", title: "Approve?", paneId: "p3"), to: file)
                manager.poll()

                let ev = manager.currentEvent
                #expect(ev?.kind == .accessRequest)
                #expect(ev?.variance == nil)
                #expect(ev?.choices == nil)
                #expect(ev?.effectiveVariance == .yesNo)
            }
        }

        @Test("truncation resets offset and reads new events")
        func truncationResetsOffsetAndReadsNewEvents() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-tui-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let text =
                event("completed", title: "a-very-long-title-that-makes-the-file-big-1234567890")
                + "\n"
            try text.write(to: file, atomically: true, encoding: .utf8)

            let manager = AgentEventManager(eventsFileURL: file, capture: false)
            defer { manager.stop() }
            manager.poll()
            #expect(manager.currentEvent == nil)

            try write([event("progress", title: "new")], to: file)
            manager.poll()
            #expect(manager.currentEvent?.kind == .progress)
        }

        @Test("partial line is buffered until newline")
        func partialLineBufferedUntilNewline() throws {
            try withTempFile { file, manager in
                let handle = try FileHandle(forWritingTo: file)
                handle.write(Data(event("progress", title: "working").utf8))
                try? handle.close()

                manager.poll()
                #expect(manager.currentEvent == nil)

                let closer = try FileHandle(forWritingTo: file)
                _ = try? closer.seekToEnd()
                closer.write(Data("\n".utf8))
                try? closer.close()

                manager.poll()
                #expect(manager.currentEvent?.kind == .progress)
            }
        }

        @Test("invalid lines are skipped")
        func invalidLinesSkipped() throws {
            try withTempFile { file, manager in
                try append("not json at all", to: file)
                try append(event("completed", title: "valid"), to: file)
                manager.poll()

                #expect(manager.currentEvent?.kind == .completed)
            }
        }

        @Test("herdr status mapping")
        func herdrStatusMapping() {
            #expect(AgentEventManager.kind(for: "blocked") == .accessRequest)
            #expect(AgentEventManager.kind(for: "working") == .progress)
            #expect(AgentEventManager.kind(for: "done") == .completed)
            #expect(AgentEventManager.kind(for: "running") == .started)
            #expect(AgentEventManager.kind(for: "idle") == .idle)
            #expect(AgentEventManager.kind(for: "unknown") == nil)
            #expect(AgentEventManager.kind(for: "") == nil)
        }

        @Test("herdr severity ordering")
        func herdrSeverityOrdering() {
            let blocked = AgentEventManager.severity(of: .accessRequest)
            let done = AgentEventManager.severity(of: .completed)
            let working = AgentEventManager.severity(of: .progress)
            let idle = AgentEventManager.severity(of: .idle)
            #expect(blocked > done)
            #expect(done > working)
            #expect(working > AgentEventManager.severity(of: .waiting))
            #expect(idle < AgentEventManager.severity(of: .waiting))
        }

        @Test("herdr snapshot builder")
        func herdrSnapshotBuilder() {
            let ag = HerdrAgentInfo(
                agent: "kilo",
                agentStatus: "blocked",
                paneId: "w3:p3",
                workspaceId: "w3",
                terminalTitle: "Kilo CLI | Working",
                cwd: "/Users/runner/work/bantay-tui/bantay-tui",
                agentSession: nil)
            let snapshot = AgentEventManager.snapshot(for: ag)
            #expect(snapshot?.source == "kilo")
            #expect(snapshot?.kind == .accessRequest)
            #expect(snapshot?.paneId == "w3:p3")
            #expect(snapshot?.workspaceId == "w3")
            #expect(snapshot?.title == "Kilo CLI | Working")
            #expect(snapshot?.id == "w3:p3")
        }

        @Test("pi blocked maps to waiting not access request")
        func piBlockedMapsToWaiting() {
            let ag = HerdrAgentInfo(
                agent: "pi",
                agentStatus: "blocked",
                paneId: "w1:p1",
                workspaceId: "w1",
                terminalTitle: "pi | Working",
                cwd: "/Users/runner/work/bantay-tui/bantay-tui",
                agentSession: nil)
            let snapshot = AgentEventManager.snapshot(for: ag)
            #expect(snapshot?.kind == .waiting)
            #expect(AgentEventManager.kind(for: "blocked", agent: "pi") == .waiting)
            #expect(AgentEventManager.kind(for: "blocked", agent: "kilo") == .accessRequest)
        }

        @Test("first poll emits working event")
        func firstPollEmitsWorkingEvent() {
            var seen: [String: AgentEventKind] = [:]
            let result = AgentEventManager.update(
                from: [agent("kilo", "working", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)

            #expect(result.events.map(\.kind) == [.progress])
            #expect(result.events.first?.playSound == true)
            #expect(result.events.first?.persistent == true)
            #expect(result.roster.map(\.source) == ["kilo"])
        }

        @Test("same state does not re-emit")
        func sameStateDoesNotReemit() {
            var seen: [String: AgentEventKind] = [:]
            let first = AgentEventManager.update(
                from: [agent("kilo", "working", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)
            let second = AgentEventManager.update(
                from: [agent("kilo", "working", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: first.events.first)

            #expect(second.events.isEmpty)
        }

        @Test("transition emits access request")
        func transitionEmitsAccessRequest() {
            var seen: [String: AgentEventKind] = [:]
            _ = AgentEventManager.update(
                from: [agent("kilo", "working", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)
            let second = AgentEventManager.update(
                from: [agent("kilo", "blocked", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)

            #expect(second.events.map(\.kind) == [.accessRequest])
        }

        @Test("idle is roster only")
        func idleIsRosterOnly() {
            var seen: [String: AgentEventKind] = [:]
            let result = AgentEventManager.update(
                from: [agent("kilo", "idle", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)

            #expect(result.events.isEmpty)
            #expect(result.roster.map(\.kind) == [.idle])
        }

        @Test("unknown status excluded")
        func unknownStatusExcluded() {
            var seen: [String: AgentEventKind] = [:]
            let result = AgentEventManager.update(
                from: [agent("kilo", "unknown", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)

            #expect(result.events.isEmpty)
            #expect(result.roster.isEmpty)
        }

        @Test("done is not persistent")
        func doneIsNotPersistent() {
            var seen: [String: AgentEventKind] = [:]
            let result = AgentEventManager.update(
                from: [agent("kilo", "done", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)

            #expect(result.events.first?.kind == .completed)
            #expect(result.events.first?.persistent == false)
        }

        @Test("roster sorted by severity")
        func rosterSortedBySeverity() {
            var seen: [String: AgentEventKind] = [:]
            let result = AgentEventManager.update(
                from: [
                    agent("kilo", "working", pane: "w3:p3"),
                    agent("freebuff", "blocked", pane: "w3:p4"),
                    agent("kilo2", "done", pane: "w3:p5"),
                ],
                lastSeenKinds: &seen,
                current: nil)

            #expect(result.roster.map(\.kind) == [.accessRequest, .completed, .progress])
        }

        @Test("empty agents clears stale roster and persistent event")
        func emptyAgentsClearsStaleRoster() {
            var seen: [String: AgentEventKind] = [:]
            let shown = AgentEvent(
                source: "kilo",
                kind: .progress,
                title: nil,
                message: nil,
                paneId: "w3:p3",
                workspaceId: "w3",
                variance: nil,
                choices: nil,
                playSound: true,
                persistent: true)

            let result = AgentEventManager.update(from: [], lastSeenKinds: &seen, current: shown)

            #expect(result.events.map(\.kind) == [.clear])
            #expect(result.roster.isEmpty)
        }

        @Test("vanished shown agent falls back silently")
        func vanishedShownAgentFallsBackSilently() {
            var seen: [String: AgentEventKind] = [:]
            let first = AgentEventManager.update(
                from: [
                    agent("kilo", "blocked", pane: "w3:p3"),
                    agent("freebuff", "working", pane: "w3:p4"),
                ],
                lastSeenKinds: &seen,
                current: nil)
            #expect(first.events.map(\.kind) == [.progress, .accessRequest])
            let shown = first.events.last!

            let second = AgentEventManager.update(
                from: [agent("freebuff", "working", pane: "w3:p4")],
                lastSeenKinds: &seen,
                current: shown)

            #expect(second.events.map(\.kind) == [.clear, .progress])
            #expect(second.events.last?.source == "freebuff")
            #expect(second.events.last?.playSound == false)
        }

        @Test("same state reshows when current nil")
        func sameStateReshowsWhenCurrentNil() {
            var seen: [String: AgentEventKind] = [:]
            _ = AgentEventManager.update(
                from: [agent("kilo", "working", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)
            let result = AgentEventManager.update(
                from: [agent("kilo", "working", pane: "w3:p3")],
                lastSeenKinds: &seen,
                current: nil)

            #expect(result.events.map(\.kind) == [.progress])
            #expect(result.events.first?.playSound == false)
        }

        @Test("worst state wins when multiple agents change")
        func worstStateWinsWhenMultipleAgentsChange() {
            var seen: [String: AgentEventKind] = [:]
            let result = AgentEventManager.update(
                from: [
                    agent("kilo", "blocked", pane: "w3:p3"),
                    agent("freebuff", "done", pane: "w3:p4"),
                ],
                lastSeenKinds: &seen,
                current: nil)

            #expect(result.events.map(\.kind) == [.completed, .accessRequest])
            #expect(result.events.last?.kind == .accessRequest)
        }

        @Test("sound cooldown suppresses rapid repeats per source and kind")
        func soundCooldownSuppressesRapidRepeats() throws {
            try withTempFile { _, manager in
                let first = AgentEvent(
                    source: "kilo", kind: .progress, title: "t", message: nil,
                    paneId: nil, workspaceId: nil, variance: nil, choices: nil,
                    playSound: true, persistent: true)
                let sameAgain = AgentEvent(
                    source: "kilo", kind: .progress, title: "t2", message: nil,
                    paneId: nil, workspaceId: nil, variance: nil, choices: nil,
                    playSound: true, persistent: true)
                let otherSource = AgentEvent(
                    source: "freebuff", kind: .progress, title: "t", message: nil,
                    paneId: nil, workspaceId: nil, variance: nil, choices: nil,
                    playSound: true, persistent: true)

                #expect(manager.shouldPlaySound(for: first))
                #expect(!manager.shouldPlaySound(for: sameAgain))
                #expect(manager.shouldPlaySound(for: otherSource))
            }
        }

        @Test("approval variance decoding")
        func approvalVarianceDecoding() {
            #expect(ApprovalVariance(rawValue: "yes-no") == .yesNo)
            #expect(ApprovalVariance(rawValue: "choices") == .choices)
            #expect(ApprovalVariance(rawValue: "multi") == .multi)
            #expect(ApprovalVariance(rawValue: "bogus") == nil)
        }

        @Test("effective variance defaults to yes-no")
        func effectiveVarianceDefaultsToYesNo() {
            let nilVariance = AgentEvent(
                source: "kilo", kind: .accessRequest, title: nil, message: nil,
                paneId: nil, workspaceId: nil, variance: nil, choices: nil,
                playSound: true, persistent: true)
            #expect(nilVariance.effectiveVariance == .yesNo)

            let explicit = AgentEvent(
                source: "kilo", kind: .accessRequest, title: nil, message: nil,
                paneId: nil, workspaceId: nil, variance: .multi, choices: nil,
                playSound: true, persistent: true)
            #expect(explicit.effectiveVariance == .multi)
        }
    }
#endif
