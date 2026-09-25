#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @Suite("Async process runner", .serialized)
    struct AsyncProcessTests {
        @Test("echo round trip status zero")
        func echoRoundTripStatusZero() async {
            let result = await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello", "world"])
            #expect(result.status == 0)
            #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
        }

        @Test("false returns non-zero status")
        func falseReturnsNonzeroStatus() async {
            let result = await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/false"))
            #expect(result.status != 0)
        }

        @Test("timeout terminates long-running process")
        func timeoutTerminatesLongRunningProcess() async {
            let start = Date()
            let result = await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 2)
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < 5)
            #expect(result.status != 0)
        }

        @Test("megabyte of stdout does not deadlock")
        func megabyteOfStdoutDoesNotDeadlock() async {
            let result = await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "yes aaaaaaaaaa | head -c 1048576"],
                timeout: 10)
            #expect(result.status == 0)
            #expect(result.stdout.count == 1_048_576)
        }

        @Test("nonexistent executable returns error not hang")
        func nonexistentExecutableReturnsErrorNotHang() async {
            let result = await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/nonexistent/bogus-binary-xyz"),
                timeout: 2)
            #expect(result.status == -1)
        }

        @Test("clamped timeout bounds")
        func clampedTimeoutBounds() {
            #expect(ProcessRunner.clampedTimeout(-5) == 0.5)
            #expect(ProcessRunner.clampedTimeout(0) == 0.5)
            #expect(ProcessRunner.clampedTimeout(0.75) == 0.75)
            #expect(ProcessRunner.clampedTimeout(3600) == 120)
        }
    }
#endif
