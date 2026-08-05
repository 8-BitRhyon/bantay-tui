import XCTest

@testable import BantayTUI

/// Plan 016 §1c XCTest twins (L43-X): the async process runner must spawn,
/// drain, and time out without deadlocking or leaking zombies. These cannot
/// run in the CLI-only logic harness, so CI (Xcode) validates them.
final class AsyncProcessTests: XCTestCase {
    func testEchoRoundTripStatusZero() async {
        let result = await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "world"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testFalseReturnsNonzeroStatus() async {
        let result = await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertNotEqual(result.status, 0)
    }

    func testTimeoutTerminatesLongRunningProcess() async {
        let start = Date()
        let result = await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5, "timeout must return well before sleep 30 finishes")
        XCTAssertNotEqual(result.status, 0, "killed process reports a non-zero status")
    }

    func testMegabyteOfStdoutDoesNotDeadlock() async {
        // `yes | head -c 1048576` writes >1MB (64KB pipe buffer) — the
        // old waitUntilExit-before-read pattern would hang here.
        let result = await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes aaaaaaaaaa | head -c 1048576"],
            timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 1_048_576, "full 1MB stdout drained")
    }

    func testNonexistentExecutableReturnsErrorNotHang() async {
        let result = await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/nonexistent/bogus-binary-xyz"),
            timeout: 2)
        XCTAssertEqual(result.status, -1, "launch failure surfaces as status -1")
    }

    func testClampedTimeoutBounds() {
        XCTAssertEqual(ProcessRunner.clampedTimeout(-5), 0.5)
        XCTAssertEqual(ProcessRunner.clampedTimeout(0), 0.5)
        XCTAssertEqual(ProcessRunner.clampedTimeout(0.75), 0.75)
        XCTAssertEqual(ProcessRunner.clampedTimeout(3600), 120)
    }
}
