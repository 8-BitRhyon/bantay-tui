import AppKit
import Foundation
import UniformTypeIdentifiers

/// Reads browser, Finder, and app drags into shelf payloads. Browsers do not
/// always hand over a file URL: an image usually arrives as TIFF or PNG bytes
/// plus a web URL, and a link arrives as a URL plus text. Files always win so
/// a Finder drop is never copied twice.
enum ShelfPasteboardReader {
    private struct PayloadType {
        let type: NSPasteboard.PasteboardType
        let utType: UTType

        init(_ utType: UTType) {
            self.utType = utType
            self.type = NSPasteboard.PasteboardType(utType.identifier)
        }

        init(rawValue: String) {
            self.type = NSPasteboard.PasteboardType(rawValue: rawValue)
            self.utType = UTType(rawValue) ?? .data
        }
    }

    private static let fileTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"),
    ]

    /// Most-specific first. WebKit often sends TIFF, so keep PNG and GIF ahead
    /// of the TIFF preview to preserve transparency and animation.
    private static let imageTypes: [PayloadType] = [
        PayloadType(.png),
        PayloadType(.gif),
        PayloadType(.jpeg),
        PayloadType(.webP),
        PayloadType(.heic),
        PayloadType(.tiff),
    ]

    private static let movieTypes: [PayloadType] = [
        PayloadType(.mpeg4Movie),
        PayloadType(.quickTimeMovie),
    ]

    private static let audioTypes: [PayloadType] = [
        PayloadType(.mp3),
        PayloadType(.mpeg4Audio),
        PayloadType(.wav),
        PayloadType(.aiff),
    ]

    private static let urlTypes: [NSPasteboard.PasteboardType] = [
        .URL,
        NSPasteboard.PasteboardType(rawValue: "text/uri-list"),
    ]

    private static let textTypes: [NSPasteboard.PasteboardType] = [
        .string
    ]

    /// Every type the notch drop view registers for. Text is included so a
    /// dragged selection can be staged and dragged back into an input.
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        fileTypes
            + imageTypes.map(\.type)
            + movieTypes.map(\.type)
            + audioTypes.map(\.type)
            + urlTypes
            + textTypes
    }

    /// Cheap type check for a drag entering the island. Does not read data.
    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: acceptedTypes) != nil
    }

    /// Read all stageable items from a drop. File URLs short-circuit the rest
    /// because a Finder drag may also carry an image preview or text.
    static func readDrops(from pasteboard: NSPasteboard, now: Date = Date())
        -> [ShelfDrop]
    {
        let files = readFileURLs(from: pasteboard)
        if !files.isEmpty {
            return dedupe(files.map(ShelfDrop.file))
        }

        guard let items = pasteboard.pasteboardItems else { return [] }
        var drops: [ShelfDrop] = []
        for item in items {
            if let drop = imageDrop(from: item, now: now) {
                drops.append(drop)
                continue
            }
            if let drop = mediaDrop(from: item, types: movieTypes, kind: .movie, now: now) {
                drops.append(drop)
                continue
            }
            if let drop = mediaDrop(from: item, types: audioTypes, kind: .audio, now: now) {
                drops.append(drop)
                continue
            }
            if let drop = linkDrop(from: item) {
                drops.append(drop)
                continue
            }
            if let drop = textDrop(from: item) {
                drops.append(drop)
            }
        }
        return dedupe(drops)
    }

    // MARK: - Readers

    private static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects =
            pasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL] ?? []
        return objects.filter(\.isFileURL)
    }

    private static func imageDrop(from item: NSPasteboardItem, now: Date)
        -> ShelfDrop?
    {
        for payload in imageTypes {
            guard let data = item.data(forType: payload.type), !data.isEmpty
            else { continue }
            let normalized = normalizedImage(data, type: payload.utType)
            let sourceURL = sourceURL(from: item)
            let name = mediaFileName(
                kind: .image, type: normalized.type, sourceURL: sourceURL, now: now)
            return .data(
                normalized.data, fileName: name, kind: .image,
                sourceURL: sourceURL)
        }
        return nil
    }

    private static func mediaDrop(
        from item: NSPasteboardItem, types: [PayloadType],
        kind: ShelfItemKind, now: Date
    ) -> ShelfDrop? {
        for payload in types {
            guard let data = item.data(forType: payload.type), !data.isEmpty
            else { continue }
            let sourceURL = sourceURL(from: item)
            let name = mediaFileName(
                kind: kind, type: payload.utType, sourceURL: sourceURL, now: now)
            return .data(
                data, fileName: name, kind: kind, sourceURL: sourceURL)
        }
        return nil
    }

    private static func linkDrop(from item: NSPasteboardItem) -> ShelfDrop? {
        for type in urlTypes {
            guard let raw = item.string(forType: type) else { continue }
            let candidate =
                raw.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first { !$0.hasPrefix("#") } ?? raw
            guard let url = webURL(from: candidate) else { continue }
            let title = item.string(
                forType: NSPasteboard.PasteboardType(rawValue: "public.url-name"))
            return .link(url, title: title)
        }
        return nil
    }

    private static func textDrop(from item: NSPasteboardItem) -> ShelfDrop? {
        for type in textTypes {
            guard let raw = item.string(forType: type) else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return .text(text) }
        }
        return nil
    }

    // MARK: - Helpers

    /// A web URL that can be reopened later. Skip browser-only schemes such as
    /// `blob:` and `about:`; those cannot survive a drop into another app.
    static func webURL(from raw: String) -> URL? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("<"), candidate.hasSuffix(">") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        guard
            let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// WebKit sends TIFF for most image drags. Store a PNG instead so upload
    /// inputs and previews get a format they all understand.
    private static func normalizedImage(_ data: Data, type: UTType)
        -> (data: Data, type: UTType)
    {
        guard type == .tiff, let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return (data, type) }
        return (png, .png)
    }

    private static func sourceURL(from item: NSPasteboardItem) -> URL? {
        for type in urlTypes {
            guard let raw = item.string(forType: type) else { continue }
            let candidate =
                raw.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first { !$0.hasPrefix("#") } ?? raw
            if let url = webURL(from: candidate) { return url }
            if let url = URL(string: candidate), url.isFileURL { return url }
        }
        return nil
    }

    private static func mediaFileName(
        kind: ShelfItemKind, type: UTType, sourceURL: URL?, now: Date
    ) -> String {
        let ext = ShelfDropWriter.fileExtension(for: type)
        if let sourceName = sourceURL?.lastPathComponent, !sourceName.isEmpty,
            sourceName != "/"
        {
            let base = (sourceName as NSString).deletingPathExtension
            if !base.isEmpty { return "\(base).\(ext)" }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let prefix: String
        switch kind {
        case .image: prefix = "Image"
        case .movie: prefix = "Video"
        case .audio: prefix = "Audio"
        default: prefix = "Dropped"
        }
        return "\(prefix) \(formatter.string(from: now)).\(ext)"
    }

    private static func dedupe(_ drops: [ShelfDrop]) -> [ShelfDrop] {
        var seen = Set<String>()
        var out: [ShelfDrop] = []
        for drop in drops {
            let key: String
            switch drop {
            case .file(let url): key = "file:\(url.path)"
            case .data(let data, _, let kind, _):
                key = "data:\(kind.rawValue):\(data.hashValue)"
            case .link(let url, _): key = "link:\(url.absoluteString)"
            case .text(let text): key = "text:\(text)"
            }
            if seen.insert(key).inserted { out.append(drop) }
        }
        return out
    }
}
