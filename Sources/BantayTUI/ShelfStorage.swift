import Foundation

/// One file paired with its on-disk size. Keeping the size separate makes the
/// budget math pure: tests can exercise eviction without writing real files.
struct ShelfSizedFile: Equatable, Sendable {
    let file: ShelfFile
    let bytes: Int64
}

/// Result of enforcing the shelf byte budget. `evicted` preserves the input
/// order so callers can delete exactly the files that no longer belong to the
/// shelf.
struct ShelfBudgetResult: Equatable, Sendable {
    let kept: [ShelfFile]
    let evicted: [ShelfFile]
}

/// Result of applying every retention rule in one pass.
struct ShelfMaintenanceResult: Equatable, Sendable {
    let kept: [ShelfFile]
    let removed: [ShelfFile]
}

extension ShelfFiles {
    /// Keep the newest items until the byte budget is reached. An item larger
    /// than the whole budget is evicted on its own, so a budget cut or a stale
    /// oversized file can never wipe smaller items that still fit. The shelf is
    /// ordered newest first, so trimming from the tail evicts the oldest files
    /// first. A non-positive budget evicts everything.
    static func enforcingByteBudget(
        _ entries: [ShelfSizedFile], maxBytes: Int64
    ) -> ShelfBudgetResult {
        guard maxBytes > 0 else {
            return ShelfBudgetResult(kept: [], evicted: entries.map(\.file))
        }

        let fitting = entries.enumerated().filter {
            max($0.element.bytes, 0) <= maxBytes
        }
        var total: Int64 = 0
        for entry in fitting {
            total += max(entry.element.bytes, 0)
        }

        var cut = fitting.count
        while cut > 0 && total > maxBytes {
            cut -= 1
            total -= max(fitting[cut].element.bytes, 0)
        }

        let keptIndices = Set(fitting.prefix(cut).map(\.offset))
        return ShelfBudgetResult(
            kept: entries.enumerated()
                .filter { keptIndices.contains($0.offset) }
                .map(\.element.file),
            evicted: entries.enumerated()
                .filter { !keptIndices.contains($0.offset) }
                .map(\.element.file))
    }
}

/// Pure retention rules. Expiry runs first, then the item limit, then the
/// byte budget. Removed files preserve their original relative order so the
/// store can delete them deterministically.
enum ShelfRetention {
    static func keep(
        _ files: [ShelfFile],
        now: Date,
        interval: TimeInterval?,
        limit: Int,
        maxBytes: Int64,
        sizes: [URL: Int64]
    ) -> ShelfMaintenanceResult {
        var kept = files

        if let interval {
            kept = kept.filter { now.timeIntervalSince($0.createdAt) <= interval }
        }

        let cappedLimit = max(limit, 1)
        if kept.count > cappedLimit {
            kept = Array(kept.prefix(cappedLimit))
        }

        let entries = kept.map { file in
            ShelfSizedFile(file: file, bytes: max(sizes[file.url] ?? 0, 0))
        }
        let budget = ShelfFiles.enforcingByteBudget(entries, maxBytes: maxBytes)
        let keptURLs = Set(budget.kept.map(\.url))
        let removed = files.filter { !keptURLs.contains($0.url) }

        return ShelfMaintenanceResult(kept: budget.kept, removed: removed)
    }
}

/// Deletes storage that the persisted shelf no longer references. The sweep
/// never follows symlinks: a link inside shelf storage is removed, while its
/// target stays untouched.
enum ShelfOrphanSweeper {
    @discardableResult
    nonisolated static func sweep(
        root: URL,
        referenced: Set<URL>,
        fileManager: FileManager = .default
    ) -> [URL] {
        let rootURL = root.standardizedFileURL
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [])
        else {
            return []
        }

        let referencedPaths = Set(referenced.map { $0.standardizedFileURL.path })
        var removed: [URL] = []

        for entry in entries {
            let entryURL = entry.standardizedFileURL
            let entryPath = entryURL.path

            if isSymlink(entryURL, fileManager: fileManager) {
                remove(entryURL, fileManager: fileManager, into: &removed)
                continue
            }

            if referencedPaths.contains(entryPath) {
                continue
            }

            let keepsDirectory = referencedPaths.contains {
                $0.hasPrefix(entryPath + "/")
            }
            guard keepsDirectory else {
                remove(entryURL, fileManager: fileManager, into: &removed)
                continue
            }

            guard
                let children = try? fileManager.contentsOfDirectory(
                    at: entryURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [])
            else {
                continue
            }
            for child in children {
                let childURL = child.standardizedFileURL
                let childPath = childURL.path
                if referencedPaths.contains(childPath) {
                    continue
                }
                if referencedPaths.contains(where: { $0.hasPrefix(childPath + "/") }) {
                    continue
                }
                remove(childURL, fileManager: fileManager, into: &removed)
            }
        }

        return removed
    }

    private nonisolated static func isSymlink(
        _ url: URL, fileManager: FileManager
    ) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private nonisolated static func remove(
        _ url: URL, fileManager: FileManager, into removed: inout [URL]
    ) {
        if (try? fileManager.removeItem(at: url)) != nil {
            removed.append(url)
        }
    }
}
