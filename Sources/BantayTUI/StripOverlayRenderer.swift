import AppKit
import SwiftUI

/// Floating border halo overlay that visually frames active AI agent windows.
struct StripHaloView: View {
    let windowInfo: StripWindowInfo
    let isFocused: Bool

    @State private var pulse: Bool = false

    private var statusColor: Color {
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
            return isFocused
                ? Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255).opacity(0.8)
                : Color.white.opacity(0.12)
        }
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
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    statusColor,
                    lineWidth: windowInfo.agentStatus == .needsApproval ? 3.0 : 2.0
                )
                .shadow(
                    color: statusColor.opacity(pulse ? 0.8 : 0.4),
                    radius: windowInfo.agentStatus == .needsApproval ? 10 : 5
                )

            if let badge = badgeText {
                Text(badge)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.85))
                            .overlay(
                                Capsule()
                                    .stroke(statusColor, lineWidth: 1)
                            )
                    )
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
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

/// Panel manager that projects non-interactive status border halos onto macOS windows.
@MainActor
public final class StripOverlayRenderer {
    public static let shared = StripOverlayRenderer()

    private var haloPanels: [String: NSPanel] = [:]

    private init() {}

    /// Updates halo overlay positions and visibility.
    public func updateHalos(
        windows: [StripWindowInfo],
        frames: [String: StripRect],
        focusedWindowID: String?,
        enabled: Bool,
        screenBounds: NSRect
    ) {
        guard enabled else {
            hideAll()
            return
        }

        var activeIDs = Set<String>()

        for win in windows {
            guard let frame = frames[win.id] else { continue }

            // Only draw halo if window is an agent or currently focused, and within screen bounds
            let isAgent = win.agentName != nil || win.agentStatus != .idle
            let isFocused = (win.id == focusedWindowID)
            guard isAgent || isFocused else { continue }

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
                rootView: StripHaloView(windowInfo: win, isFocused: isFocused)
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
    }

    /// Hides all halo panels.
    public func hideAll() {
        for panel in haloPanels.values {
            panel.orderOut(nil)
        }
        haloPanels.removeAll()
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
}
