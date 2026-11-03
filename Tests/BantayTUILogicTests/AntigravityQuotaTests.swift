#if canImport(Testing)
    import Foundation
    import SQLite3
    import Testing

    @testable import BantayTUI

    private let testTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private enum AgyFixtureError: Error {
        case sqlite(String)
    }

    /// Synthetic protobuf bytes. The real blob contains account data and
    /// never appears in a fixture.
    private enum AgyFixture {
        static func varint(_ value: UInt64) -> Data {
            var value = value
            var data = Data()
            while value >= 0x80 {
                data.append(UInt8((value & 0x7f) | 0x80))
                value >>= 7
            }
            data.append(UInt8(value))
            return data
        }

        static func field(_ number: Int, _ payload: Data) -> Data {
            var data = varint(UInt64(number) << 3 | 2)
            data += varint(UInt64(payload.count))
            data += payload
            return data
        }

        static func varintField(_ number: Int, _ value: UInt64) -> Data {
            var data = varint(UInt64(number) << 3)
            data += varint(value)
            return data
        }

        static func floatField(_ number: Int, _ value: Float) -> Data {
            var data = varint(UInt64(number) << 3 | 5)
            data += withUnsafeBytes(of: value.bitPattern.littleEndian) {
                Data($0)
            }
            return data
        }

        static func model(_ name: String, fraction: Float, reset: UInt64) -> Data {
            let quota =
                floatField(1, fraction)
                + field(2, varintField(1, reset))
            return field(1, Data(name.utf8)) + field(15, quota)
        }

        static func payload(models: [Data], tier: String = "Google AI Pro") -> Data {
            var container = Data()
            for model in models {
                container += field(1, model)
            }
            let tierMessage =
                field(1, Data("g1-pro-tier".utf8))
                + field(2, Data(tier.utf8))
            return field(33, container) + field(36, tierMessage)
        }

        static func wrapped(models: [Data], tier: String = "Google AI Pro") -> Data {
            let payload = payload(models: models, tier: tier)
            let encoded = field(1, Data(payload.base64EncodedString().utf8))
            let row =
                field(1, Data("userStatusSentinelKey".utf8))
                + field(2, encoded)
            let wrapper = field(1, row)
            return Data(wrapper.base64EncodedString().utf8)
        }
    }

    private enum AgyHome {
        static func make(userStatus: Data?, conversations: Bool) throws -> URL {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-agy-quota-\(UUID().uuidString)")
            let global = home.appendingPathComponent(
                "Library/Application Support/Antigravity IDE/User/globalStorage",
                isDirectory: true)
            try FileManager.default.createDirectory(
                at: global, withIntermediateDirectories: true)
            if let userStatus {
                let dbURL = global.appendingPathComponent("state.vscdb")
                var handle: OpaquePointer?
                guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let db = handle
                else { throw AgyFixtureError.sqlite("open state.vscdb") }
                sqlite3_exec(
                    db, "CREATE TABLE ItemTable(key TEXT, value BLOB);", nil, nil, nil)
                var stmt: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        db, "INSERT INTO ItemTable VALUES(?, ?);", -1, &stmt, nil)
                        == SQLITE_OK, let stmt
                else {
                    sqlite3_close(db)
                    throw AgyFixtureError.sqlite("prepare insert")
                }
                sqlite3_bind_text(
                    stmt, 1, AntigravityQuota.userStatusKey, -1, testTransient)
                userStatus.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(
                        stmt, 2, raw.baseAddress, Int32(userStatus.count),
                        testTransient)
                }
                let step = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                sqlite3_close(db)
                guard step == SQLITE_DONE else {
                    throw AgyFixtureError.sqlite("insert row")
                }
            }
            if conversations {
                let dir = home.appendingPathComponent(
                    ".gemini/antigravity-ide/conversations", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                let dbURL = dir.appendingPathComponent("conv-1.db")
                var handle: OpaquePointer?
                guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let db = handle
                else { throw AgyFixtureError.sqlite("open conversation") }
                sqlite3_exec(
                    db,
                    "CREATE TABLE steps(idx INTEGER, step_type INTEGER, status INTEGER, metadata BLOB);"
                        + "INSERT INTO steps VALUES(0, 21, 3, x'');"
                        + "INSERT INTO steps VALUES(1, 15, 3, x'');",
                    nil, nil, nil)
                sqlite3_close(db)
            }
            return home
        }
    }

    @MainActor
    @Suite("Antigravity quota decode", .serialized)
    struct AntigravityQuotaTests {
        @Test("lowest model fraction keeps that model's own reset")
        func lowestFractionKeepsOwnReset() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let later = UInt64(now.timeIntervalSince1970) + 7_200
            let earlier = UInt64(now.timeIntervalSince1970) + 600
            let data = AgyFixture.wrapped(models: [
                AgyFixture.model("Low Model", fraction: 0.42, reset: later),
                AgyFixture.model("High Model", fraction: 0.80, reset: earlier),
            ])
            let state = AntigravityQuota.parseUserStatus(data, now: now)
            #expect(state != nil)
            #expect(abs((state?.remainingPercent ?? 0) - 42.0) < 0.001)
            #expect(state?.modelName == "Low Model")
            #expect(state?.resetsAt == Date(timeIntervalSince1970: TimeInterval(later)))
            #expect(state?.modelCount == 2)
            #expect(state?.isStale == false)
            #expect(state?.tier == "Google AI Pro")
        }

        @Test("equal fractions pick the earlier reset")
        func tiePicksEarlierReset() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let first = UInt64(now.timeIntervalSince1970) + 100
            let second = UInt64(now.timeIntervalSince1970) + 200
            let data = AgyFixture.wrapped(models: [
                AgyFixture.model("Later", fraction: 0.5, reset: second),
                AgyFixture.model("Earlier", fraction: 0.5, reset: first),
            ])
            let state = AntigravityQuota.parseUserStatus(data, now: now)
            #expect(state?.modelName == "Earlier")
            #expect(state?.resetsAt == Date(timeIntervalSince1970: TimeInterval(first)))
        }

        @Test("expired window is flagged stale and never critical")
        func expiredWindowIsStale() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let past = UInt64(now.timeIntervalSince1970) - 60
            let data = AgyFixture.wrapped(models: [
                AgyFixture.model("Expired", fraction: 0.0, reset: past)
            ])
            let state = AntigravityQuota.parseUserStatus(data, now: now)
            #expect(state?.isStale == true)
            let row = ProviderQuota(
                provider: "Antigravity",
                remainingPercent: state?.remainingPercent ?? 0,
                resetsAt: nil,
                isStale: true)
            #expect(row.isWarning == false)
            #expect(row.isCritical == false)
            #expect(row.dynamicResetDescription(now: now).contains("Stale"))
        }

        @Test("fresh zero percent is critical")
        func freshZeroIsCritical() {
            let row = ProviderQuota(provider: "Antigravity", remainingPercent: 0)
            #expect(row.isCritical == true)
            #expect(row.isWarning == true)
        }

        @Test("corrupt or missing payload returns no quota")
        func corruptPayloadReturnsNil() {
            #expect(AntigravityQuota.parseUserStatus(Data("not-base64!!".utf8)) == nil)
            let validBase64 = Data([0xff, 0xff, 0xff, 0xff]).base64EncodedData()
            #expect(AntigravityQuota.parseUserStatus(validBase64) == nil)
            let noQuota = AgyFixture.wrapped(models: [
                AgyFixture.field(1, Data("No Quota".utf8))
            ])
            #expect(AntigravityQuota.parseUserStatus(noQuota) == nil)
        }

        @Test("two antigravity rows have distinct ids and labels")
        func twoRowsHaveDistinctIDs() throws {
            let now = Date()
            let reset = UInt64(now.timeIntervalSince1970) + 3_600
            let value = AgyFixture.wrapped(models: [
                AgyFixture.model("Model", fraction: 0.42, reset: reset)
            ])
            let home = try AgyHome.make(userStatus: value, conversations: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let rows = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: ["antigravity"],
                costUSD: 0,
                budgetUSD: 10,
                home: home.path)
            #expect(rows.count == 2)
            #expect(rows.map(\.id) == ["antigravity", "antigravity-measured"])
            #expect(rows[0].rowLabel == "Reported")
            #expect(rows[1].rowLabel == "Measured")
            #expect(rows[1].hidesProgress == true)
            #expect(abs(rows[0].remainingPercent - 42.0) < 0.001)
        }

        @Test("no cache and no sessions emits no antigravity row")
        func emptyHomeEmitsNothing() {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-agy-empty-\(UUID().uuidString)")
            let rows = QuotaAxiTracker.probeLiveQuotas(
                activeProviders: ["antigravity"],
                costUSD: 0,
                budgetUSD: 10,
                home: home.path)
            #expect(rows.contains { $0.id.hasPrefix("antigravity") } == false)
        }

        @Test("id suffix keeps measured row distinct")
        func idSuffix() {
            let row = ProviderQuota(
                provider: "Antigravity", remainingPercent: 100, idSuffix: "measured")
            #expect(row.id == "antigravity-measured")
        }
    }
#endif
