import AppKit
import Foundation

/// Shelf retention options (NotchDrop-style: files are kept for a duration,
/// then auto-expired). Persisted in UserDefaults.
enum ShelfKeepDuration: String, CaseIterable, Identifiable, Sendable {
    case oneHour = "1 Hour"
    case oneDay = "1 Day"
    case threeDays = "3 Days"
    case oneWeek = "1 Week"
    case forever = "Forever"

    var id: String { rawValue }

    /// The `shelfKeepDuration` config raw value. Kept as a plain String in
    /// the config for harness compatibility; this enum maps it.
    static func from(configRaw: String?) -> ShelfKeepDuration {
        ShelfKeepDuration(rawValue: configRaw ?? "") ?? .oneDay
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .oneHour: 60 * 60
        case .oneDay: 60 * 60 * 24
        case .threeDays: 60 * 60 * 24 * 3
        case .oneWeek: 60 * 60 * 24 * 7
        case .forever: nil  // nil = keep forever
        }
    }
}

/// Persists and manages dropped shelf files with QuickLook previews.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var files: [ShelfFile] = []
    @Published private(set) var isLoading = false
    /// Total bytes owned by the current shelf, refreshed whenever files change.
    @Published private(set) var totalBytes: Int64 = 0
    /// Result of the last drop batch. The view shows it briefly so a failed
    /// copy never looks like a successful one.
    @Published private(set) var lastReport: ShelfDropReport?

    private static let persistKey = "shelfFiles_v1"
    /// Expensive checks run every 15 minutes while the app stays open.
    private static let maintenanceInterval: Duration = .seconds(900)

    private struct PendingAdd: Sendable {
        let drops: [ShelfDrop]
        let now: Date
    }

    private var pendingAdds: [PendingAdd] = []
    private var isProcessingAdds = false
    private var maintenanceTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?

    /// Storage root for copied shelf files.
    nonisolated static func storageDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI/shelf", isDirectory: true)
    }

    private init() {
        load()
        maintain()
        sweepOrphans()
        startMaintenanceLoop()
    }

    /// Add dropped files: copy each into shelf storage, then persist. Runs the
    /// (blocking) copy off the main actor so a big drop never beachballs.
    func add(urls: [URL], now: Date = Date()) {
        add(drops: urls.map(ShelfDrop.file), now: now)
    }

    /// Add any stageable drop. Image and media bytes become real files in the
    /// shelf, and links become `.webloc` files, so every item can be dragged
    /// back out as a file or a native pasteboard type.
    func add(drops: [ShelfDrop], now: Date = Date()) {
        guard !drops.isEmpty else { return }
        if !isProcessingAdds && pendingAdds.isEmpty {
            publishReport(nil)
        }
        pendingAdds.append(PendingAdd(drops: drops, now: now))
        isLoading = true
        processPendingAdds()
    }

    /// Writes are serialized so two quick drops cannot race their merges or
    /// leave one batch's files unreferenced.
    private func processPendingAdds() {
        guard !isProcessingAdds, !pendingAdds.isEmpty else { return }
        isProcessingAdds = true
        let job = pendingAdds.removeFirst()
        let maxItemBytes = Int64(NotchHUDConfig.shared.clampedShelfMaxBytes)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.persist(
                job.drops, now: job.now, maxItemBytes: maxItemBytes)
            self.apply(result, now: job.now)
            self.isProcessingAdds = false
            if self.pendingAdds.isEmpty {
                self.isLoading = false
                self.sweepOrphans()
            } else {
                self.processPendingAdds()
            }
        }
    }

    /// Merge one completed batch, enforce count and byte limits, persist, and
    /// publish a report that names every item that failed.
    private func apply(_ result: ShelfDropWriteResult, now: Date) {
        let previousURLs = Set(files.map(\.url))
        let merged = ShelfFiles.adding(
            result.files, to: files,
            limit: NotchHUDConfig.shared.clampedShelfLimit)
        let keptAfterCount = Set(merged.map(\.url))
        for url in previousURLs where !keptAfterCount.contains(url) {
            Self.deleteOwned(url)
        }

        var sizes: [URL: Int64] = [:]
        for file in merged {
            sizes[file.url] = Int64(max(file.byteCount ?? 0, 0))
        }
        let budget = ShelfFiles.enforcingByteBudget(
            merged.map {
                ShelfSizedFile(file: $0, bytes: sizes[$0.url] ?? 0)
            },
            maxBytes: Int64(NotchHUDConfig.shared.clampedShelfMaxBytes))
        for file in budget.evicted {
            Self.deleteOwned(file.url)
        }

        setFiles(budget.kept)
        maintain(now: now)
        save()

        let finalURLs = Set(files.map(\.url))
        let added = result.files.filter { finalURLs.contains($0.url) }.count
        publishReport(
            ShelfDropReport(
                added: added, failed: result.failures.count,
                removed: previousURLs.subtracting(finalURLs).count,
                failures: result.failures))
    }

    /// Write drops into shelf storage off the main actor.
    nonisolated private static func persist(
        _ drops: [ShelfDrop], now: Date, maxItemBytes: Int64
    ) async -> ShelfDropWriteResult {
        await Task.detached(priority: .utility) {
            ShelfDropWriter.write(
                drops, root: storageDirectory(), now: now,
                maxItemBytes: maxItemBytes)
        }.value
    }

    /// Remove an item and its copied file (best-effort).
    func remove(_ file: ShelfFile) {
        setFiles(ShelfFiles.removing(file.url, from: files))
        Self.deleteOwned(file.url)
        save()
    }

    func removeAll() {
        for file in files {
            Self.deleteOwned(file.url)
        }
        setFiles([])
        save()
    }

    /// Delete only files inside the shelf storage root. A stale or corrupt
    /// persisted entry must never delete a file the user still owns.
    nonisolated private static func deleteOwned(_ url: URL) {
        let root = storageDirectory().standardizedFileURL
        let path = url.standardizedFileURL
        guard path.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: path)
        let parent = path.deletingLastPathComponent()
        if parent.path != root.path {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    func copyPath(_ file: ShelfFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.url.path, forType: .string)
    }

    func copyContent(_ file: ShelfFile) {
        guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func airDrop(_ file: ShelfFile) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        if service.canPerform(withItems: [file.url]) {
            service.perform(withItems: [file.url])
        }
    }

    /// Apply every retention rule: expiry, item limit, then byte budget.
    /// Called on launch, after each drop, on settings changes, on the periodic
    /// timer, and when the shelf opens.
    func maintain(now: Date = Date()) {
        var sizes: [URL: Int64] = [:]
        for file in files {
            sizes[file.url] = Int64(max(file.byteCount ?? 0, 0))
        }
        let keep = ShelfKeepDuration.from(
            configRaw: NotchHUDConfig.shared.shelfKeepDuration)
        let result = ShelfRetention.keep(
            files, now: now, interval: keep.timeInterval,
            limit: NotchHUDConfig.shared.clampedShelfLimit,
            maxBytes: Int64(NotchHUDConfig.shared.clampedShelfMaxBytes),
            sizes: sizes)
        guard !result.removed.isEmpty else { return }
        for file in result.removed {
            Self.deleteOwned(file.url)
        }
        setFiles(result.kept)
        save()
    }

    /// Remove storage that no persisted item references. Runs at launch, after
    /// a drop queue drains, periodically, and when the shelf opens. It never
    /// runs while a write is in flight, so an incoming directory is safe.
    func sweepOrphans() {
        guard !isLoading, !isProcessingAdds else { return }
        ShelfOrphanSweeper.sweep(
            root: Self.storageDirectory(),
            referenced: Set(files.map(\.url)))
    }

    private func startMaintenanceLoop() {
        maintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.maintenanceInterval)
                guard !Task.isCancelled, let self else { return }
                self.maintain()
                self.sweepOrphans()
            }
        }
    }

    private func publishReport(_ report: ShelfDropReport?) {
        reportTask?.cancel()
        lastReport = report
        guard report != nil else { return }
        reportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.lastReport = nil
        }
    }

    /// Single writer for `files` so the published byte total can never drift.
    private func setFiles(_ newFiles: [ShelfFile]) {
        files = newFiles
        totalBytes = newFiles.reduce(into: Int64(0)) { total, file in
            total += Int64(max(file.byteCount ?? 0, 0))
        }
    }

    // MARK: - Persistence

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.persistKey),
            let decoded = try? JSONDecoder().decode([PersistedShelfFile].self, from: data)
        else {
            setFiles([])
            return
        }
        setFiles(decoded.compactMap { $0.toShelfFile() })
    }

    private func save() {
        let encoded = files.map {
            PersistedShelfFile(
                name: $0.name, url: $0.url, createdAt: $0.createdAt,
                kind: $0.kind, sourceURL: $0.sourceURL)
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistKey)
    }
}

/// Codable mirror of `ShelfFile` for persistence (ShelfFile itself has a URL
/// which encodes fine, but this keeps the stored format stable and small).
/// The optional fields keep shelves written by older builds readable.
private struct PersistedShelfFile: Codable {
    let name: String
    let url: URL
    let createdAt: Date
    let kind: ShelfItemKind?
    let sourceURL: URL?

    func toShelfFile() -> ShelfFile? {
        // Drop items whose storage file no longer exists (deleted outside).
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ShelfFile(
            url: url, createdAt: createdAt, name: name, kind: kind,
            sourceURL: sourceURL)
    }
}
