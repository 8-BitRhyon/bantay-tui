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
        let manager = AgentEventManager(eventsFileURL: file)
        defer { manager.stop() }

        manager.poll()

        XCTAssertNil(manager.currentEvent)
    }

    func testAppendedEventsAreShownInOrder() throws {
        try write([])
        let manager = AgentEventManager(eventsFileURL: file)
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
        let manager = AgentEventManager(eventsFileURL: file)
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
        let manager = AgentEventManager(eventsFileURL: file)
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
        let manager = AgentEventManager(eventsFileURL: file)
        defer { manager.stop() }

        manager.poll()
        XCTAssertNil(manager.currentEvent)

        try write([event("progress", title: "new")])
        manager.poll()
        XCTAssertEqual(manager.currentEvent?.kind, .progress)
    }

    func testPartialLineIsBufferedUntilNewline() throws {
        try write([])
        let manager = AgentEventManager(eventsFileURL: file)
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
        let manager = AgentEventManager(eventsFileURL: file)
        defer { manager.stop() }

        try append("not json at all")
        try append(event("completed", title: "valid"))
        manager.poll()

        XCTAssertEqual(manager.currentEvent?.kind, .completed)
    }
}
