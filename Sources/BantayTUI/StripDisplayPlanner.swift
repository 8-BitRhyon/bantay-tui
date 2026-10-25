import AppKit
import Foundation

/// Maps windows to displays and enforces per-display strip policy.
///
/// The strip tiles one display at a time. Windows that live on another
/// display are never pulled across screens; each display keeps its own
/// windows where the user put them.
public enum StripDisplayPlanner {
    /// Stable key for a screen: CGDirectDisplayID survives launches.
    public static func displayKey(for screen: NSScreen) -> String {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else { return "display-unknown" }
        return StripSessionStore.displayKey(number.uint32Value)
    }

    /// Display that contains the window's center. Falls back to the display
    /// with the largest overlap, then to the first display. Nil only when no
    /// screens are supplied.
    public static func displayKey(
        origin: StripRect,
        screens: [(key: String, frame: NSRect)]
    ) -> String? {
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: origin.x + origin.width / 2, y: origin.y + origin.height / 2)
        if let hit = screens.first(where: { $0.frame.contains(center) }) {
            return hit.key
        }
        var best: (key: String, area: CGFloat)?
        for screen in screens {
            let overlap = screen.frame.intersection(
                NSRect(x: origin.x, y: origin.y, width: origin.width, height: origin.height))
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (screen.key, area) }
        }
        if let best, best.area > 0 { return best.key }
        return screens.first?.key
    }

    /// Live screen geometry for the planner.
    public static func currentScreens() -> [(key: String, frame: NSRect)] {
        NSScreen.screens.map { (key: displayKey(for: $0), frame: $0.frame) }
    }

    /// Display that should own the strip right now: the one showing the
    /// focused window, else the one under the pointer, else the main screen.
    public static func activeDisplayKey(
        focusedWindowOrigin: StripRect?,
        mouse: CGPoint,
        screens: [(key: String, frame: NSRect)]
    ) -> String? {
        if let focusedWindowOrigin,
            let key = displayKey(origin: focusedWindowOrigin, screens: screens)
        {
            return key
        }
        if let hit = screens.first(where: { $0.frame.contains(mouse) }) {
            return hit.key
        }
        return screens.first?.key
    }

    /// Windows the strip may tile on `displayKey`: their own display only,
    /// and never a display the user switched off.
    public static func eligible(
        windows: [StripWindowInfo],
        displayKey: String,
        disabledDisplayKeys: [String]
    ) -> [StripWindowInfo] {
        guard !disabledDisplayKeys.contains(displayKey) else { return [] }
        return windows.filter { window in
            guard !window.displayKey.isEmpty else { return true }
            return window.displayKey == displayKey
        }
    }
}
