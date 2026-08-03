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

    /// How the closed idle chip presents live agent activity on the sides of
    /// the notch.
    public enum IdleStyle: String, Sendable {
        /// One small severity dot per agent (most glanceable, least text).
        case dots
        /// Dot + agent name chips, up to `idleMaxChips`, `+N` overflow.
        case names
        /// Dot + a single "N agents" summary.
        case summary
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
    public static let dockGap: CGFloat = 0
    public static let notchlessFallbackWidth: CGFloat = 211
    public static let morphDuration: TimeInterval = 0.42
    public static let hoverBounceClosed: CGFloat = 1.02
    public static let hoverBounceExpanded: CGFloat = 1.012

    // MARK: - Idle agent strip
    /// Max agents shown as chips in the idle strip before `+N`.
    public static let idleDefaultMaxChips: Int = 3
    /// Horizontal padding inside a chip.
    public static let idleChipHPad: CGFloat = 10
    /// Gap between the severiy dot and the chip label.
    public static let idleChipDotGap: CGFloat = 5
    /// Gap between adjacent chips in a strip.
    public static let idleChipGap: CGFloat = 4
    /// Severity dot diameter.
    public static let idleDotSize: CGFloat = 5
    /// Overflow label width when more agents exist than shown chips.
    public static let idleOverflowPad: CGFloat = 16

    /// Width of one dot-only chip (also the "dots" style chip).
    public static func idleDotsChipWidth(dotCount: Int) -> CGFloat {
        let dots = min(max(dotCount, 0), 6)
        guard dots > 0 else { return idleDotSize }
        return idleChipHPad * 2 + CGFloat(dots) * (idleDotSize + 2) - 2
    }

    /// Width of a single name chip: dot + gap + (clamped) label.
    public static func idleNameChipWidth(nameLength: Int) -> CGFloat {
        let textLen = min(max(nameLength, 2), 14)
        return idleChipHPad * 2 + idleDotSize + idleChipDotGap + CGFloat(textLen) * 6.4 + 2
    }

    /// Width of one summary chip ("N agents").
    public static func idleSummaryChipWidth(agentCount: Int) -> CGFloat {
        let digits = max(1, String(agentCount).count)
        let textLen = min(digits + 9, 14)
        return idleChipHPad * 2 + idleDotSize + idleChipDotGap + CGFloat(textLen) * 6.4 + 2
    }

    /// How many agent chips fit before truncating to `+N`.
    public static func idleShownChips(agentCount: Int, maxChips: Int) -> Int {
        min(max(agentCount, 0), max(maxChips, 0))
    }

    /// Total closed idle strip width for `style`.
    public static func idleStripWidth(
        style: IdleStyle, agentCount: Int, maxChips: Int, nameLengths: [Int]
    ) -> CGFloat {
        let count = max(agentCount, 0)
        guard count > 0 else { return idleChipWidth }
        switch style {
        case .dots:
            return idleDotsChipWidth(
                dotCount: idleShownChips(agentCount: count, maxChips: maxChips))
        case .summary:
            return idleSummaryChipWidth(agentCount: count)
        case .names:
            let shown = idleShownChips(agentCount: count, maxChips: maxChips)
            var w: CGFloat = 0
            for i in 0..<shown {
                let len = nameLengths.isEmpty ? 6 : nameLengths[min(i, nameLengths.count - 1)]
                w += idleNameChipWidth(nameLength: len)
            }
            w += CGFloat(max(shown - 1, 0)) * idleChipGap
            if count > shown { w += idleOverflowPad }
            return w
        }
    }

    /// Closed pill content width for the idle (agents-only) state.
    public static func idleClosedWidth(
        style: IdleStyle, agentCount: Int, maxChips: Int, nameLengths: [Int],
        notchWidth: CGFloat, expandedWidth: CGFloat = expandedWidth
    ) -> CGFloat {
        let w = idleStripWidth(
            style: style, agentCount: agentCount, maxChips: maxChips, nameLengths: nameLengths)
        return min(max(w, idleChipWidth), min(expandedWidth, max(notchWidth, 0)))
    }

    // MARK: - Expanded control plane

    /// How many blocked/needs-input agents get their own queue card before
    /// collapsing into `+N more`.
    public static let expandedQueueCap: Int = 3
    /// Height of one approval-queue card.
    public static let queueCardHeight: CGFloat = 42
    /// Footer health-bar height.
    public static let footerHeight: CGFloat = 22
    /// Group order for the expanded roster: needs input first, then working,
    /// then finished states — most actionable on top.
    static func expandedGroupRank(_ kind: AgentEventKind) -> Int {
        switch kind {
        case .accessRequest, .waiting: return 0
        case .progress, .started: return 1
        case .completed: return 2
        case .failed: return 3
        case .idle, .cancelled, .clear: return 4
        }
    }

    /// Aggregated counts shown in the control-plane header/footer.
    public struct AgentCounts: Equatable, Sendable {
        public var needsInput: Int = 0
        public var working: Int = 0
        public var done: Int = 0
        public var error: Int = 0
        public var idle: Int = 0
        public var total: Int { needsInput + working + done + error + idle }
    }

    static func agentCounts(kinds: [AgentEventKind]) -> AgentCounts {
        var counts = AgentCounts()
        for kind in kinds {
            switch kind {
            case .accessRequest, .waiting: counts.needsInput += 1
            case .progress, .started: counts.working += 1
            case .completed: counts.done += 1
            case .failed: counts.error += 1
            case .idle, .cancelled, .clear: counts.idle += 1
            }
        }
        return counts
    }

    /// Approval-queue split: how many cards to show vs `+N more` overflow.
    public static func queueSplit(blockedCount: Int, cap: Int) -> (shown: Int, overflow: Int) {
        let shown = min(max(blockedCount, 0), max(cap, 1))
        return (shown, max(blockedCount - shown, 0))
    }

    /// Expanded panel height accounting for the header, approval queue,
    /// roster rows, and footer — capped at the island max.
    public static func expandedSize(
        topInset: CGFloat, agentCount: Int, queueCount: Int,
        headerHeight: CGFloat = headerHeight, rowHeight: CGFloat = rowHeight
    ) -> CGSize {
        let h =
            topInset + headerHeight + CGFloat(queueCount) * queueCardHeight
            + CGFloat(agentCount) * rowHeight + footerHeight + contentSpacing
        return CGSize(width: expandedWidth, height: min(h, maxExpandedHeight))
    }

    // MARK: - Approval controls (in-UI approvals)

    /// Pure description of an approval prompt's interactive surface. The UI
    /// renders controls from this model; the manager feeds it the variance
    /// and choices it decoded from the event stream.
    struct ApprovalControls: Equatable, Sendable {
        public let variance: ApprovalVariance
        public let choices: [String]

        init(variance: ApprovalVariance?, choices: [String]?) {
            self.variance = variance ?? .yesNo
            self.choices = choices ?? []
        }

        static func make(
            variance: ApprovalVariance?, choices: [String]?
        ) -> ApprovalControls {
            ApprovalControls(variance: variance, choices: choices)
        }

        var isYesNo: Bool {
            variance == .yesNo || choices.isEmpty
        }

        var isMulti: Bool { variance == .multi && !choices.isEmpty }

        /// 1-based option labels for choice/multi prompts; empty for yes-no.
        var optionLabels: [String] {
            guard variance != .yesNo, !choices.isEmpty else { return [] }
            return (1...choices.count).map { "\($0)" }
        }

        var submitLabel: String {
            isMulti ? "Submit" : "Approve"
        }

        /// Number of the option at index `i` (0-based) in `selection`, or nil.
        static func optionNumber(forIndex i: Int) -> Int { i + 1 }

        /// Toggle a 0-based option index in a multi-select selection set.
        static func toggling(
            _ selection: Set<Int>, index: Int
        ) -> Set<Int> {
            var next = selection
            let option = optionNumber(forIndex: index)
            if next.contains(option) {
                next.remove(option)
            } else {
                next.insert(option)
            }
            return next
        }

        /// The sorted 1-based option numbers to send for a multi-select.
        static func selectionNumbers(_ selection: Set<Int>) -> [Int] {
            selection.sorted()
        }
    }

    // MARK: - Peripheral-vision & speed snacks

    /// Pulsing approval edge-glow color (amber, blocked state).
    public static let glowBlockedColor = "#ffe066"
    /// Steady edge-glow for urgent (accessRequest) states.
    public static let glowUrgentColor = "#ff6b6b"

    /// Human-readable elapsed time since `startedAt`, e.g. "14s", "2m", "1h".
    public static func elapsedLabel(since startedAt: Date, now: Date) -> String {
        let elapsed = max(now.timeIntervalSince(startedAt), 0)
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        }
        let minutes = Int(elapsed / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = Int(elapsed / 3600)
        let remMinutes = minutes % 60
        return remMinutes > 0 ? "\(hours)h\(remMinutes)m" : "\(hours)h"
    }

    /// Whether the roster should react to single-key shortcuts (Y/N/digits).
    /// Requires the island window to be key (clicked/global hotkey focus).
    public static func shortcutKey(for char: Character) -> ApprovalShortcut? {
        switch char.lowercased() {
        case "y": return .approve
        case "n": return .deny
        case "0"..."9": return .option(Int(String(char)) ?? 0)
        default: return nil
        }
    }

    public enum ApprovalShortcut: Equatable {
        case approve
        case deny
        case option(Int)
    }

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
        expandedSize(topInset: topInset, agentCount: agentCount, queueCount: 0)
    }

    public static func contentHeight(
        isExpanded: Bool, topInset: CGFloat, agentCount: Int, queueCount: Int = 0
    ) -> CGFloat {
        if isExpanded {
            return expandedSize(
                topInset: topInset, agentCount: agentCount, queueCount: queueCount
            ).height - topInset
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

    /// How far down (from the window's top edge) the island content sits.
    /// Docked idle chips sit flush in the notch row (0); the expanded panel and
    /// the "center" idle mode drop under the menu bar, like BoringNotch.
    public static func effectiveTopOffset(
        side: IslandDockSide, isExpanded: Bool, topInset: CGFloat
    ) -> CGFloat {
        isExpanded ? topInset : (side == .center ? topInset : 0)
    }

    /// Collapse on hover-exit unless the user is mid-prompt (composing).
    public static func shouldCollapseOnHoverExit(isExpanded: Bool, isComposing: Bool) -> Bool {
        isExpanded && !isComposing
    }

    public static func requiresApproval(_ kind: String) -> Bool {
        kind == "accessRequest" || kind == "access_request"
    }
}
