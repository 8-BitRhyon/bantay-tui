import Foundation

/// Sendable snapshot of live strip state for the control gateway.
public struct StripStatusSnapshot: Sendable {
    public struct Window: Sendable {
        public let id: String
        public let pid: Int32
        public let appBundleID: String
        public let title: String
        public let agent: String
        public let agentCwd: String
        public let status: String
    }

    public struct Column: Sendable {
        public let index: Int
        public let widthFraction: Double
        public let isTabbed: Bool
        public let isPinned: Bool
        public let activeWindowID: String
        public let activeWindowTitle: String
        public let windows: [Window]
    }

    public let enabled: Bool
    public let defaultWidthPreset: Double
    public let gap: Double
    public let inset: Double
    public let overview: Bool
    public let isFullScreen: Bool
    public let activeColumnIndex: Int
    public let accessibility: Bool
    public let columns: [Column]

    /// JSON-safe representation for the NDJSON control gateway.
    public var jsonObject: [String: Any] {
        [
            "enabled": enabled,
            "defaultWidthPreset": defaultWidthPreset,
            "gap": gap,
            "inset": inset,
            "overview": overview,
            "isFullScreen": isFullScreen,
            "activeColumnIndex": activeColumnIndex,
            "accessibility": accessibility,
            "columns": columns.map { column -> [String: Any] in
                [
                    "index": column.index,
                    "widthFraction": column.widthFraction,
                    "isTabbed": column.isTabbed,
                    "isPinned": column.isPinned,
                    "activeWindowID": column.activeWindowID,
                    "activeWindowTitle": column.activeWindowTitle,
                    "windows": column.windows.map { window -> [String: Any] in
                        [
                            "id": window.id,
                            "pid": Int(window.pid),
                            "appBundleID": window.appBundleID,
                            "title": window.title,
                            "agent": window.agent,
                            "agentCwd": window.agentCwd,
                            "status": window.status,
                        ]
                    },
                ]
            },
        ]
    }
}

/// Bridge between the AppKit strip manager and the control gateway. The app
/// installs the provider at launch. The pure logic harness compiles this file
/// without the UI-only window manager.
public enum StripStatusProvider {
    @MainActor public static var current: (() -> StripStatusSnapshot)?
}
