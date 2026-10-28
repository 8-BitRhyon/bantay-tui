import AppKit
import Foundation
import UniformTypeIdentifiers

/// One item read from a drag pasteboard, before the shelf stores it. Data
/// drops are materialized into real files so the shelf can own them and hand
/// a file URL back out to any app.
enum ShelfDrop: Sendable, Equatable {
    case file(URL)
    case data(Data, fileName: String, kind: ShelfItemKind, sourceURL: URL?)
    case link(URL, title: String?)
    case text(String)
}

/// Outcome of writing a whole drop batch. A bad item is reported instead of
/// being silently skipped, and one failure never discards the rest.
struct ShelfDropWriteResult: Equatable, Sendable {
    let files: [ShelfFile]
    let failures: [ShelfDropFailure]
}

/// Writes dropped payloads into the shelf's own storage. Pure file work runs
/// off the main actor through `ShelfStore`.
enum ShelfDropWriter {
    /// Persist a batch of drops. A bad item is reported instead of being
    /// silently skipped, so one failure never discards the rest of the batch.
    nonisolated static func write(
        _ drops: [ShelfDrop], root: URL, now: Date = Date(),
        maxItemBytes: Int64 = .max
    ) -> ShelfDropWriteResult {
        var files: [ShelfFile] = []
        var failures: [ShelfDropFailure] = []
        for drop in drops {
            switch writeItem(
                drop, root: root, now: now, maxItemBytes: maxItemBytes)
            {
            case .file(let file):
                files.append(file)
            case .failure(let reason):
                failures.append(
                    ShelfDropFailure(
                        name: displayName(for: drop), reason: reason))
            }
        }
        return ShelfDropWriteResult(files: files, failures: failures)
    }

    nonisolated static func write(
        _ drop: ShelfDrop, root: URL, now: Date = Date(),
        maxItemBytes: Int64 = .max
    ) -> ShelfFile? {
        switch writeItem(
            drop, root: root, now: now, maxItemBytes: maxItemBytes)
        {
        case .file(let file):
            return file
        case .failure:
            return nil
        }
    }

    // MARK: - Item writers

    private enum ItemResult {
        case file(ShelfFile)
        case failure(ShelfDropFailureReason)
    }

    private nonisolated static func writeItem(
        _ drop: ShelfDrop, root: URL, now: Date, maxItemBytes: Int64
    ) -> ItemResult {
        switch drop {
        case .file(let source):
            return writeFile(
                source, root: root, now: now, maxItemBytes: maxItemBytes)
        case .data(let data, let fileName, let kind, let sourceURL):
            return writeData(
                data, fileName: fileName, kind: kind, sourceURL: sourceURL,
                root: root, now: now, maxItemBytes: maxItemBytes)
        case .link(let url, let title):
            return writeLink(
                url, title: title, root: root, now: now,
                maxItemBytes: maxItemBytes)
        case .text(let text):
            return writeText(
                text, root: root, now: now, maxItemBytes: maxItemBytes)
        }
    }

    private nonisolated static func writeFile(
        _ source: URL, root: URL, now: Date, maxItemBytes: Int64
    ) -> ItemResult {
        let name = sanitizedName(source.lastPathComponent, fallback: "File")
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let values = try? source.resourceValues(forKeys: keys) else {
            return .failure(.sourceUnavailable)
        }
        if values.isSymbolicLink == true {
            return .failure(.sourceIsSymlink)
        }
        if values.isDirectory == true {
            return .failure(.sourceIsDirectory)
        }

        let sourceBytes = Int64(max(values.fileSize ?? 0, 0))
        if sourceBytes > maxItemBytes {
            return .failure(
                .tooLarge(limit: maxItemBytes, actual: sourceBytes))
        }

        guard let dir = makeDirectory(root) else {
            return .failure(.storageUnavailable)
        }
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            // Never stage the source URL as a fallback. Removing a shelf item
            // deletes its file, and that must never delete the user's original.
            try? FileManager.default.removeItem(at: dir)
            return .failure(.writeFailed)
        }

        // The source can grow between the stat and the copy. Check the bytes
        // that actually landed before the file is admitted to the shelf.
        let copiedBytes = Int64(
            max(
                (try? dest.resourceValues(forKeys: [.fileSizeKey]))?
                    .fileSize ?? 0, 0))
        if copiedBytes > maxItemBytes {
            try? FileManager.default.removeItem(at: dir)
            return .failure(
                .tooLarge(limit: maxItemBytes, actual: copiedBytes))
        }

