import XCTest

@testable import BantayTUI

@MainActor
final class AgentEventManagerTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bantay-tui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("agent-events.jsonl")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ lines: [String]) throws {
        guard !lines.isEmpty else {
            try Data().write(to: file, options: [.atomic])
            return
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func event(_ type: String, title: String? = nil, paneId: String? = nil) -> String {
        let titleJSON = title.map { "\"title\":\"\($0)\"" } ?? "\"title\":null"
        let paneJSON = paneId.map { "\"paneId\":\"\($0)\"" } ?? "\"paneId\":null"
        return
            "{\"source\":\"herdr\",\"type\":\"\(type)\",\(titleJSON),\"message\":null,\(paneJSON),\"workspaceId\":null}"
    }

    func testPreExistingEventsAreSkippedOnLaunch() throws {
        try write([event("completed", title: "old")])
        let manager = AgentEventManager(eventsFileURL: file, capture: false)
        defer { manager.stop() }

        manager.poll()

        XCTAssertNil(manager.currentEvent)
    }

    func testAppendedEventsAreShownInOrder() throws {
        try write([])
        let manager = AgentEventManager(eventsFileURL: file, capture: false)
        defer { manager.stop() }

        try append(event("progress", title: "working"))
        manager.poll()
        XCTAssertEqual(manager.currentEvent?.kind, .progress)
        XCTAssertEqual(manager.currentEvent?.title, "working")

        try append(event("completed", title: "done"))
        manager.poll()
        XCTAssertEqual(manager.currentEvent?.kind, .completed)
    }

    func testDuplicateActiveEventIsIgnored() throws {
        try write([])
        let manager = AgentEventManager(eventsFileURL: file, capture: false)
        defer { manager.stop() }

        try append(event("progress", title: "working", paneId: "p1"))
        manager.poll()
        XCTAssertEqual(manager.currentEvent?.kind, .progress)

        try append(event("progress", title: "still working", paneId: "p1"))
        manager.poll()
        XCTAssertEqual(manager.currentEvent?.title, "working")

        try append(event("completed", title: "done", paneId: "p1"))
        manager.poll()
        XCTAssertEqual(manager.currentEvent?.kind, .completed)
    }

    func testClearDismissesCurrentEvent() throws {
        try write([])
        let manager = AgentEventManager(eventsFileURL: file, capture: false)
        defer { manager.stop() }

        try append(event("access_request", title: "approve me", paneId: "p2"))
        manager.poll()
        XCTAssertEqual(manager.currentEvent?.kind, .accessRequest)

        try append(event("clear"))
        manager.poll()
        XCTAssertNil(manager.currentEvent)
    }

    func testTruncationResetsOffsetAndReadsNewEvents() throws {
        try write([
            event("completed", title: "a-very-long-title-that-makes-the-file-big-1234567890")
        ])
        let manager = AgentEventManager(eventsFileURL: file, capture: false)
        defer { manager.stop() }

        manager.poll()
        XCTAssertNil(manager.currentEvent)

        try write([event("progress", title: "new")])
        manager.poll()
        XCTAssertEqual(manager.currentEvent?.kind, .progress)
    }

    func testPartialLineIsBufferedUntilNewline() throws {
        try write([])
        let manager = AgentEventManager(eventsFileURL: file, capture: false)
        defer { manager.stop() }

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(event("progress", title: "working").utf8))
        try? handle.close()

        manager.poll()
        XCTAssertNil(manager.currentEvent)

        let closer = try FileHandle(forWritingTo: file)
        try closer.seekToEnd()
        try closer.write(contentsOf: Data("\n".utf8))
        try? closer.close()

        manager.poll()
        XCTAssertEqual(manager.currentEvent?.kind, .progress)
    }

    func testInvalidLinesAreSkipped() throws {
        try write([])
        let manager = AgentEventManager(eventsFileURL: file, capture: false)
        defer { manager.stop() }

        try append("not json at all")
        try append(event("completed", title: "valid"))
        manager.poll()

        XCTAssertEqual(manager.currentEvent?.kind, .completed)
    }

