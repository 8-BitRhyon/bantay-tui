import AppKit
import SwiftUI

/// Floating border halo overlay that visually frames active AI agent windows.
struct StripHaloView: View {
    let windowInfo: StripWindowInfo
    let isFocused: Bool
    let dimInactive: Bool

    @State private var pulse: Bool = false

    private var statusColor: Color {
        if windowInfo.agentStatus != .idle {
            switch windowInfo.agentStatus {
            case .needsApproval:
                return Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)  // Amber
            case .working:
                return Color(red: 6 / 255, green: 182 / 255, blue: 212 / 255)  // Cyan
            case .completed:
                return Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255)  // Emerald
            case .failed:
                return Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)  // Crimson
            case .idle:
                break
            }
        }
        return isFocused
            ? Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)  // Focus amber border
            : Color.white.opacity(0.12)
    }

    private var headerTitle: String {
        if let badge = badgeText {
            return badge
        }
        let t = windowInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && t != "Window" {
            let parts = t.components(separatedBy: " - ")
            return parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? t
        }
        if !windowInfo.appBundleID.isEmpty {
            return windowInfo.appBundleID.split(separator: ".").last.map(String.init)?.capitalized
                ?? "Window"
        }
        return "Window"
    }

    private var badgeText: String? {
        guard let name = windowInfo.agentName else { return nil }
        switch windowInfo.agentStatus {
        case .needsApproval:
            return "🟡 \(name.capitalized): Approval Required (⌃⌥A)"
        case .working:
            return "⚡ \(name.capitalized): Running…"
        case .completed:
            return "🟢 \(name.capitalized): Completed"
        case .failed:
            return "🔴 \(name.capitalized): Failed"
        case .idle:
            return name.capitalized
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Inactive window dimming
            if dimInactive && !isFocused {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            }

            // Window focus border
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused ? statusColor : Color.clear,
                    lineWidth: windowInfo.agentStatus == .needsApproval ? 3.0 : 2.5
                )
                .shadow(
                    color: isFocused ? statusColor.opacity(pulse ? 0.8 : 0.4) : Color.clear,
                    radius: windowInfo.agentStatus == .needsApproval ? 10 : 6
                )

            // Header title pill above the window
            Text(headerTitle)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(isFocused ? .white : .white.opacity(0.65))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(isFocused ? 0.85 : 0.5))
                        .overlay(
                            Capsule()
                                .stroke(
                                    isFocused ? statusColor : Color.white.opacity(0.15),
                                    lineWidth: 1)
                        )
                )
                .padding(.top, 8)
        }
        .onAppear {
            if windowInfo.agentStatus == .needsApproval || windowInfo.agentStatus == .working {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }
}

/// Floating circular chevron button for sliding the strip left or right.
struct StripChevronView: View {
    let direction: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isHovered ? 0.95 : 0.82))
                    .frame(width: 40, height: 40)
                    .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)

                Image(systemName: direction == "left" ? "chevron.left" : "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.black.opacity(isEnabled ? 0.85 : 0.25))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.25)
        .onHover { isHovered = $0 }
    }
}

/// Panel manager that projects non-interactive status border halos onto macOS windows.
@MainActor
public final class StripOverlayRenderer {
    public static let shared = StripOverlayRenderer()

    private var haloPanels: [String: NSPanel] = [:]
    private var leftChevronPanel: NSPanel?
    private var rightChevronPanel: NSPanel?

    private init() {}

    /// Updates halo overlay positions, dimming, and edge navigation chevrons.
    public func updateHalos(
        windows: [StripWindowInfo],
        frames: [String: StripRect],
        focusedWindowID: String?,
        enabled: Bool,
        dimInactive: Bool,
        showChevrons: Bool,
        canFocusLeft: Bool,
        canFocusRight: Bool,
        screenBounds: NSRect
    ) {
        guard enabled else {
            hideAll()
            return
        }

        var activeIDs = Set<String>()

        for win in windows {
            guard let frame = frames[win.id] else { continue }

            let isAgent = win.agentName != nil || win.agentStatus != .idle
            let isFocused = (win.id == focusedWindowID)
            guard isAgent || isFocused || dimInactive else { continue }

            // Check if frame intersects screen bounds
            let winNSRect = NSRect(
                x: frame.x,
                // AppKit coordinates flip Y (origin is bottom-left of screen)
                y: screenBounds.maxY - frame.y - frame.height,
                width: frame.width,
                height: frame.height
            )

            guard winNSRect.intersects(screenBounds) else { continue }

            activeIDs.insert(win.id)
            let panel = haloPanels[win.id] ?? makeHaloPanel()
            haloPanels[win.id] = panel

            panel.contentView = NSHostingView(
                rootView: StripHaloView(
                    windowInfo: win,
                    isFocused: isFocused,
                    dimInactive: dimInactive
                )
            )
            panel.setFrame(winNSRect, display: true)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        // Hide stale panels
        for (id, panel) in haloPanels where !activeIDs.contains(id) {
            panel.orderOut(nil)
            haloPanels.removeValue(forKey: id)
        }

        // Update navigation chevrons
        updateChevrons(
            showChevrons: showChevrons && frames.count > 1,
            canFocusLeft: canFocusLeft,
            canFocusRight: canFocusRight,
            screenBounds: screenBounds
        )
    }

    private func updateChevrons(
        showChevrons: Bool,
        canFocusLeft: Bool,
        canFocusRight: Bool,
        screenBounds: NSRect
    ) {
        guard showChevrons else {
            leftChevronPanel?.orderOut(nil)
            rightChevronPanel?.orderOut(nil)
            return
        }

        let y = screenBounds.midY - 20.0

        // Left Chevron
        let leftRect = NSRect(x: screenBounds.minX + 16.0, y: y, width: 44.0, height: 44.0)
        let lPanel = leftChevronPanel ?? makeChevronPanel()
        leftChevronPanel = lPanel
        lPanel.contentView = NSHostingView(
            rootView: StripChevronView(
                direction: "left",
                isEnabled: canFocusLeft,
                action: { StripWindowManager.shared.focusLeft() }
            )
        )
        lPanel.setFrame(leftRect, display: true)
        if !lPanel.isVisible { lPanel.orderFrontRegardless() }

        // Right Chevron
        let rightRect = NSRect(x: screenBounds.maxX - 60.0, y: y, width: 44.0, height: 44.0)
        let rPanel = rightChevronPanel ?? makeChevronPanel()
        rightChevronPanel = rPanel
        rPanel.contentView = NSHostingView(
            rootView: StripChevronView(
                direction: "right",
                isEnabled: canFocusRight,
                action: { StripWindowManager.shared.focusRight() }
            )
        )
        rPanel.setFrame(rightRect, display: true)
        if !rPanel.isVisible { rPanel.orderFrontRegardless() }
    }

    /// Hides all halo and chevron panels.
    public func hideAll() {
        for panel in haloPanels.values {
            panel.orderOut(nil)
        }
        haloPanels.removeAll()
        leftChevronPanel?.orderOut(nil)
        rightChevronPanel?.orderOut(nil)
    }

    private func makeHaloPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func makeChevronPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}
