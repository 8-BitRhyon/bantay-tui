import AppKit
import SwiftUI

/// Tracks the active on-screen interactive bounds of the island.
@MainActor
public enum IslandHitTracker {
    public static var interactiveRect: NSRect = .zero

    /// The island's interactive bounds in screen coordinates. SwiftUI reports
    /// `.global` frames in window content space with a top-left origin, while
    /// AppKit windows use a bottom-left screen origin. Returns nil until the
    /// island has reported a non-empty frame.
    public static func interactiveScreenRect(in window: NSWindow) -> NSRect? {
        let rect = interactiveRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return IslandMetrics.screenRect(
            fromGlobalRect: rect, windowFrame: window.frame)
    }
}

/// Hosting view that takes the first mouse click even when its window is a
/// non-activating panel. The hit-tested view, not its container, decides
/// whether a click is delivered, so the override must live here.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// AppKit drag destination hosting SwiftUI island content.
final class FileDropContentView<Content: View>: NSView {
    let hosting: FirstMouseHostingView<Content>

    init(rootView: Content) {
        hosting = FirstMouseHostingView(rootView: rootView)
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        registerForDraggedTypes(ShelfPasteboardReader.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(ShelfPasteboardReader.acceptedTypes)
    }

    override var isFlipped: Bool { true }

    /// The island is a non-activating panel: without this, the first click
    /// on a notification button only brings the panel forward and the button
    /// never fires. Accepting the first mouse makes controls work while the
    /// terminal or browser stays frontmost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

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
        guard ShelfPasteboardReader.canAccept(sender.draggingPasteboard) else {
            return []
        }
        // Announce so the island expands to the shelf while hovering.
        NotificationCenter.default.post(name: .notchFileDragEntered, object: nil)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ShelfPasteboardReader.canAccept(sender.draggingPasteboard) else {
            return []
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // No-op: keep the shelf open while the drop is in flight.
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let drops = ShelfPasteboardReader.readDrops(from: sender.draggingPasteboard)
        guard !drops.isEmpty else { return false }
        NotificationCenter.default.post(
            name: .notchFilesDropped, object: nil, userInfo: ["drops": drops])
        return true
    }
}
