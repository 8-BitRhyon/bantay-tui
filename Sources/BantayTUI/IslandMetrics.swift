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
    public static let hoverExitGrace: TimeInterval = 0.25
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

    /// The largest chip count whose total strip width fits `availableWidth`
    /// (used when menu-bar clearance shrinks the strip). Never exceeds
    /// `maxChips`; floors at 1 when any room exists.
    public static func idleFitChips(
        agentCount: Int, maxChips: Int, nameLengths: [Int], availableWidth: CGFloat
    ) -> Int {
        let count = max(agentCount, 0)
        guard count > 0, availableWidth > 0 else { return 0 }
        let cap = min(count, max(maxChips, 0))
        guard cap > 0 else { return 0 }
        var width: CGFloat = 0
        var shown = 0
        for i in 0..<cap {
            let len = nameLengths.isEmpty ? 6 : nameLengths[min(i, nameLengths.count - 1)]
            let chip = idleNameChipWidth(nameLength: len)
            let gap = shown > 0 ? idleChipGap : 0
            guard width + chip + gap <= availableWidth else { break }
            width += chip + gap
            shown += 1
        }
        return shown
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
    /// Height of one approval-queue card. Reserves room for the optional live
    /// "peek" tail (captureTail) that drops in below the controls on hover.
    public static let queueCardHeight: CGFloat = 56
    /// Shelf tab bar height (Agents/Shelf switcher).
    public static let shelfTabBarHeight: CGFloat = 22
    /// Divider between the header/tabs and the list.
    public static let dividerHeight: CGFloat = 1
    /// "+N more waiting" overflow row height.
    public static let overflowRowHeight: CGFloat = 18
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

    /// Human label for a roster group rank (section header in the expanded
    /// control plane). Empty for ranks that never carry agents.
    static func groupLabel(rank: Int) -> String {
        switch rank {
        case 0: return "Needs you"
        case 1: return "Working"
        case 2: return "Done"
        case 3: return "Failed"
        case 4: return "Idle"
        default: return ""
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
        shelfTabVisible: Bool = false, overflowCount: Int = 0,
        headerHeight: CGFloat = headerHeight, rowHeight: CGFloat = rowHeight
    ) -> CGSize {
        let chrome =
            (shelfTabVisible ? shelfTabBarHeight + dividerHeight : 0)
            + CGFloat(max(overflowCount, 0)) * overflowRowHeight
        let h =
            topInset + headerHeight + chrome + CGFloat(queueCount) * queueCardHeight
            + CGFloat(agentCount) * rowHeight + footerHeight + contentSpacing
        return CGSize(width: expandedWidth, height: min(h, maxExpandedHeight))
    }

    // MARK: - Multi-monitor placement

    /// Abstract screen facts the placement logic needs (injected for tests).
    public struct ScreenInfo: Equatable, Sendable {
        public let frame: CGRect
        public let hasNotch: Bool
        public let containsMouse: Bool

        public init(frame: CGRect, hasNotch: Bool, containsMouse: Bool) {
            self.frame = frame
            self.hasNotch = hasNotch
            self.containsMouse = containsMouse
        }
    }

    /// Which screen the island should live on. Prefers the mouse's screen
    /// when it has a notch; otherwise any notch screen; otherwise falls back
    /// to the mouse's screen (floating pill, no notch).
    public static func islandScreen(
        screens: [ScreenInfo], preferMouseScreen: Bool
    ) -> ScreenInfo? {
        guard !screens.isEmpty else { return nil }
        let mouse = screens.first(where: \.containsMouse)
        if preferMouseScreen {
            if let mouse, mouse.hasNotch { return mouse }
            if let notch = screens.first(where: \.hasNotch) { return notch }
            return mouse ?? screens.first
        }
        return screens.first(where: \.hasNotch) ?? mouse ?? screens.first
    }

    /// Vertical inset for a floating pill on a notch-less display: below the
    /// menu bar with a small gap.
    public static func floatingTopInset(menuBarHeight: CGFloat) -> CGFloat {
        menuBarHeight + 6
    }

    /// Centered floating-pill frame on a notch-less screen.
    public static func floatingPillFrame(
        screenFrame: CGRect, size: CGSize, menuBarHeight: CGFloat
    ) -> CGRect {
        let topInset = floatingTopInset(menuBarHeight: menuBarHeight)
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - topInset - size.height,
            width: size.width,
            height: size.height)
    }

    // MARK: - Visibility policy

    /// Pure island-visibility gate. The island shows when enabled, not
    /// snoozed, not hidden-at-start, and either there is work or the user
    /// asked to keep it visible while idle (`showWhenIdle` / `forced`).
    enum VisibilityPolicy {
        static func shouldShow(
            islandEnabled: Bool,
            snoozed: Bool,
            hideAtStartup: Bool,
            didShowOnce: Bool,
            hasWork: Bool,
            showWhenIdle: Bool,
            forced: Bool = false
        ) -> Bool {
            guard islandEnabled, !snoozed else { return false }
            let hiddenAtStart = hideAtStartup && !didShowOnce && !showWhenIdle && !forced
            if hiddenAtStart { return false }
            return hasWork || showWhenIdle || forced
        }
    }

    // MARK: - Menu-bar collision avoidance

    /// How much horizontal room the island may use on a docked side without
    /// overlapping the menu-bar icon cluster the OS reports via auxiliary
    /// areas. The auxiliary areas describe the left/right menu-bar regions
    /// (icons live there); the notch sits between them.
    enum MenuBarClearance {
        /// Max idle width available on `side` given the OS-reported auxiliary
        /// area widths and the notch width. Returns the full screen width
        /// minus the notch when the OS reports nothing (fallback).
        static func maxIdleWidth(
            side: IslandDockSide, notchWidth: CGFloat, screenWidth: CGFloat,
            auxLeft: CGFloat, auxRight: CGFloat
        ) -> CGFloat {
            switch side {
            case .right:
                let rightRoom = auxRight > 0 ? auxRight : screenWidth - notchWidth
                return max(rightRoom - dockGap, 0)
            case .left:
                let leftRoom = auxLeft > 0 ? auxLeft : screenWidth - notchWidth
                return max(leftRoom - dockGap, 0)
            case .center:
                return max(screenWidth - notchWidth, 0)
            }
        }

        /// Whether a strip of `width` starting at the notch edge would
        /// collide with the icon cluster on the docked side.
        static func collides(
            side: IslandDockSide, stripWidth: CGFloat, notchWidth: CGFloat,
            screenWidth: CGFloat, auxLeft: CGFloat, auxRight: CGFloat
        ) -> Bool {
            stripWidth
                > maxIdleWidth(
                    side: side, notchWidth: notchWidth, screenWidth: screenWidth,
                    auxLeft: auxLeft, auxRight: auxRight)
        }
    }

    // MARK: - Display hot-swap & ghost validation

    /// Whether a window frame still lands on any of the given screens. A
    /// frame on a disconnected display is a "ghost" that must be re-anchored.
    enum DisplayAnchor {
        static func frameIsOnScreens(frame: CGRect, screens: [CGRect]) -> Bool {
            screens.contains { $0.intersects(frame) }
        }

        /// True when the window must be re-anchored: it is visible but its
        /// frame is off every current screen (display disconnected, clamshell
        /// closed, hot-plug race).
        static func needsReanchor(
            isVisible: Bool, windowFrame: CGRect, screens: [CGRect]
        ) -> Bool {
            isVisible && !frameIsOnScreens(frame: windowFrame, screens: screens)
        }
    }

    // MARK: - Full-screen & space policy

    /// Whether the island should be visible for the given full-screen state.
    /// Kept in pure form so the policy is testable without AppKit.
    enum FullScreenPolicy {
        static func shouldShow(
            inFullScreen: Bool, showInFullScreen: Bool
        ) -> Bool {
            !inFullScreen || showInFullScreen
        }

        /// Delay (seconds) before re-anchoring after a full-screen or space
        /// transition — lets the WindowServer settle the new frame.
        static let transitionSettleDelay: TimeInterval = 0.35
    }

    // MARK: - Approval heartbeat (phantom-prompt protection)

    /// Live-state verification for pinned approvals. A prompt card stays
    /// pinned only while the agent's live status still looks blocked (or is
    /// unknown — never phantom-clear on missing data). When the agent has
    /// actually moved on, the prompt is a phantom and must self-clear.
    enum ApprovalHeartbeat {
        /// Whether a prompt of `kind` should remain pinned given the pane's
        /// live status from the latest roster poll.
        static func shouldKeepPinned(
            kind: AgentEventKind, liveStatus: String?
        ) -> Bool {
            guard kind == .accessRequest || kind == .waiting else { return false }
            switch liveStatus?.lowercased() {
            case "working", "idle", "done", "failed", "cancelled", "running":
                return false
            case "blocked", "unknown", nil:
                return true
            default:
                return true
            }
        }

        /// Prune stale pending-approval keys: keep only panes whose live
        /// status still warrants a pinned prompt.
        static func verifyPendingKeys(
            _ keys: [String], liveStatuses: [String: String]
        ) -> [String] {
            keys.filter { key in
                guard let status = liveStatuses[key] else { return true }
                return shouldKeepPinned(kind: .accessRequest, liveStatus: status)
            }
        }
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

        /// Max option buttons rendered per queue card before `+N` overflow.
        static let maxDisplayedOptions = 6

        /// Option labels capped for display; the rest collapse into `+N`.
        func displayedLabels(cap: Int = ApprovalControls.maxDisplayedOptions) -> [String] {
            Array(optionLabels.prefix(max(cap, 1)))
        }

        /// How many options are hidden behind the `+N` overflow.
        func overflowCount(cap: Int = ApprovalControls.maxDisplayedOptions) -> Int {
            max(optionLabels.count - max(cap, 1), 0)
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

    /// Quiet-hours window check. Minutes are 0...1439 (00:00-23:59).
    /// Windows that wrap midnight (start > end) are handled; a zero-length
    /// window (start == end) is always inactive. Only suppresses sounds —
    /// approvals stay visible.
    public static func quietHoursActive(
        nowMinutes: Int, startMinutes: Int, endMinutes: Int
    ) -> Bool {
        guard (0..<1440).contains(nowMinutes), startMinutes != endMinutes else {
            return false
        }
        if startMinutes < endMinutes {
            return nowMinutes >= startMinutes && nowMinutes < endMinutes
        }
        return nowMinutes >= startMinutes || nowMinutes < endMinutes
    }

    /// Whether an approval event needs a Notification Center fallback:
    /// the feature is on, the island is NOT showing the event, and the kind
    /// is one a user must act on. Progress/completion noise never notifies.
    static func shouldPostNotification(
        islandVisible: Bool, notifyWhenHidden: Bool, kind: AgentEventKind
    ) -> Bool {
        guard notifyWhenHidden, !islandVisible else { return false }
        return kind == .accessRequest || kind == .waiting
    }

    /// F8 "attention only" triage filter: keeps needs-input (blocked) and
    /// failed agents, in roster order; everything else is dropped.
    static func attentionFilter(_ roster: [AgentSnapshot]) -> [AgentSnapshot] {
        roster.filter {
            $0.kind == .accessRequest || $0.kind == .waiting || $0.kind == .failed
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
        isExpanded: Bool, topInset: CGFloat, agentCount: Int, queueCount: Int = 0,
        shelfTabVisible: Bool = false, overflowCount: Int = 0
    ) -> CGFloat {
        if isExpanded {
            return expandedSize(
                topInset: topInset, agentCount: agentCount, queueCount: queueCount,
                shelfTabVisible: shelfTabVisible, overflowCount: overflowCount
            ).height - topInset
        }
        return pillHeight
    }

    /// F13 stable roster viewport: reserve one row even when the roster is
    /// empty, then cap growth at the available viewport height.
    static func stableRosterHeight(
        agentCount: Int, availableHeight: CGFloat, rowHeight: CGFloat = rowHeight
    ) -> CGFloat {
        let natural = CGFloat(max(agentCount, 0)) * rowHeight
        return max(min(max(natural, rowHeight), max(availableHeight, 0)), 0)
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
    /// Docked idle chips sit flush in the notch row (0); the expanded panel
    /// drops under the menu bar. Centered idle spans the notch itself, so it
    /// also sits in the notch row.
    public static func effectiveTopOffset(
        side: IslandDockSide, isExpanded: Bool, topInset: CGFloat
    ) -> CGFloat {
        isExpanded ? topInset : 0
    }

    /// Centered idle: the pill spans the notch width (black bar "behind" the
    /// notch), and details split to both sides. Each side gets half of the
    /// remaining window width.
    public static func centeredSideWidth(
        windowWidth: CGFloat, notchWidth: CGFloat
    ) -> CGFloat {
        max((windowWidth - notchWidth) / 2 - contentSpacing, 0)
    }

    /// Collapse on hover-exit unless the user is mid-prompt (composing).
    public static func shouldCollapseOnHoverExit(
        isExpanded: Bool, isComposing: Bool, isPinned: Bool = false
    ) -> Bool {
        isExpanded && !isComposing && !isPinned
    }

    // MARK: - Pin state machine (F11, plan 016 1b)

    /// Why a panel is collapsing. User-driven reasons (hover exit, hotkey
    /// toggle, display re-anchor) keep the pin latched; `agentsEmpty` and
    /// `explicitUnpin` clear it.
    public enum PinCollapseReason: Sendable {
        case hoverExit
        case hotkeyToggle
        case agentsEmpty
        case displayReanchor
        case explicitUnpin
    }

    /// Pure pin transition on collapse. The pin survives a collapse for
    /// user-driven reasons when `persistAcrossCollapse` is on; zero agents and
    /// an explicit unpin always clear it; persistence can be opted out
    /// wholesale (future `persistAcrossCollapse` flag → everything clears).
    public static func pinAfterCollapse(
        reason: PinCollapseReason, wasPinned: Bool, persistAcrossCollapse: Bool
    ) -> Bool {
        guard persistAcrossCollapse else { return false }
        switch reason {
        case .hoverExit, .hotkeyToggle, .displayReanchor:
            return wasPinned
        case .agentsEmpty, .explicitUnpin:
            return false
        }
    }

    /// A latched pin may re-expand the panel only while agents exist — it
    /// never resurrects an empty expanded panel.
    public static func pinShouldExpand(hasAgents: Bool) -> Bool {
        hasAgents
    }

    public static func requiresApproval(_ kind: String) -> Bool {
        kind == "accessRequest" || kind == "access_request"
    }
}
