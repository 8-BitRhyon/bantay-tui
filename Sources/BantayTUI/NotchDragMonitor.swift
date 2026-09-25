import AppKit

extension Notification.Name {
    /// Posted when a file drag enters the notch rectangle (before any drop).
    static let notchFileDragEntered = Notification.Name("notchFileDragEntered")
    /// Posted when file(s) are dropped onto the island window; `userInfo`
    /// carries `"urls"` as `[URL]`.
    static let notchFilesDropped = Notification.Name("notchFilesDropped")
}

/// Monitors global mouse drag gestures approaching the screen notch.
@MainActor
final class NotchDragMonitor {
    private var monitor: Any?
    private var wasNearNotch = false
    private var running = false
    private var lastCheckedAt: TimeInterval = 0

    /// The rect (screen coords) the cursor must enter to count as "at the
    /// notch": the top strip of the island screen, notch width ± padding.
    func notchRect(screen: NSScreen) -> CGRect {
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let safeTop = screen.safeAreaInsets.top
        let notchW = IslandMetrics.notchWidth(
            screenWidth: screen.frame.width,
            auxLeft: left, auxRight: right,
            safeTop: safeTop)
        // The notch sits centered in the top strip between the aux areas.
        let x = screen.frame.minX + left + (screen.frame.width - left - right - notchW) / 2
        let y = screen.frame.maxY - safeTop
        return CGRect(
            x: x - 24, y: y - 40,
            width: notchW + 48, height: 40 + safeTop)
    }

    func start() {
        guard monitor == nil else { return }
        running = true
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDrag(event: event)
            }
        }
    }

    func stop() {
        running = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        wasNearNotch = false
    }

    private func handleDrag(event: NSEvent) {
        guard running else { return }
        // Cheap pre-filter on the event thread: a drag anywhere in the top
        // 120pt of a screen is the only thing that can reach the notch, and
        // we only need to re-check ~every 50ms. Cuts the per-event main-actor
        // hop + pasteboard read during ordinary drags to a fraction.
        let now = event.timestamp
        guard now - lastCheckedAt > 0.05 else { return }
        lastCheckedAt = now
        // NSEvent.mouseLocation is global screen coords (bottom-left origin),
        // the same space as NSScreen.frame — no flip needed.
        let screenPoint = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: {
                $0.frame.insetBy(dx: -2, dy: -2).contains(screenPoint)
            }), screen.safeAreaInsets.top > 0
        else {
            wasNearNotch = false
            return
        }
        guard screen.frame.maxY - screenPoint.y < 120 else {
            wasNearNotch = false
            return
        }
        // A file drag is in progress iff the pasteboard carries file URLs.
        let isFileDrag =
            NSPasteboard(name: .drag)
            .canReadObject(forClasses: [NSURL.self])
        let rect = notchRect(screen: screen)
        let near = isFileDrag && rect.insetBy(dx: -8, dy: -8).contains(screenPoint)

        if near && !wasNearNotch {
            wasNearNotch = true
            NotificationCenter.default.post(name: .notchFileDragEntered, object: nil)
        } else if !near {
            wasNearNotch = false
        }
    }
}
