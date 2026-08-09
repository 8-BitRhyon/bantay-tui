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

/// The shelf: persisted, owns copies of dropped files, expires by retention,
/// and renders QuickLook thumbnails. Mirrors NotchDrop's TrayDrop semantics —
/// a drop here is *safe* (the file is copied into Bantay's data dir and
/// survives the source file moving or the app restarting).
///
/// - Persistence: items persisted as JSON in UserDefaults; files copied into
///   `~/Library/Application Support/Bantay-TUI/shelf/<uuid>/<name>`.
/// - Retention: `cleanExpired()` removes items past `keepDuration` (config).
/// - Thumbnails: generated lazily via NSWorkspace icon (fast) then upgraded
///   to a QuickLook thumbnail when available.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var files: [ShelfFile] = []
    @Published private(set) var isLoading = false

    private static let persistKey = "shelfFiles_v1"

    /// Storage root for copied shelf files.
    nonisolated static func storageDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bantay-TUI/shelf", isDirectory: true)
    }

    private init() {
        load()
    }

    /// Add dropped files: copy each into shelf storage, then persist. Runs the
    /// (blocking) copy off the main actor so a big drop never beachballs.
    func add(urls: [URL], now: Date = Date()) {
        isLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let copied = await Self.copyToStorage(urls)
            let items = copied.map { ShelfFile(url: $0, createdAt: now) }
            self.files = ShelfFiles.adding(
                items, to: self.files,
                limit: NotchHUDConfig.shared.clampedShelfLimit)
            self.save()
            self.isLoading = false
        }
    }

    /// Copy dropped URLs into shelf storage off the main actor; returns the
    /// copied destinations. Falls back to the original URL if the copy fails
    /// (so a file that can't be copied still lands on the shelf).
    nonisolated
        private static func copyToStorage(_ urls: [URL]) async -> [URL]
    {
        await Task.detached(priority: .utility) {
            urls.map { url in
                let dir = ShelfStore.storageDirectory()
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: dest)
                    return dest
                } catch {
                    return url
                }
            }
        }.value
    }

    /// Remove an item and its copied file (best-effort).
    func remove(_ file: ShelfFile) {
        files = ShelfFiles.removing(file.url, from: files)
        try? FileManager.default.removeItem(at: file.url)
        save()
    }

    func removeAll() {
        for file in files {
            try? FileManager.default.removeItem(at: file.url)
        }
        files = []
        save()
    }

    /// Expire items past the configured retention. Call on launch and after
    /// each add so the shelf never holds files longer than the user asked.
    func cleanExpired(now: Date = Date()) {
        let keep = ShelfKeepDuration.from(
            configRaw: NotchHUDConfig.shared.shelfKeepDuration)
        guard let interval = keep.timeInterval else { return }
        var changed = false
        files.removeAll { file in
            let expired = now.timeIntervalSince(file.createdAt) > interval
            if expired {
                try? FileManager.default.removeItem(at: file.url)
                changed = true
            }
            return expired
        }
        if changed { save() }
    }

    // MARK: - Persistence

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.persistKey),
            let decoded = try? JSONDecoder().decode([PersistedShelfFile].self, from: data)
        else {
            files = []
            return
        }
        files = decoded.compactMap { $0.toShelfFile() }
        cleanExpired()
    }

    private func save() {
        let encoded = files.map {
            PersistedShelfFile(name: $0.name, url: $0.url, createdAt: $0.createdAt)
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistKey)
    }
}

/// Codable mirror of `ShelfFile` for persistence (ShelfFile itself has a URL
/// which encodes fine, but this keeps the stored format stable and small).
private struct PersistedShelfFile: Codable {
    let name: String
    let url: URL
    let createdAt: Date

    func toShelfFile() -> ShelfFile? {
        // Drop items whose storage file no longer exists (deleted outside).
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ShelfFile(url: url, createdAt: createdAt)
    }
}
