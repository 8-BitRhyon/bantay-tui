import AppKit
import Foundation
import UniformTypeIdentifiers

/// Builds the drag-out payload for a shelf card. Files and images carry a
/// file URL plus their native type so Finder, upload inputs, and editors all
/// accept them. Links drag as a URL and text so a plain input receives the
/// address instead of a `.webloc` filename.
enum ShelfDragProvider {
    static func itemProvider(for file: ShelfFile) -> NSItemProvider {
        switch file.kind {
        case .link:
            guard let url = file.linkURL else { return fallbackProvider(for: file) }
            let provider = NSItemProvider(object: url as NSURL)
            provider.suggestedName = file.displayName
            provider.registerObject(
                url.absoluteString as NSString, visibility: .all)
            return provider
        case .text:
            let text = file.textContent ?? ""
            let provider = NSItemProvider(object: text as NSString)
            provider.suggestedName = file.displayName
            return provider
        case .file, .image, .movie, .audio:
            let provider =
                NSItemProvider(contentsOf: file.url)
                ?? NSItemProvider(object: file.url as NSURL)
            provider.suggestedName = file.displayName
            if file.kind == .image {
                registerTIFFRepresentation(on: provider, url: file.url)
            }
            return provider
        }
    }

    private static func fallbackProvider(for file: ShelfFile) -> NSItemProvider {
        let provider = NSItemProvider(object: file.url as NSURL)
        provider.suggestedName = file.displayName
        return provider
    }

    /// Rich text editors often ask for TIFF even when the shelf file is a PNG.
    /// Register TIFF data lazily so those editors receive pixels, not a path.
    private static func registerTIFFRepresentation(
        on provider: NSItemProvider, url: URL
    ) {
        guard !provider.registeredTypeIdentifiers.contains(UTType.tiff.identifier)
        else { return }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.tiff.identifier, visibility: .all
        ) { completion in
            do {
                let data = try Data(contentsOf: url)
                guard let bitmap = NSBitmapImageRep(data: data),
                    let tiff = bitmap.tiffRepresentation
                else {
                    completion(
                        nil,
                        NSError(
                            domain: "ShelfDragProvider", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Could not convert the shelf image to TIFF."
                            ]))
                    return nil
                }
                completion(tiff, nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
    }
}

/// Tracks a shelf drag until the mouse goes up. The notch is hover-driven, so
/// without this the island collapses as soon as the pointer leaves it, which
/// would cancel the drag before it reaches the target app.
///
/// Polling `pressedMouseButtons` avoids the Accessibility permission that a
/// global mouse-up monitor needs. The app must keep working for users who have
/// not granted that permission.
@MainActor
enum ShelfDragSession {
    private static var endTask: Task<Void, Never>?
    private static var generation: UInt = 0

    static func begin() {
        guard endTask == nil else { return }
        generation &+= 1
        let current = generation
        NotificationCenter.default.post(name: .notchDragOutStarted, object: nil)
        endTask = Task { @MainActor in
            // `.onDrag` fires when a drag starts, but a short click can still
            // cancel it. Give the session a beat before polling.
            try? await Task.sleep(for: .milliseconds(120))
            while !Task.isCancelled {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    finish(current)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func end() {
        finish(generation)
    }

    /// A late poll from an old session must not end a new drag.
    private static func finish(_ id: UInt) {
        guard id == generation, let task = endTask else { return }
        endTask = nil
        task.cancel()
        NotificationCenter.default.post(name: .notchDragOutEnded, object: nil)
    }
}
