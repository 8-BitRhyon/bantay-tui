#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @Suite("Focus telemetry", .serialized)
    struct FocusTelemetryTests {
        private func makeHome() throws -> URL {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-focus-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: true)
            return home
        }

        private func event(
            _ seconds: TimeInterval, success: Bool, method: FocusEvent.Method
        ) -> FocusEvent {
            FocusEvent(
                timestamp: Date(timeIntervalSince1970: seconds),
                agentID: "antigravity:\(Int(seconds))",
                source: "antigravity",
                sessionPath: "/tmp/\(Int(seconds)).db",
                paneID: nil,
                method: method,
                success: success)
        }

        @Test("record and load round-trip the focus event")
        func recordLoad() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let first = event(1_000, success: true, method: .antigravityConversation)
            let second = event(2_000, success: false, method: .standalone)
            FocusTelemetry.record(first, home: home.path)
            FocusTelemetry.record(second, home: home.path)
            FocusTelemetry.flush()
            let loaded = FocusTelemetry.load(home: home.path)
            #expect(loaded == [first, second])
        }

        @Test("summary counts only the requested window")
        func summaryWindow() {
            let events = [
                event(1_000, success: true, method: .pane),
                event(2_000, success: false, method: .pane),
                event(3_000, success: true, method: .standalone),
            ]
            let all = FocusTelemetry.summary(events)
            #expect(all.total == 3)
            #expect(all.successes == 2)
            #expect(abs(all.rate - 2.0 / 3.0) < 0.001)
            let recent = FocusTelemetry.summary(
                events, since: Date(timeIntervalSince1970: 1_500))
            #expect(recent.total == 2)
            #expect(recent.successes == 1)
            #expect(abs(recent.rate - 0.5) < 0.001)
        }

        @Test("empty summary is zero, not a division error")
        func emptySummary() {
            let summary = FocusTelemetry.summary([])
            #expect(summary.total == 0)
            #expect(summary.successes == 0)
            #expect(summary.rate == 0)
        }
    }
#endif
