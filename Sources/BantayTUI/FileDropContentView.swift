import AppKit
import SwiftUI

/// A real AppKit drag destination that SwiftUI's `.onDrop` cannot be trusted
/// to create. SwiftUI `.onDrop` on a borderless, non-activating accessory
/// panel silently never registers with AppKit (verified: the hosting view's
/// `registeredDraggedTypes` is empty), so no drop ever arrives.
///
/// This view is the window's content view with the SwiftUI island hosted
/// inside it. It registers `.fileURL` itself, returns `.copy` for any file
/// drag, and on drop posts `.notchFilesDropped` so the shelf receives the
/// URLs. The island's own handlers already expand on `.notchFileDragEntered`.
/// File URL pasteboard types a Finder file drag carries.
private enum FileDropTypes {
    static let all: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType(rawValue: "public.file-url"),
        NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"),
    ]
}

final class FileDropContentView<Content: View>: NSView {
    let hosting: NSHostingView<Content>

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        registerForDraggedTypes(FileDropTypes.all)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(FileDropTypes.all)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let hasFile = FileDropTypes.all.contains { pb.availableType(from: [$0]) != nil }
        NSLog("bantay-drop: draggingEntered hasFile=%d", hasFile)
        guard hasFile else { return [] }
        // Announce so the island expands to the shelf while hovering.
        NotificationCenter.default.post(name: .notchFileDragEntered, object: nil)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        NSLog("bantay-drop: draggingExited")
        // No-op: keep the shelf open while the drop is in flight.
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        NSLog("bantay-drop: performDragOperation urls=%d", urls?.count ?? -1)
        guard let urls, !urls.isEmpty else {
            return false
        }
        NotificationCenter.default.post(
            name: .notchFilesDropped, object: nil, userInfo: ["urls": urls])
        return true
    }
}
