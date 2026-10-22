import AppKit
import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: inout CGWindowID)
    -> AXError

/// Reference to a native macOS window tracked on the infinite strip.
@MainActor
public final class StripWindowRegistry {
    public static let shared = StripWindowRegistry()

    private var axElements: [String: AXUIElement] = [:]

    private init() {}

    /// Checks whether Bantay has Accessibility permissions granted.
    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Requests accessibility permission prompt if not already granted.
    public static func promptAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Deep-links directly to macOS System Settings Accessibility pane.
    public static func openAccessibilitySettings() {
        if let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Scans the system for movable, regular application windows.
    public func scanWindows(
        ignoredBundleIDs: [String] = StripConfiguration.defaultIgnoredBundleIDs
    ) -> [StripWindowInfo] {
        guard Self.hasAccessibilityPermission() else { return [] }

        var results: [StripWindowInfo] = []
        var activeIDs = Set<String>()

        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, !app.isHidden else { return false }
            guard let bundleID = app.bundleIdentifier else { return false }
            let lower = bundleID.lowercased()
            return !ignoredBundleIDs.contains { $0.lowercased() == lower }
        }

        let agentRoster = AgentEventManager.shared.agents

        for app in runningApps {
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier ?? ""
            let appRef = AXUIElementCreateApplication(pid)

            // Ensure Electron and Chromium apps expose accessibility window tree
            _ = AXUIElementSetAttributeValue(
                appRef, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)

            var axWindows: [AXUIElement] = []
            var seenElements = Set<CFHashCode>()

            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
                == .success,
                let wins = windowsRef as? [AXUIElement]
            {
                for w in wins {
                    let hash = CFHash(w)
                    if !seenElements.contains(hash) {
                        seenElements.insert(hash)
                        axWindows.append(w)
                    }
                }
            }

            var mainRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &mainRef)
                == .success,
                let w = mainRef as! AXUIElement?
            {
                let hash = CFHash(w)
                if !seenElements.contains(hash) {
                    seenElements.insert(hash)
                    axWindows.append(w)
                }
            }

            var focusRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appRef, kAXFocusedWindowAttribute as CFString, &focusRef) == .success,
                let w = focusRef as! AXUIElement?
            {
                let hash = CFHash(w)
                if !seenElements.contains(hash) {
                    seenElements.insert(hash)
                    axWindows.append(w)
                }
            }

            guard !axWindows.isEmpty else { continue }

            for (index, windowRef) in axWindows.enumerated() {
                // Verify window role and subrole
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(windowRef, kAXRoleAttribute as CFString, &roleRef)
                guard let role = roleRef as? String, role == (kAXWindowRole as String) else {
                    continue
                }

                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(
                    windowRef, kAXSubroleAttribute as CFString, &subroleRef)
                if let subrole = subroleRef as? String {
                    // Ignore dialogs, sheets, floating palettes, drawer windows
                    if subrole == (kAXDialogSubrole as String)
                        || subrole == (kAXSystemDialogSubrole as String)
                        || subrole == (kAXFloatingWindowSubrole as String)
                    {
                        continue
                    }
                }

                // Check minimized state
                var minRef: CFTypeRef?
                AXUIElementCopyAttributeValue(
                    windowRef, kAXMinimizedAttribute as CFString, &minRef)
                if let isMinimized = minRef as? Bool, isMinimized {
                    continue
                }

                // Check window dimensions (ignore tiny popups/tooltips)
                var sizeRef: CFTypeRef?
                var size = CGSize.zero
                if AXUIElementCopyAttributeValue(
                    windowRef, kAXSizeAttribute as CFString, &sizeRef) == .success,
                    let val = sizeRef
                {
                    AXValueGetValue(val as! AXValue, .cgSize, &size)
                    if size.width < 140 || size.height < 140 {
                        continue
                    }
                }

                // Window Title
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(
                    windowRef, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? app.localizedName ?? "Window"

                var wid: CGWindowID = 0
                let windowID: String
                if _AXUIElementGetWindow(windowRef, &wid) == .success, wid != 0 {
                    windowID = "\(wid)"
                } else {
                    windowID = "\(pid):\(index):\(bundleID)"
                }
                activeIDs.insert(windowID)
                axElements[windowID] = windowRef

                // Associate with Agent if running an AI coding tool
                let (agentName, agentStatus, agentCwd) = resolveAgent(
                    pid: pid,
                    bundleID: bundleID,
                    title: title,
                    roster: agentRoster
                )

                let info = StripWindowInfo(
                    id: windowID,
                    pid: pid,
                    appBundleID: bundleID,
                    title: title,
                    agentName: agentName,
                    agentCwd: agentCwd,
                    agentStatus: agentStatus
                )
                results.append(info)
            }
        }

        // Clean up stale window references
        for key in axElements.keys where !activeIDs.contains(key) {
            axElements.removeValue(forKey: key)
        }

        return results
    }

    /// Positions and resizes a native macOS window.
    public func applyFrame(windowID: String, frame: StripRect) {
        guard let windowRef = axElements[windowID] else { return }

        var sz = CGSize(width: frame.width, height: frame.height)
        if let szVal = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(windowRef, kAXSizeAttribute as CFString, szVal)
        }

        var pt = CGPoint(x: frame.x, y: frame.y)
        if let ptVal = AXValueCreate(.cgPoint, &pt) {
            AXUIElementSetAttributeValue(windowRef, kAXPositionAttribute as CFString, ptVal)
        }

        // Set size once more if window bounds clamped during position shift
        if let szVal = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(windowRef, kAXSizeAttribute as CFString, szVal)
        }
    }

    /// Focuses and raises a native macOS window.
    public func focusWindow(windowID: String) {
        guard let windowRef = axElements[windowID] else { return }
        AXUIElementSetAttributeValue(windowRef, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(windowRef, kAXRaiseAction as CFString)

        // Extract PID to activate parent app
        let components = windowID.split(separator: ":")
        if let pidStr = components.first, let pid = Int32(pidStr) {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    /// Resolves agent family and status from process information and window titles.
    private func resolveAgent(
        pid: Int32,
        bundleID: String,
        title: String,
        roster: [AgentSnapshot]
    ) -> (name: String?, status: StripAgentStatus, cwd: String?) {
        let titleLower = title.lowercased()
        let bundleLower = bundleID.lowercased()

        // 1. Direct match from active AgentEventManager roster
        for agent in roster {
            let src = agent.source.lowercased()
            if titleLower.contains(src) || bundleLower.contains(src) {
                let status = StripAgentStatus(eventKind: agent.kind)
                return (agent.source, status, agent.cwd)
            }
        }

        // 2. Check title keywords for common CLI agents
        let knownAgents = [
            "claude": "claude",
            "codex": "codex",
            "kilo": "kilo",
            "opencode": "opencode",
            "cursor": "cursor",
            "antigravity": "antigravity",
            "windsurf": "windsurf",
            "gemini": "gemini",
        ]

        for (keyword, name) in knownAgents {
            if titleLower.contains(keyword) || bundleLower.contains(keyword) {
                return (name, .idle, nil)
            }
        }

        return (nil, .idle, nil)
    }
}
