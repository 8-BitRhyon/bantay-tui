#if canImport(Testing)
    import AppKit
    import Foundation
    import Testing
    import UniformTypeIdentifiers

    @testable import BantayTUI

    @MainActor
    @Suite("Shelf drag-in and drag-out")
    struct ShelfDragTests {
        // MARK: - Pasteboard readers

        @Test("an image drop from a browser becomes image data")
        func browserImage() throws {
            let pasteboard = makePasteboard()
            let item = NSPasteboardItem()
            item.setData(Data("png-bytes".utf8), forType: .png)
            item.setString("https://cdn.example.com/cat.png", forType: .URL)
            pasteboard.writeObjects([item])

            let drops = ShelfPasteboardReader.readDrops(from: pasteboard)
            #expect(drops.count == 1)
            guard case .data(let data, let name, let kind, let source) = drops[0] else {
                Issue.record("expected an image data drop")
                return
            }
            #expect(data == Data("png-bytes".utf8))
            #expect(kind == .image)
            #expect(name == "cat.png")
            #expect(source?.absoluteString == "https://cdn.example.com/cat.png")
        }

        @Test("a TIFF browser image is stored as PNG")
        func tiffImageConversion() throws {
            let tiff = try makeTIFF()
            let pasteboard = makePasteboard()
            let item = NSPasteboardItem()
            item.setData(tiff, forType: .tiff)
            pasteboard.writeObjects([item])

            let drops = ShelfPasteboardReader.readDrops(from: pasteboard)
            guard case .data(let data, let name, let kind, _) = drops.first else {
                Issue.record("expected image data")
                return
            }
            #expect(kind == .image)
            #expect(name.hasSuffix(".png"))
            #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }

        @Test("a dragged link keeps its title and URL")
        func browserLink() {
            let pasteboard = makePasteboard()
            let item = NSPasteboardItem()
            item.setString("https://example.com/watch?v=1", forType: .URL)
            item.setString("A video", forType: .init(rawValue: "public.url-name"))
            pasteboard.writeObjects([item])

            let drops = ShelfPasteboardReader.readDrops(from: pasteboard)
            guard case .link(let url, let title) = drops.first else {
                Issue.record("expected a link drop")
                return
            }
            #expect(url.absoluteString == "https://example.com/watch?v=1")
            #expect(title == "A video")
        }

        @Test("a file URL wins over the preview types inside the same drag")
        func fileWins() {
            let file = URL(fileURLWithPath: "/tmp/bantay-shelf-test.png")
            let pasteboard = makePasteboard()
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            item.setData(Data("preview".utf8), forType: .png)
            pasteboard.writeObjects([item])

            let drops = ShelfPasteboardReader.readDrops(from: pasteboard)
            guard case .file(let url) = drops.first else {
                Issue.record("expected a file drop")
                return
            }
            #expect(url == file)
            #expect(drops.count == 1)
        }

        @Test("dragged text becomes a text drop")
        func draggedText() {
            let pasteboard = makePasteboard()
            let item = NSPasteboardItem()
            item.setString("hello from a browser", forType: .string)
            pasteboard.writeObjects([item])

            let drops = ShelfPasteboardReader.readDrops(from: pasteboard)
            guard case .text(let text) = drops.first else {
                Issue.record("expected a text drop")
                return
            }
            #expect(text == "hello from a browser")
        }

        @Test("non-reopenable browser URLs are rejected")
        func rejectsBlobURL() {
            #expect(ShelfPasteboardReader.webURL(from: "blob:https://example.com/123") == nil)
            #expect(ShelfPasteboardReader.webURL(from: "javascript:alert(1)") == nil)
        }

        @Test("the drop view accepts images, files, links, and text")
        func acceptsStageableDrags() {
            let image = makePasteboard()
            let imageItem = NSPasteboardItem()
            imageItem.setData(Data([1, 2, 3]), forType: .png)
            image.writeObjects([imageItem])
            #expect(ShelfPasteboardReader.canAccept(image))

            let link = makePasteboard()
            let linkItem = NSPasteboardItem()
            linkItem.setString("https://example.com", forType: .URL)
            link.writeObjects([linkItem])
            #expect(ShelfPasteboardReader.canAccept(link))
        }

        // MARK: - Writers

        @Test("image bytes are materialized as a real shelf file")
        func writesImageFile() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = URL(string: "https://cdn.example.com/cat.png")!
            let drop = ShelfDrop.data(
                Data("image".utf8), fileName: "cat.png", kind: .image,
                sourceURL: source)

            let file = try #require(
                ShelfDropWriter.write(drop, root: root, now: Date(timeIntervalSince1970: 1_000)))
            #expect(FileManager.default.fileExists(atPath: file.url.path))
            #expect(try Data(contentsOf: file.url) == Data("image".utf8))
            #expect(file.kind == .image)
            #expect(file.name == "cat.png")
            #expect(file.sourceURL == source)
        }

        @Test("a file that cannot be copied is skipped, never staged in place")
        func uncopyableFileIsSkipped() {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let missing = root.appendingPathComponent("missing.png")
            let file = ShelfDropWriter.write(.file(missing), root: root)
            #expect(file == nil)
        }

        @Test("a link becomes a readable .webloc")
        func writesWebloc() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = URL(string: "https://example.com/a")!
            let file = try #require(
                ShelfDropWriter.write(.link(url, title: "Example"), root: root))
            #expect(file.kind == .link)
            #expect(file.linkURL == url)
            #expect(file.displayName == "Example")
            #expect(file.url.pathExtension == "webloc")
        }

        @Test("dragged text becomes a text file with content")
        func writesText() throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = try #require(
                ShelfDropWriter.write(.text("first line\nsecond"), root: root))
            #expect(file.kind == .text)
            #expect(file.displayName == "first line")
            #expect(file.textContent == "first line\nsecond")
        }

        @Test("unsafe file names are sanitized")
        func sanitizesNames() {
            #expect(
                ShelfDropWriter.sanitizedName(
                    "a/b:c.png", fallback: "File", extension: "png") == "a-b-c.png")
            #expect(
                ShelfDropWriter.sanitizedName("photo", fallback: "File", extension: "png")
                    == "photo.png")
        }

        // MARK: - Drag-out providers

        @Test("an image drag offers a file URL and a PNG")
        func imageProviderTypes() throws {
            let url = try temporaryImageFile()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let file = ShelfFile(
                url: url, createdAt: Date(), name: "cat.png", kind: .image)
            let provider = ShelfDragProvider.itemProvider(for: file)
            #expect(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier))
            #expect(provider.registeredTypeIdentifiers.contains(UTType.png.identifier))
            #expect(provider.registeredTypeIdentifiers.contains(UTType.tiff.identifier))
            #expect(provider.suggestedName == "cat.png")
        }

        @Test("a link drag offers a URL and text")
        func linkProviderTypes() {
            let url = URL(string: "https://example.com/a")!
            let file = ShelfFile(
                url: URL(fileURLWithPath: "/tmp/a.webloc"), createdAt: Date(),
                name: "Example", kind: .link, sourceURL: url)
            let provider = ShelfDragProvider.itemProvider(for: file)
            #expect(provider.registeredTypeIdentifiers.contains(UTType.url.identifier))
            #expect(
                provider.registeredTypeIdentifiers.contains(
                    UTType.utf8PlainText.identifier))
        }

        @Test("a text drag offers plain text")
        func textProviderTypes() {
            let file = ShelfFile(
                url: URL(fileURLWithPath: "/tmp/a.txt"), createdAt: Date(),
                name: "Note", kind: .text)
            let provider = ShelfDragProvider.itemProvider(for: file)
            #expect(
                provider.registeredTypeIdentifiers.contains(
                    UTType.utf8PlainText.identifier))
        }

        // MARK: - Helpers

        private func makePasteboard() -> NSPasteboard {
            let name = NSPasteboard.Name("bantay.shelf.tests.\(UUID().uuidString)")
            let pasteboard = NSPasteboard(name: name)
            pasteboard.clearContents()
            return pasteboard
        }

        private func temporaryRoot() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "bantay-shelf-tests-\(UUID().uuidString)", isDirectory: true)
        }

        private func temporaryImageFile() throws -> URL {
            let dir = temporaryRoot()
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("cat.png")
            try Data("image".utf8).write(to: url)
            return url
        }

        private func makeTIFF() throws -> Data {
            let rep = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 2, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            return try #require(rep.tiffRepresentation)
        }
    }
#endif
