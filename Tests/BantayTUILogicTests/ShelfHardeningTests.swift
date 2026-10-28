#if canImport(Testing)
    import Foundation
    import Testing

    @testable import BantayTUI

    @Suite("Shelf hardening")
    struct ShelfHardeningTests {
        // MARK: - Byte budget

        @Test("the byte budget keeps the newest items and evicts the oldest")
        func byteBudgetEvictsOldest() {
            let now = Date(timeIntervalSince1970: 1_000)
            let newest = shelfFile("newest", at: now)
            let middle = shelfFile("middle", at: now)
            let oldest = shelfFile("oldest", at: now)

            let result = ShelfFiles.enforcingByteBudget(
                [
                    ShelfSizedFile(file: newest, bytes: 4),
                    ShelfSizedFile(file: middle, bytes: 4),
                    ShelfSizedFile(file: oldest, bytes: 4),
                ], maxBytes: 8)

            #expect(result.kept == [newest, middle])
            #expect(result.evicted == [oldest])
        }

        @Test("an exact byte fit is accepted")
        func exactByteFit() {
            let file = shelfFile("exact")
            let result = ShelfFiles.enforcingByteBudget(
                [ShelfSizedFile(file: file, bytes: 12)], maxBytes: 12)
            #expect(result.kept == [file])
            #expect(result.evicted.isEmpty)
        }

        @Test("a zero budget evicts every file")
        func zeroBudget() {
            let file = shelfFile("zero")
            let result = ShelfFiles.enforcingByteBudget(
                [ShelfSizedFile(file: file, bytes: 1)], maxBytes: 0)
            #expect(result.kept.isEmpty)
            #expect(result.evicted == [file])
        }

        @Test("one oversized item is evicted without wiping smaller items")
        func oversizedItemDoesNotWipeShelf() {
            let huge = shelfFile("huge")
            let small = shelfFile("small")
            let result = ShelfFiles.enforcingByteBudget(
                [
                    ShelfSizedFile(file: huge, bytes: 20),
                    ShelfSizedFile(file: small, bytes: 4),
                ], maxBytes: 8)
            #expect(result.kept == [small])
            #expect(result.evicted == [huge])
        }

        @Test("an all-oversized shelf is emptied")
        func allOversizedShelf() {
            let first = shelfFile("first")
            let second = shelfFile("second")
            let result = ShelfFiles.enforcingByteBudget(
                [
                    ShelfSizedFile(file: first, bytes: 20),
                    ShelfSizedFile(file: second, bytes: 30),
                ], maxBytes: 8)
            #expect(result.kept.isEmpty)
            #expect(result.evicted == [first, second])
        }

        // MARK: - Retention

        @Test("expiry keeps the exact boundary and future timestamps")
        func retentionBoundary() {
            let now = Date(timeIntervalSince1970: 2_000)
            let fresh = shelfFile("fresh", at: now)
            let exact = shelfFile("exact", at: now.addingTimeInterval(-3_600))
            let old = shelfFile("old", at: now.addingTimeInterval(-3_601))
            let future = shelfFile("future", at: now.addingTimeInterval(30))

            let result = ShelfRetention.keep(
                [fresh, exact, old, future], now: now, interval: 3_600,
                limit: 10, maxBytes: 10_000, sizes: [:])

            #expect(result.kept == [fresh, exact, future])
            #expect(result.removed == [old])
        }

        @Test("expiry, item limit, and byte budget compose in order")
        func retentionComposition() {
            let now = Date(timeIntervalSince1970: 2_000)
            let old = shelfFile("old", at: now.addingTimeInterval(-3_601))
            let first = shelfFile("first", at: now)
            let second = shelfFile("second", at: now)
            let third = shelfFile("third", at: now)

            let result = ShelfRetention.keep(
                [old, first, second, third], now: now, interval: 3_600,
                limit: 2, maxBytes: 4,
                sizes: [first.url: 4, second.url: 4, third.url: 4])

            #expect(result.kept == [first])
            #expect(result.removed == [old, second, third])
        }

        // MARK: - Writer failures

        @Test("oversized data is reported without leaving a directory")
        func oversizedData() throws {
            let base = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: base) }
            let storage = base.appendingPathComponent("storage")
            let drop = ShelfDrop.data(
                Data(repeating: 7, count: 10), fileName: "big.bin",
                kind: .file, sourceURL: nil)

            let result = ShelfDropWriter.write(
                [drop], root: storage, maxItemBytes: 5)

            #expect(result.files.isEmpty)
            #expect(result.failures.count == 1)
            #expect(result.failures.first?.name == "big.bin")
            #expect(
                result.failures.first?.reason
                    == .tooLarge(limit: 5, actual: 10))
            #expect(entryCount(storage) == 0)
        }

        @Test("an exact byte limit is written")
        func exactByteLimit() throws {
            let base = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: base) }
            let storage = base.appendingPathComponent("storage")
            let drop = ShelfDrop.data(
                Data(repeating: 7, count: 5), fileName: "exact.bin",
                kind: .file, sourceURL: nil)

            let result = ShelfDropWriter.write(
                [drop], root: storage, maxItemBytes: 5)

            #expect(result.files.count == 1)
            #expect(result.failures.isEmpty)
            let file = try #require(result.files.first)
            #expect(try Data(contentsOf: file.url) == Data(repeating: 7, count: 5))
        }

        @Test("folders and symbolic links are rejected, never copied")
        func unsafeSources() throws {
            let base = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: base) }
            let sources = base.appendingPathComponent("sources")
            try FileManager.default.createDirectory(
                at: sources, withIntermediateDirectories: true)
            let folder = sources.appendingPathComponent("folder")
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            let target = sources.appendingPathComponent("target.txt")
            try Data("target".utf8).write(to: target)
            let link = sources.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: target)
            let missing = sources.appendingPathComponent("missing.txt")

            let result = ShelfDropWriter.write(
                [.file(folder), .file(link), .file(missing)],
                root: base.appendingPathComponent("storage"),
                maxItemBytes: 1_000)

            #expect(result.files.isEmpty)
            #expect(result.failures.count == 3)
            #expect(
                result.failures.map(\.reason)
                    == [.sourceIsDirectory, .sourceIsSymlink, .sourceUnavailable])
            #expect(FileManager.default.fileExists(atPath: folder.path))
            #expect(FileManager.default.fileExists(atPath: target.path))
        }

        @Test("unwritable storage is reported, not silently dropped")
        func unwritableStorage() throws {
            let base = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: base) }
            let storage = base.appendingPathComponent("storage")
            try FileManager.default.createDirectory(
                at: storage, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: storage.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: storage.path)
            }

            let result = ShelfDropWriter.write(
                [.text("hello")], root: storage, maxItemBytes: 1_000)

            #expect(result.files.isEmpty)
            #expect(
                result.failures.first?.reason == .storageUnavailable)
        }

        @Test("a bad item does not discard the rest of the batch")
        func partialBatch() throws {
            let base = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: base) }
            let storage = base.appendingPathComponent("storage")
            let result = ShelfDropWriter.write(
                [
                    .text("ok"),
                    .data(
                        Data(repeating: 7, count: 10), fileName: "big.bin",
                        kind: .file, sourceURL: nil),
                ], root: storage, maxItemBytes: 5)

            #expect(result.files.count == 1)
            #expect(result.failures.count == 1)
            #expect(result.files.first?.textContent == "ok")
            #expect(result.failures.first?.name == "big.bin")
            #expect(entryCount(storage) == 1)
        }

        // MARK: - Orphan sweep

        @Test("the sweep keeps references and removes junk and symlinks")
        func orphanSweep() throws {
            let base = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: base) }
            let root = base.appendingPathComponent("storage")
            let keepDir = root.appendingPathComponent("keep")
            try FileManager.default.createDirectory(
                at: keepDir, withIntermediateDirectories: true)
            let keepFile = keepDir.appendingPathComponent("keep.bin")
            let extraFile = keepDir.appendingPathComponent("extra.bin")
            try Data("keep".utf8).write(to: keepFile)
            try Data("extra".utf8).write(to: extraFile)

            let orphanDir = root.appendingPathComponent("orphan")
            try FileManager.default.createDirectory(
                at: orphanDir, withIntermediateDirectories: true)
            try Data("orphan".utf8).write(
                to: orphanDir.appendingPathComponent("orphan.bin"))
            let emptyDir = root.appendingPathComponent("empty")
            try FileManager.default.createDirectory(
                at: emptyDir, withIntermediateDirectories: true)
            let looseFile = root.appendingPathComponent("loose.bin")
            try Data("loose".utf8).write(to: looseFile)

            let outside = base.appendingPathComponent("outside.txt")
            try Data("outside".utf8).write(to: outside)
            let escape = root.appendingPathComponent("escape")
            try FileManager.default.createSymbolicLink(
                at: escape, withDestinationURL: outside)

            let removed = ShelfOrphanSweeper.sweep(
                root: root, referenced: [keepFile])

            #expect(FileManager.default.fileExists(atPath: keepFile.path))
            #expect(!FileManager.default.fileExists(atPath: extraFile.path))
            #expect(!FileManager.default.fileExists(atPath: orphanDir.path))
            #expect(!FileManager.default.fileExists(atPath: emptyDir.path))
            #expect(!FileManager.default.fileExists(atPath: looseFile.path))
            #expect(!FileManager.default.fileExists(atPath: escape.path))
            #expect(FileManager.default.fileExists(atPath: outside.path))
            #expect(removed.count == 5)
        }

        @Test("the sweep tolerates a missing root")
        func missingSweepRoot() {
            let root = URL(fileURLWithPath: "/tmp/bantay-no-such-shelf-\(UUID())")
            #expect(ShelfOrphanSweeper.sweep(root: root, referenced: []).isEmpty)
        }

        // MARK: - Reporting and layout

        @Test("a total failure produces a readable report")
        func failureReport() {
            let report = ShelfDropReport(
                added: 0, failed: 1, removed: 0,
                failures: [
                    ShelfDropFailure(
                        name: "huge.mov",
                        reason: .tooLarge(limit: 1_000_000, actual: 2_000_000))
                ])
            #expect(report.isError)
            #expect(report.hasFailure)
            #expect(report.shortMessage.contains("huge.mov"))
            #expect(report.shortMessage.contains("too large"))
            #expect(report.detail.contains("huge.mov"))
            #expect(report.detail.contains("too large"))
        }

        @Test("a multi-item failure summarizes the count")
        func multiFailureReport() {
            let report = ShelfDropReport(
                added: 0, failed: 2, removed: 0,
                failures: [
                    ShelfDropFailure(name: "a.mov", reason: .sourceUnavailable),
                    ShelfDropFailure(name: "b.mov", reason: .sourceIsDirectory),
                ])
            #expect(report.shortMessage == "Couldn't add 2 items")
        }

        @Test("a successful batch is summarized with removals")
        func successReport() {
            let report = ShelfDropReport(
                added: 2, failed: 0, removed: 1, failures: [])
            #expect(!report.isError)
            #expect(report.shortMessage == "Added 2 items, removed 1")
        }

        @Test("a forced shelf keeps its tab bar so the panel has an escape")
        func forcedShelfTabBar() {
            #expect(
                IslandMetrics.shelfTabBarVisible(
                    showShelfTab: true, shelfSelected: false))
            #expect(
                !IslandMetrics.shelfTabBarVisible(
                    showShelfTab: false, shelfSelected: false))
            #expect(
                IslandMetrics.shelfTabBarVisible(
                    showShelfTab: false, shelfSelected: true))
        }

        @Test("the shelf panel reserves its footer and caps long clip lists")
        func shelfPanelFooterAndCap() {
            let chrome =
                IslandMetrics.shelfTabBarHeight + IslandMetrics.dividerHeight
            let empty = IslandMetrics.shelfPanelSize(
                topInset: 38, fileCount: 0, clipboardCount: 0)
            #expect(
                empty.height
                    == 38 + IslandMetrics.headerHeight + chrome
                    + IslandMetrics.shelfEmptyHeight
                    + IslandMetrics.shelfFooterHeight
                    + IslandMetrics.contentSpacing)

            let overflow = IslandMetrics.shelfPanelSize(
                topInset: 38, fileCount: 1, clipboardCount: 50)
            #expect(overflow.height == IslandMetrics.maxExpandedHeight)
            let fixed =
                38 + IslandMetrics.headerHeight + chrome
                + IslandMetrics.shelfStripHeight
                + IslandMetrics.shelfFooterHeight
                + IslandMetrics.contentSpacing
            #expect(
                overflow.height - fixed
                    < 50 * IslandMetrics.rowHeight)
        }

        // MARK: - Helpers

        private func shelfFile(
            _ name: String, at date: Date = Date(timeIntervalSince1970: 0)
        ) -> ShelfFile {
            ShelfFile(
                url: URL(fileURLWithPath: "/tmp/bantay-\(name)-\(UUID())"),
                createdAt: date, name: name)
        }

        private func temporaryRoot() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "bantay-shelf-hardening-tests-\(UUID().uuidString)",
                isDirectory: true)
        }

        private func entryCount(_ url: URL) -> Int {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return 0
            }
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path).count)
                ?? -1
        }
    }
#endif