    func testHerdrStatusMapping() {
        XCTAssertEqual(AgentEventManager.kind(for: "blocked"), .accessRequest)
        XCTAssertEqual(AgentEventManager.kind(for: "working"), .progress)
        XCTAssertEqual(AgentEventManager.kind(for: "done"), .completed)
        XCTAssertEqual(AgentEventManager.kind(for: "running"), .started)
        XCTAssertEqual(AgentEventManager.kind(for: "idle"), .idle)
        XCTAssertNil(AgentEventManager.kind(for: "unknown"))
        XCTAssertNil(AgentEventManager.kind(for: ""))
    }

    func testHerdrSeverityOrdering() {
        let blocked = AgentEventManager.severity(of: .accessRequest)
        let done = AgentEventManager.severity(of: .completed)
        let working = AgentEventManager.severity(of: .progress)
        let idle = AgentEventManager.severity(of: .idle)
        XCTAssertGreaterThan(blocked, done)
        XCTAssertGreaterThan(done, working)
        XCTAssertGreaterThan(working, AgentEventManager.severity(of: .waiting))
        XCTAssertLessThan(idle, AgentEventManager.severity(of: .waiting))
    }

    func testHerdrSnapshotBuilder() {
        let agent = HerdrAgentInfo(
            agent: "kilo",
            agentStatus: "blocked",
            paneId: "w3:p3",
            workspaceId: "w3",
            terminalTitle: "Kilo CLI | Working")
        let snapshot = AgentEventManager.snapshot(for: agent)
        XCTAssertEqual(snapshot?.source, "kilo")
        XCTAssertEqual(snapshot?.kind, .accessRequest)
        XCTAssertEqual(snapshot?.paneId, "w3:p3")
        XCTAssertEqual(snapshot?.workspaceId, "w3")
        XCTAssertEqual(snapshot?.title, "Kilo CLI | Working")
        XCTAssertEqual(snapshot?.id, "w3:p3")
    }

    // MARK: - herdr capture update() logic

    private func agent(_ name: String, _ status: String, pane: String) -> HerdrAgentInfo {
        HerdrAgentInfo(
            agent: name,
            agentStatus: status,
            paneId: pane,
            workspaceId: String(pane.split(separator: ":").first ?? ""),
            terminalTitle: "\(name) | \(status)")
    }

    func testFirstPollEmitsWorkingEvent() {
        var seen: [String: AgentEventKind] = [:]
        let result = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)

