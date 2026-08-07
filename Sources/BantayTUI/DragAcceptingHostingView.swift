import AppKit
import SwiftUI

/// The file URL pasteboard types a Finder file drag carries.
private enum FileDragTypes {
    static let all: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType(rawValue: "public.file-url"),
        NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"),
    ]
}

/// A hosting view that also accepts file drops. Drag events land on the
/// view under the cursor, NOT the window — registering the window as an
/// NSDraggingDestination does nothing because the hosting view swallows the
/// drag. This view is the actual destination: it checks the drag TYPE on
/// enter (readObjects fails mid-drag on modern macOS), accepts .copy, and
/// on drop posts `.notchFilesDropped` for the shelf.
final class DragAcceptingHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes(FileDragTypes.all)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(FileDragTypes.all)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-register after the window attach: some hosts drop registrations.
        registerForDraggedTypes(FileDragTypes.all)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let hasFile = FileDragTypes.all.contains { pb.availableType(from: [$0]) != nil }
        guard hasFile else { return [] }
        NotificationCenter.default.post(name: .notchFileDragEntered, object: nil)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // No-op: the shelf stays open; only a successful drop matters.
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])
                as? [URL], !urls.isEmpty
        else {
            return false
        }
        NotificationCenter.default.post(
            name: .notchFilesDropped, object: nil, userInfo: ["urls": urls])
        return true
    }
}
