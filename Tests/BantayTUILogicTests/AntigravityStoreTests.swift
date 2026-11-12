#if canImport(Testing)
    import Foundation
    import SQLite3
    import Testing

    @testable import BantayTUI

    private enum AgyStoreFixtureError: Error {
        case sqlite(String)
    }

    @Suite("Antigravity store roots and WAL heartbeat", .serialized)
    struct AntigravityStoreTests {
        private func makeConversation(
            at url: URL, steps: Int
        ) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
                throw AgyStoreFixtureError.sqlite("open \(url.lastPathComponent)")
            }
            sqlite3_exec(
                db,
                "CREATE TABLE steps(idx INTEGER, step_type INTEGER, status INTEGER, metadata BLOB);",
                nil, nil, nil)
            for index in 0..<steps {
                sqlite3_exec(
                    db,
                    "INSERT INTO steps VALUES(\(index), 15, 3, x'');",
                    nil, nil, nil)
            }
            sqlite3_close(db)
        }

        private func setModified(_ date: Date, _ url: URL) throws {
            try FileManager.default.setAttributes(
                [.modificationDate: date], ofItemAtPath: url.path)
        }

        private func makeHome() throws -> URL {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("bantay-agy-store-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: true)
            return home
        }

        @Test("CLI root is read and WAL mtime marks the agent working")
        func cliRootWALHeartbeat() throws {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let cli = home.appendingPathComponent(
                ".gemini/antigravity/conversations", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cli, withIntermediateDirectories: true)
            let db = cli.appendingPathComponent("conv-1.db")
            try makeConversation(at: db, steps: 3)
            let wal = URL(fileURLWithPath: db.path + "-wal")
            FileManager.default.createFile(atPath: wal.path, contents: Data())
            try setModified(now.addingTimeInterval(-300), db)
            try setModified(now.addingTimeInterval(-30), wal)

            let snapshot = AntigravityStore.snapshot(home: home.path, now: now)
            #expect(snapshot.conversations.count == 1)
            #expect(snapshot.conversations.first?.id == "conv-1")
            #expect(snapshot.conversations.first?.stepCount == 3)
            #expect(snapshot.isWorking == true)
            #expect(
                AntigravityStore.conversationsDirectory(home: home.path).path == cli.path)
        }

        @Test("same conversation id in both roots uses the newer copy")
        func dualRootDedupe() throws {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let cli = home.appendingPathComponent(
                ".gemini/antigravity/conversations", isDirectory: true)
            let ide = home.appendingPathComponent(
                ".gemini/antigravity-ide/conversations", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cli, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: ide, withIntermediateDirectories: true)
            let cliDB = cli.appendingPathComponent("same.db")
            let ideDB = ide.appendingPathComponent("same.db")
            try makeConversation(at: cliDB, steps: 2)
            try makeConversation(at: ideDB, steps: 1)
            let cliWAL = URL(fileURLWithPath: cliDB.path + "-wal")
            FileManager.default.createFile(atPath: cliWAL.path, contents: Data())
            try setModified(now.addingTimeInterval(-200), ideDB)
            try setModified(now.addingTimeInterval(-200), cliDB)
            try setModified(now.addingTimeInterval(-30), cliWAL)

            let snapshot = AntigravityStore.snapshot(home: home.path, now: now)
            #expect(snapshot.conversations.count == 1)
            #expect(snapshot.conversations.first?.stepCount == 2)
        }

        @Test("a quiet conversation is not marked working")
        func quietConversationIsIdle() throws {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let cli = home.appendingPathComponent(
                ".gemini/antigravity/conversations", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cli, withIntermediateDirectories: true)
            let db = cli.appendingPathComponent("quiet.db")
            try makeConversation(at: db, steps: 2)
            let wal = URL(fileURLWithPath: db.path + "-wal")
            FileManager.default.createFile(atPath: wal.path, contents: Data())
            try setModified(now.addingTimeInterval(-300), db)
            try setModified(now.addingTimeInterval(-300), wal)

            let snapshot = AntigravityStore.snapshot(home: home.path, now: now)
            #expect(snapshot.conversations.count == 1)
            #expect(snapshot.isWorking == false)
        }
    }
#endif
