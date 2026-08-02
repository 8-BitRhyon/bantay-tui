import CoreGraphics
import Foundation

/// Pure geometry and state-machine helpers for the notch island expand animation.
/// All functions are deterministic over their numeric inputs — no AppKit dependency.
public enum IslandMorphStyle: Sendable {
    case spring
    case linear
}

public enum IslandMetrics: Sendable {
    /// Where the island parks when idle (closed): beside the notch or centered
    /// underneath it.
    public enum IslandDockSide: String, Sendable {
        case center
        case left
        case right
    }

    // MARK: - Constants
    public static let expandedWidth: CGFloat = 456
    public static let closedCornerRadius: CGFloat = 8
    public static let expandedCornerRadius: CGFloat = 24
    public static let pillHeight: CGFloat = 36
    public static let headerHeight: CGFloat = 40
    public static let rowHeight: CGFloat = 26
    public static let contentSpacing: CGFloat = 10
    public static let maxExpandedHeight: CGFloat = 560
    public static let hoverCooldown: TimeInterval = 0.22
    public static let idleChipWidth: CGFloat = 120
    public static let dockGap: CGFloat = 8
    public static let notchlessFallbackWidth: CGFloat = 211
    public static let morphDuration: TimeInterval = 0.42
    public static let hoverBounceClosed: CGFloat = 1.02
    public static let hoverBounceExpanded: CGFloat = 1.012

    public static func cornerRadius(expanded: Bool) -> CGFloat {
        expanded ? expandedCornerRadius : closedCornerRadius
    }

    /// Fixed window size — always the expanded size plus corner-radius overhang.
    public static func windowSize() -> CGSize {
        CGSize(width: expandedWidth + expandedCornerRadius * 2, height: maxExpandedHeight)
    }

    /// The closed pill content size.
    public static func closedSize(topInset: CGFloat, notchWidth: CGFloat) -> CGSize {
        CGSize(width: min(max(notchWidth, 0), expandedWidth), height: topInset + pillHeight)
    }

    /// The expanded roster content size, height-capped.
    public static func expandedSize(topInset: CGFloat, agentCount: Int) -> CGSize {
        let h = topInset + headerHeight + CGFloat(agentCount) * rowHeight + contentSpacing
        return CGSize(width: expandedWidth, height: min(h, maxExpandedHeight))
    }

    public static func contentHeight(isExpanded: Bool, topInset: CGFloat, agentCount: Int)
        -> CGFloat
    {
        if isExpanded {
            return expandedSize(topInset: topInset, agentCount: agentCount).height - topInset
        }
        return pillHeight
    }

    public static func notchWidth(
        screenWidth: CGFloat, auxLeft: CGFloat, auxRight: CGFloat, safeTop: CGFloat
    ) -> CGFloat {
        guard safeTop > 0, auxLeft > 0, auxRight > 0 else { return notchlessFallbackWidth }
        let w = screenWidth - auxLeft - auxRight + 2
        return w > 100 ? w : notchlessFallbackWidth
    }

    public static func topInset(safeTop: CGFloat, menuBarHeight: CGFloat) -> CGFloat {
        safeTop > 0 ? safeTop : (menuBarHeight > 0 ? menuBarHeight : 0)
    }

    /// Builds a centered, pixel-aligned window frame, clamped to the display so the
    /// island never hangs off-screen on displays smaller than the fixed window size.
    public static func windowFrame(screenFrame: CGRect, size: CGSize, scale: CGFloat) -> CGRect {
        let fitted = CGSize(
            width: min(size.width, screenFrame.width),
            height: min(size.height, screenFrame.height))
        let r = CGRect(
            x: screenFrame.midX - fitted.width / 2,
            y: screenFrame.maxY - fitted.height,
            width: fitted.width,
            height: fitted.height)
        return alignedToBackingPixelGrid(r, scale: scale)
    }

    public static func alignedToBackingPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return (value * s).rounded() / s
    }

    public static func alignedToBackingPixelGrid(_ frame: CGRect, scale: CGFloat) -> CGRect {
        let s = max(scale, 1)
        let minX = alignedToBackingPixel(frame.minX, scale: s)
        let maxX = alignedToBackingPixel(frame.maxX, scale: s)
        let minY = alignedToBackingPixel(frame.minY, scale: s)
        let maxY = alignedToBackingPixel(frame.maxY, scale: s)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The X-origin of the content view so it stays centered in the window.
    public static func centeredContentX(windowWidth: CGFloat, contentWidth: CGFloat) -> CGFloat {
        (windowWidth - contentWidth) / 2
    }

    public static func morphStyle(reduceMotion: Bool) -> IslandMorphStyle {
        reduceMotion ? .linear : .spring
    }

    public static func hoverScale(isHovered: Bool, isExpanded: Bool) -> CGFloat {
        guard isHovered else { return 1 }
        return isExpanded ? hoverBounceExpanded : hoverBounceClosed
    }

    public static func shouldExpand(hovering: Bool, hasAgents: Bool) -> Bool {
        hovering && hasAgents
    }

    public static func shouldCollapse(isExpanded: Bool, hasAgents: Bool) -> Bool {
        isExpanded && !hasAgents
    }

    /// Horizontal shift (in window points) to dock the closed chip beside the
    /// notch instead of under it. Positive shifts right, negative left.
    public static func dockOffset(
        side: IslandDockSide, notchWidth: CGFloat, chipWidth: CGFloat
    ) -> CGFloat {
        guard side != .center else { return 0 }
        let shift = notchWidth / 2 + dockGap + chipWidth / 2
        return side == .left ? -shift : shift
    }

    /// Collapse on hover-exit unless the user is mid-prompt (composing).
    public static func shouldCollapseOnHoverExit(isExpanded: Bool, isComposing: Bool) -> Bool {
        isExpanded && !isComposing
    }

    public static func requiresApproval(_ kind: String) -> Bool {
        kind == "accessRequest" || kind == "access_request"
    }
}
