import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

/// The content type a shelf item holds. The kind drives the card icon and the
/// representations offered when the user drags the item back out.
enum ShelfItemKind: String, Codable, CaseIterable, Sendable {
    case file
    case image
    case movie
    case audio
    case link
    case text

    var systemImage: String {
        switch self {
        case .file: return "doc.fill"
        case .image: return "photo.fill"
        case .movie: return "film.fill"
        case .audio: return "waveform"
        case .link: return "link"
        case .text: return "doc.text.fill"
        }
    }

    /// Best-effort classification for items that were persisted before the
    /// kind field existed, and for files dropped from Finder.
    static func inferred(from url: URL) -> ShelfItemKind {
        if url.pathExtension.lowercased() == "webloc" { return .link }
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return .file
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        return .file
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
    let kind: ShelfItemKind
    /// The original web or file URL, when the drop had one. The drag-out
    /// provider uses it to offer a link alongside the stored file.
    let sourceURL: URL?

    init(
        id: UUID = UUID(),
        url: URL,
        createdAt: Date,
        name: String? = nil,
        kind: ShelfItemKind? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.createdAt = createdAt
        self.kind = kind ?? ShelfItemKind.inferred(from: url)
        self.sourceURL = sourceURL
    }

    var displayName: String {
        if kind == .link, name.lowercased().hasSuffix(".webloc") {
            return String(name.dropLast(".webloc".count))
        }
        return name
    }

    /// File size for the shelf card footer, or nil.
    var byteCount: Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// The workspace icon for this file's type. Instant, always available.
    var icon: NSImage? {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// A downsampled image preview for image items, cached per URL.
    @MainActor
    var imagePreview: NSImage? {
        guard kind == .image else { return nil }
        return ShelfPreviewCache.image(for: url)
    }

    /// A web link held as a `.webloc` file. Reads the stored bookmark when the
    /// in-memory source URL is missing after a relaunch.
    var linkURL: URL? {
        if let sourceURL { return sourceURL }
        guard kind == .link, let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            let raw = plist["URL"] as? String
        else { return nil }
        return URL(string: raw)
    }

    /// Plain text held as a `.txt` file.
    var textContent: String? {
        guard kind == .text else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Cache for shelf image thumbnails. ImageIO downsamples before the image is
/// turned into an NSImage, so a 20-item shelf never holds full-size bitmaps.
@MainActor
enum ShelfPreviewCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL, maxPixel: CGFloat = 160) -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
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

/// Why a drop could not be stored. The cases are deliberately specific so the
/// shelf can tell a user that a folder is unsupported, not just "failed".
enum ShelfDropFailureReason: Error, Equatable, Sendable {
    case sourceUnavailable
    case sourceIsDirectory
    case sourceIsSymlink
    case tooLarge(limit: Int64, actual: Int64)
    case writeFailed
    case storageUnavailable

    var message: String {
        switch self {
        case .sourceUnavailable:
            return "cannot be read"
        case .sourceIsDirectory:
            return "folders are not supported"
        case .sourceIsSymlink:
            return "symbolic links are not supported"
        case .tooLarge(let limit, let actual):
            return "too large (\(ShelfFormat.bytes(actual)), limit \(ShelfFormat.bytes(limit)))"
        case .writeFailed:
            return "could not be copied"
        case .storageUnavailable:
            return "shelf storage is unavailable"
        }
    }
}

/// One failed item in a drop batch.
struct ShelfDropFailure: Equatable, Sendable {
    let name: String
    let reason: ShelfDropFailureReason

    var message: String { "\(name): \(reason.message)" }
}

/// Short, user-facing outcome of one drop batch. The report survives until the
/// next drop or a short timeout, so a failure is never silent.
struct ShelfDropReport: Equatable, Sendable {
    let added: Int
    let failed: Int
    let removed: Int
    let failures: [ShelfDropFailure]

    var isError: Bool { added == 0 && failed > 0 }
    var hasFailure: Bool { failed > 0 }

    var shortMessage: String {
        if added == 0 && failed > 0 {
            if failed == 1, let failure = failures.first {
                return removed > 0
                    ? "\(failure.message), removed \(removed)"
                    : failure.message
            }
            let base = "Couldn't add \(failed) items"
            return removed > 0 ? "\(base), removed \(removed)" : base
        }

        var parts: [String] = []
        if added == 1 {
            parts.append("Added 1 item")
        } else if added > 1 {
            parts.append("Added \(added) items")
        }
        if failed > 0 {
            parts.append("\(failed) failed")
        }
        if removed > 0 {
            parts.append("removed \(removed)")
        }
        return parts.isEmpty ? "Nothing added" : parts.joined(separator: ", ")
    }

    var detail: String {
        failures.map(\.message).joined(separator: "\n")
    }
}

/// Byte formatting shared by the shelf footer and failure messages.
enum ShelfFormat {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 bytes" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
