import AppKit
import Foundation

/// One clipboard entry captured from the system pasteboard.
struct ClipboardItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// One dropped file held on the shelf. The `url` points at the file the shelf
/// owns (a copy in Bantay's data dir once the file has been through
/// `ShelfStore.add`), so the shelf is safe against the source moving.
struct ShelfFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let createdAt: Date

    init(id: UUID = UUID(), url: URL, createdAt: Date) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.createdAt = createdAt
    }

    /// File size for the shelf card footer, or nil.
    var byteCount: Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// The workspace icon for this file's type — instant, always available
    /// (the card uses this; richer QuickLook thumbnails are a future upgrade).
    var icon: NSImage? {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Pure clipboard-history logic: newest first, de-duplicated by content,
/// capped at a limit. Empty/whitespace text is ignored.
enum ClipboardHistory {
    static func merging(
        existing: [ClipboardItem], newText: String, now: Date, limit: Int
    ) -> [ClipboardItem] {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        var items = existing.filter { $0.text != trimmed }
        items.insert(ClipboardItem(text: trimmed, createdAt: now), at: 0)
        return Array(items.prefix(max(limit, 1)))
    }
}

/// Pure shelf-file logic: newest first, de-duplicated by URL, capped.
enum ShelfFiles {
    static func adding(
        _ newFiles: [ShelfFile], to existing: [ShelfFile], limit: Int
    ) -> [ShelfFile] {
        var items = existing
        for file in newFiles {
            items.removeAll { $0.url == file.url }
            items.insert(file, at: 0)
        }
        return Array(items.prefix(max(limit, 1)))
    }

    static func removing(
        _ url: URL, from existing: [ShelfFile]
    ) -> [ShelfFile] {
        existing.filter { $0.url != url }
    }
}