        return .file(
            ShelfFile(
                url: dest, createdAt: now,
                kind: ShelfItemKind.inferred(from: source)))
    }

    private nonisolated static func writeData(
        _ data: Data, fileName: String, kind: ShelfItemKind,
        sourceURL: URL?, root: URL, now: Date, maxItemBytes: Int64
    ) -> ItemResult {
        let bytes = Int64(data.count)
        if bytes > maxItemBytes {
            return .failure(.tooLarge(limit: maxItemBytes, actual: bytes))
        }
        guard let dir = makeDirectory(root) else {
            return .failure(.storageUnavailable)
        }
        let name = sanitizedName(fileName, fallback: "Dropped item")
        let dest = dir.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return .failure(.writeFailed)
        }
        return .file(
            ShelfFile(
                url: dest, createdAt: now, name: name, kind: kind,
                sourceURL: sourceURL))
    }

    private nonisolated static func writeLink(
        _ url: URL, title: String?, root: URL, now: Date,
        maxItemBytes: Int64
    ) -> ItemResult {
        let display = linkDisplayName(url, title: title)
        let name = sanitizedName(
            display, fallback: "Link", extension: "webloc")
        let plist: [String: Any] = ["URL": url.absoluteString]
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            return .failure(.writeFailed)
        }
        let bytes = Int64(data.count)
        if bytes > maxItemBytes {
            return .failure(.tooLarge(limit: maxItemBytes, actual: bytes))
        }

        guard let dir = makeDirectory(root) else {
            return .failure(.storageUnavailable)
        }
        let dest = dir.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return .failure(.writeFailed)
        }
        return .file(
            ShelfFile(
                url: dest, createdAt: now, name: display, kind: .link,
                sourceURL: url))
    }

    private nonisolated static func writeText(
        _ text: String, root: URL, now: Date, maxItemBytes: Int64
    ) -> ItemResult {
        let data = Data(text.utf8)
        let bytes = Int64(data.count)
        if bytes > maxItemBytes {
            return .failure(.tooLarge(limit: maxItemBytes, actual: bytes))
        }
        guard let dir = makeDirectory(root) else {
            return .failure(.storageUnavailable)
        }
        let display = textDisplayName(text)
        let name = sanitizedName(
            display, fallback: "Text", extension: "txt")
        let dest = dir.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return .failure(.writeFailed)
        }
        return .file(
            ShelfFile(
                url: dest, createdAt: now, name: display, kind: .text))
    }

    /// Human-readable name for a failure report. Never used as a file path.
    nonisolated static func displayName(for drop: ShelfDrop) -> String {
        switch drop {
        case .file(let url):
            let name = url.lastPathComponent
            return name.isEmpty ? "File" : name
        case .data(_, let fileName, _, _):
            return fileName.isEmpty ? "Dropped item" : fileName
        case .link(let url, let title):
            return linkDisplayName(url, title: title)
        case .text(let text):
            return textDisplayName(text)
        }
    }

    // MARK: - Helpers

    private nonisolated static func makeDirectory(_ root: URL) -> URL? {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Keep names readable and safe for the file system. Slashes and colons
    /// become hyphens, control characters disappear, and long names truncate.
    nonisolated static func sanitizedName(
        _ raw: String, fallback: String, extension ext: String? = nil
    ) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: ":", with: "-")
        name = name.replacingOccurrences(of: "\0", with: "")
        if name.isEmpty { name = fallback }
        if let ext, !ext.isEmpty {
            let current = (name as NSString).pathExtension
            if current.caseInsensitiveCompare(ext) != .orderedSame {
                name = (name as NSString).deletingPathExtension
                if name.isEmpty { name = fallback }
                name += ".\(ext)"
            }
        }
        if name.count > 96 {
            let currentExt = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let trimmed = String(base.prefix(80))
            name = currentExt.isEmpty ? trimmed : "\(trimmed).\(currentExt)"
        }
        return name
    }

    nonisolated static func linkDisplayName(_ url: URL, title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let host = url.host, !host.isEmpty {
            let path = url.path.trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
            return path.isEmpty ? host : "\(host)/\(path)"
        }
        return url.absoluteString
    }

    nonisolated static func textDisplayName(_ text: String) -> String {
        let firstLine =
            text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Text" }
        return String(trimmed.prefix(60))
    }

    /// The preferred file extension for a dropped pasteboard type.
    nonisolated static func fileExtension(for type: UTType) -> String {
        if let ext = type.preferredFilenameExtension, !ext.isEmpty { return ext }
        let fallbacks: [(UTType, String)] = [
            (.png, "png"), (.jpeg, "jpg"), (.tiff, "tiff"), (.gif, "gif"),
            (.heic, "heic"), (.webP, "webp"), (.mpeg4Movie, "mp4"),
            (.quickTimeMovie, "mov"), (.mp3, "mp3"), (.mpeg4Audio, "m4a"),
            (.aiff, "aiff"),
        ]
        return fallbacks.first { $0.0 == type }?.1 ?? "dat"
    }
}
