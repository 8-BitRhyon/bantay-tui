import AppKit
import SwiftUI

/// File URL pasteboard types recognized for Finder file drags.
private enum FileDropTypes {
    static let all: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType(rawValue: "public.file-url"),
        NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"),
    ]
}

/// Tracks the active on-screen interactive bounds of the island.
@MainActor
public enum IslandHitTracker {
    public static var interactiveRect: NSRect = .zero
}

/// AppKit drag destination hosting SwiftUI island content.
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

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let activeRect = MainActor.assumeIsolated { IslandHitTracker.interactiveRect }
        guard activeRect != .zero else { return super.hitTest(point) }
        let localPoint = convert(point, from: superview)
        let hitTarget = activeRect.insetBy(dx: -12, dy: -12)
        guard hitTarget.contains(localPoint) else { return nil }
        return super.hitTest(point)
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