        XCTAssertEqual(result.events.map(\.kind), [.progress])
        XCTAssertEqual(result.events.first?.playSound, true)
        XCTAssertEqual(result.events.first?.persistent, true)
        XCTAssertEqual(result.roster.map(\.source), ["kilo"])
    }

    func testSameStateDoesNotReemit() {
        var seen: [String: AgentEventKind] = [:]
        let first = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)
        let second = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: first.events.first)

        XCTAssertTrue(second.events.isEmpty)
    }

    func testTransitionEmitsAccessRequest() {
        var seen: [String: AgentEventKind] = [:]
        _ = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)
        let second = AgentEventManager.update(
            from: [agent("kilo", "blocked", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)

        XCTAssertEqual(second.events.map(\.kind), [.accessRequest])
    }

    func testIdleIsRosterOnly() {
        var seen: [String: AgentEventKind] = [:]
        let result = AgentEventManager.update(
            from: [agent("kilo", "idle", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.roster.map(\.kind), [.idle])
    }

    func testUnknownStatusExcluded() {
        var seen: [String: AgentEventKind] = [:]
        let result = AgentEventManager.update(
            from: [agent("kilo", "unknown", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.roster.isEmpty)
    }

    func testDoneIsNotPersistent() {
        var seen: [String: AgentEventKind] = [:]
        let result = AgentEventManager.update(
            from: [agent("kilo", "done", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)

        XCTAssertEqual(result.events.first?.kind, .completed)
        XCTAssertEqual(result.events.first?.persistent, false)
    }

    func testRosterSortedBySeverity() {
        var seen: [String: AgentEventKind] = [:]
        let result = AgentEventManager.update(
            from: [
                agent("kilo", "working", pane: "w3:p3"),
                agent("freebuff", "blocked", pane: "w3:p4"),
                agent("kilo2", "done", pane: "w3:p5"),
            ],
            lastSeenKinds: &seen,
            current: nil)

        XCTAssertEqual(result.roster.map(\.kind), [.accessRequest, .completed, .progress])
    }

    func testEmptyAgentsClearsStaleRosterAndPersistentEvent() {
        var seen: [String: AgentEventKind] = [:]
        let shown = AgentEvent(
            source: "kilo",
            kind: .progress,
            title: nil,
            message: nil,
            paneId: "w3:p3",
            workspaceId: "w3",
            playSound: true,
            persistent: true)

        let result = AgentEventManager.update(from: [], lastSeenKinds: &seen, current: shown)

        XCTAssertEqual(result.events.map(\.kind), [.clear])
        XCTAssertTrue(result.roster.isEmpty)
    }

    func testVanishedShownAgentFallsBackSilently() {
        var seen: [String: AgentEventKind] = [:]
        let first = AgentEventManager.update(
            from: [
                agent("kilo", "blocked", pane: "w3:p3"),
                agent("freebuff", "working", pane: "w3:p4"),
            ],
            lastSeenKinds: &seen,
            current: nil)
        XCTAssertEqual(first.events.map(\.kind), [.progress, .accessRequest])
        let shown = first.events.last!

        let second = AgentEventManager.update(
            from: [agent("freebuff", "working", pane: "w3:p4")],
            lastSeenKinds: &seen,
            current: shown)

        XCTAssertEqual(second.events.map(\.kind), [.clear, .progress])
        XCTAssertEqual(second.events.last?.source, "freebuff")
        XCTAssertEqual(second.events.last?.playSound, false)
    }

    func testSameStateReshowsWhenCurrentNil() {
        var seen: [String: AgentEventKind] = [:]
        _ = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)
        let result = AgentEventManager.update(
            from: [agent("kilo", "working", pane: "w3:p3")],
            lastSeenKinds: &seen,
            current: nil)

        XCTAssertEqual(result.events.map(\.kind), [.progress])
        XCTAssertEqual(result.events.first?.playSound, false)
    }

    func testWorstStateWinsWhenMultipleAgentsChange() {
        var seen: [String: AgentEventKind] = [:]
        let result = AgentEventManager.update(
            from: [
                agent("kilo", "blocked", pane: "w3:p3"),
                agent("freebuff", "done", pane: "w3:p4"),
            ],
            lastSeenKinds: &seen,
            current: nil)

        XCTAssertEqual(result.events.map(\.kind), [.completed, .accessRequest])
        XCTAssertEqual(result.events.last?.kind, .accessRequest)
    }

    func testSoundCooldownSuppressesRapidRepeatsPerSourceAndKind() throws {
        let manager = AgentEventManager(eventsFileURL: file, capture: false)
        defer { manager.stop() }
        let first = AgentEvent(
            source: "kilo", kind: .progress, title: "t", message: nil,
            paneId: nil, workspaceId: nil, playSound: true, persistent: true)
        let sameAgain = AgentEvent(
            source: "kilo", kind: .progress, title: "t2", message: nil,
            paneId: nil, workspaceId: nil, playSound: true, persistent: true)
        let otherSource = AgentEvent(
            source: "freebuff", kind: .progress, title: "t", message: nil,
            paneId: nil, workspaceId: nil, playSound: true, persistent: true)

        XCTAssertTrue(manager.shouldPlaySound(for: first))
        XCTAssertFalse(manager.shouldPlaySound(for: sameAgain))
        XCTAssertTrue(manager.shouldPlaySound(for: otherSource))
    }
}
