import AppKit
import Foundation

/// Warns when another window manager or snapping tool is running. Two
/// tools fighting over the same window produce jitter that looks like a
/// strip bug, so the first run should say who else is in the room.
public enum StripConflictDetector {
    /// Bundle ids and display names for tools that also move windows.
    public static let knownConflicts: [(bundleID: String, name: String)] = [
        ("com.knollsoft.Rectangle", "Rectangle"),
        ("com.knollsoft.RectanglePro", "Rectangle Pro"),
        ("com.manytricks.Moom", "Moom"),
        ("com.hegenberg.BetterSnapTool", "BetterSnapTool"),
        ("com.hegenberg.BetterTouchTool", "BetterTouchTool"),
        ("com.koekeishiya.yabai", "yabai"),
        ("bobko.AeroSpace", "AeroSpace"),
        ("com.amethyst.Amethyst", "Amethyst"),
        ("com.if.Amphetamine", "Amphetamine"),
        ("com.windowflow", "WindowFlow"),
        ("com.michaelvillar.Loop", "Loop"),
    ]

    /// Names of conflicting tools that are running right now.
    public static func running(
        applications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> [String] {
        let bundles = Set(applications.compactMap(\.bundleIdentifier))
        return
            knownConflicts
            .filter { bundles.contains($0.bundleID) }
            .map(\.name)
    }
}
