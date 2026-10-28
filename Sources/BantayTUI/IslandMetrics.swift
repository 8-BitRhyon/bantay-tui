import AppKit
import CoreGraphics
import Foundation

/// Pure geometry and state-machine helpers for the notch island expand animation.
/// All functions are deterministic over their numeric inputs — AppKit is only
/// imported for `NSEvent.ModifierFlags` in the hotkey mapping.
public enum IslandMorphStyle: Sendable {
    case spring
    case linear
}

/// How the notch's content cross-fades when `isExpanded` flips. `.synced`
/// rides the same smooth morph as the background (opacity+scale grow from the
/// notch top); `.instant` is the reduce-motion path (opacity only, driven by
/// the short linear morph animation).
public enum ContentTransitionKind: Sendable, Equatable {
    case synced
    case instant
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
        /// One project chip plus the working count. Project names are more
        /// distinct than tool names when several agents run at once.
        case project
    }

    // MARK: - Constants
    public static let expandedWidth: CGFloat = 456
    public static let closedCornerRadius: CGFloat = 8
    public static let expandedCornerRadius: CGFloat = 24
    public static let pillHeight: CGFloat = 36
    public static let notificationHeight: CGFloat = 82
    /// Approval cards carry the command, file path, or prompt text, so they
    /// need room for several wrapped lines plus the action row.
    public static let approvalNotificationHeight: CGFloat = 160
    /// Labeled toggle row height for the control-plane multi-select list.
    public static let multiOptionRowHeight: CGFloat = 28
    public static func multiOptionsExtraHeight(optionCount: Int, cap: Int = 6) -> CGFloat {
        let shown = min(max(optionCount, 0), max(cap, 1))
        guard shown > 0 else { return 0 }
        let rows = (shown + 1) / 2
        return CGFloat(rows) * multiOptionRowHeight + CGFloat(max(rows - 1, 0)) * 6
    }
    public static let notificationWidth: CGFloat = 432
    /// Room below the last inbox row so a full row can clear the bottom
    /// fade instead of being cut by the panel edge.
    public static let rosterBottomClearance: CGFloat = 8
    public static let notificationCornerRadius: CGFloat = 20
    /// Clearance between the physical notch and a closed notification card.
    /// Without it the card's top row renders inside the notch cutout.
    public static let notificationTopGap: CGFloat = 8

    /// How long a completion or failure card stays visible before it dismisses
    /// itself. The countdown pauses while the pointer is over the notch.
    public static let notificationAutoDismissSeconds: Double = 8

    /// Agents report "done" at the end of every turn, then resume within a
    /// second while autonomous work continues. A completion card is only
    /// worth showing once the agent stays finished for this settle window;
    /// a resume inside the window drops the notice silently.
    public static let transientNoticeSettleSeconds: Double = 4

    /// Whether a settled completion or failure notice should appear for an
    /// agent in `agentKind`. Working agents suppress it; idle, finished, or
    /// vanished agents show it.
    static func transientNoticeShouldShow(agentKind: AgentEventKind?) -> Bool {
        switch agentKind {
        case .progress, .started: return false
        default: return true
        }
    }
    public static let headerHeight: CGFloat = 40
    public static let rowHeight: CGFloat = 26
    /// Height of the horizontal thumbnail strip on the shelf tab.
    public static let shelfStripHeight: CGFloat = 84
    /// Height of the shelf empty state when no files or clips exist.
    public static let shelfEmptyHeight: CGFloat = 100
    /// Footer that shows usage, budget, loading, and drop failures.
    public static let shelfFooterHeight: CGFloat = 18
    public static let taskRowHeight: CGFloat = 34
    public static let taskSearchBarHeight: CGFloat = 38
    public static let contentSpacing: CGFloat = 10
    public static let minExpandedHeight: CGFloat = 380
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
    public static let idleChipHPad: CGFloat = 6
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

    /// Chips to render beside the notch plus how many fold into `+N`.
    /// Reserves room for the overflow label when one has to appear. When even
    /// one readable chip plus the label will not fit, shows no chips rather
    /// than truncating every name to an ellipsis.
    public struct IdleChipFit: Equatable, Sendable {
        public let shown: Int
        public let overflow: Int

        public init(shown: Int, overflow: Int) {
            self.shown = shown
            self.overflow = overflow
        }
    }

    public static func idleChipFit(
        agentCount: Int, maxChips: Int, nameLengths: [Int], availableWidth: CGFloat
    ) -> IdleChipFit {
        let count = max(agentCount, 0)
        guard count > 0, availableWidth > 0 else {
            return IdleChipFit(shown: 0, overflow: 0)
        }
        let full = idleFitChips(
            agentCount: count, maxChips: maxChips,
            nameLengths: nameLengths, availableWidth: availableWidth)
        if full >= count {
            return IdleChipFit(shown: full, overflow: 0)
        }
        let overflowWidth = idleOverflowPad + idleChipGap
        let withOverflow = idleFitChips(
            agentCount: count, maxChips: maxChips, nameLengths: nameLengths,
            availableWidth: max(availableWidth - overflowWidth, 0))
        guard withOverflow >= 1 else {
            return IdleChipFit(shown: 0, overflow: 0)
        }
        return IdleChipFit(shown: withOverflow, overflow: count - withOverflow)
    }

    /// Count label for the right wing while agents are working.
    public static func centeredWorkingLabel(working: Int) -> String {
        "\(working) working"
    }

    /// Width of the docked project chip: project name, `+N` overflow, and the
    /// agent count that replaces the right-wing status on a docked strip.
    public static func idleProjectChipWidth(
        nameLength: Int, agentCount: Int, projectCount: Int
    ) -> CGFloat {
        let digits = max(String(max(agentCount, 0)).count, 1)
        let countWidth = 10 + CGFloat(digits) * 6.4
        let overflow = projectCount > 1 ? idleOverflowPad : 0
        return idleNameChipWidth(nameLength: nameLength) + countWidth + overflow
    }

    /// Distinct project labels in roster order. Falls back to the agent source
    /// when the working directory produced no project. Case-insensitive dedupe
    /// so two paths that resolve to the same project do not become two chips.
    public static func compactProjectLabels(
        projects: [String?], sources: [String]
    ) -> [String] {
        let count = min(projects.count, sources.count)
        return compactProjectLabels(
            projects: projects, sources: sources, order: Array(0..<count))
    }

    /// Distinct project labels ordered by the most recently started agent.
    /// Ties keep roster order so the lead chip does not jitter.
    public static func compactProjectLabels(
        projects: [String?], sources: [String], startedAt: [Date?]
    ) -> [String] {
        let count = min(projects.count, min(sources.count, startedAt.count))
        let order = (0..<count).sorted { lhs, rhs in
            let left = startedAt[lhs] ?? .distantPast
            let right = startedAt[rhs] ?? .distantPast
            if left != right { return left > right }
            return lhs < rhs
        }
        return compactProjectLabels(projects: projects, sources: sources, order: order)
    }

    private static func compactProjectLabels(
        projects: [String?], sources: [String], order: [Int]
    ) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for index in order {
            let raw = (projects[index] ?? sources[index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            guard seen.insert(raw.lowercased()).inserted else { continue }
            labels.append(raw)
        }
        return labels
    }

    /// Total closed idle strip width for `style`. For `.project`, `nameLengths`
    /// carries the distinct project label lengths and `agentCount` stays the
    /// agent total shown in the chip's count.
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
        case .project:
            return idleProjectChipWidth(
                nameLength: nameLengths.first ?? 6,
                agentCount: count,
                projectCount: max(nameLengths.count, 1))
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
    /// Height of one expanded inbox approval card: request summary plus a
    /// full-height action row. Used by the v2 roster layout math.
    public static let approvalCardHeight: CGFloat = 152
    /// Extra height for each visible choice row inside an approval card.
    public static let approvalChoiceRowHeight: CGFloat = 34
    /// Height of one active/working agent row: project line plus humanized
    /// activity line. Used by the v2 roster layout math.
    public static let workingRowHeight: CGFloat = 48
    /// Height of one idle/standby agent row. Used by the v2 roster layout math.
    public static let idleRowHeight: CGFloat = 34
    /// Height of the inline reply composer reserved while composing.
    public static let replyComposerHeight: CGFloat = 76
    /// Height of the dismissible while-away recap card.
    public static let awayDigestHeight: CGFloat = 64
    /// Shelf tab bar height (Inbox/Tasks/History + utility pills).
    public static let shelfTabBarHeight: CGFloat = 26
    /// Divider between the header/tabs and the list.
    public static let dividerHeight: CGFloat = 1
    /// "+N more waiting" overflow row height.
    public static let overflowRowHeight: CGFloat = 18
    /// Section header height inside the grouped expanded roster (one per
    /// non-empty group).
    public static let sectionHeaderHeight: CGFloat = 18
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

    /// How many non-empty roster groups the grouped expanded list will render
    /// section headers for. Mirrors `expandedGroupRank` bucketing (0...4), so
    /// the height math reserves exactly the header rows the UI draws.
    static func groupHeaderCount(kinds: [AgentEventKind]) -> Int {
        Set(kinds.map(expandedGroupRank)).count
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
    /// roster rows, grouped section headers, and footer — capped at the
    /// island max. `footerVisible: false` drops the footer term (used when the
    /// panel renders no footer bar).
    public static func expandedSize(
        topInset: CGFloat, agentCount: Int, queueCount: Int,
        shelfTabVisible: Bool = false, overflowCount: Int = 0,
        headerHeight: CGFloat = headerHeight, rowHeight: CGFloat = rowHeight,
        groupCount: Int = 0, footerVisible: Bool = true,
        taskCount: Int = 0, sectionCount: Int = 0, isTasksTab: Bool = false
    ) -> CGSize {
        let chrome =
            (shelfTabVisible ? shelfTabBarHeight + dividerHeight : 0)
            + CGFloat(max(overflowCount, 0)) * overflowRowHeight

        let contentH: CGFloat = {
            if isTasksTab {
                let natural =
                    headerHeight + chrome + taskSearchBarHeight
                    + CGFloat(max(taskCount, 0)) * taskRowHeight
                    + CGFloat(max(sectionCount, 0)) * sectionHeaderHeight + contentSpacing
                return max(natural, minExpandedHeight - topInset)
            } else {
                return headerHeight + chrome + CGFloat(queueCount) * queueCardHeight
                    + CGFloat(agentCount) * rowHeight
                    + CGFloat(max(groupCount, 0)) * sectionHeaderHeight
                    + (footerVisible ? footerHeight : 0) + contentSpacing
            }
        }()

        let h = topInset + contentH
        return CGSize(width: expandedWidth, height: min(h, maxExpandedHeight))
    }

    /// Panel height for the shelf tab. The shelf uses a fixed thumbnail strip,
    /// a scrolling clipboard list, and a status footer. Keeping this pure lets
    /// the view and the harness agree.
    public static func shelfPanelSize(
        topInset: CGFloat, fileCount: Int, clipboardCount: Int,
        shelfTabVisible: Bool = true
    ) -> CGSize {
        let chrome = shelfTabVisible ? shelfTabBarHeight + dividerHeight : 0
        let strip: CGFloat
        if fileCount > 0 {
            strip = shelfStripHeight
        } else if clipboardCount > 0 {
            strip = 0
        } else {
            strip = shelfEmptyHeight
        }
        let contentH =
            headerHeight + chrome + strip + shelfFooterHeight
            + CGFloat(max(clipboardCount, 0)) * rowHeight
            + contentSpacing
        return CGSize(
            width: expandedWidth,
            height: min(topInset + contentH, maxExpandedHeight))
    }

    /// A hidden Shelf tab must still render its bar while a drop forces the
    /// shelf open. Otherwise the panel has no way back to another tab.
    public static func shelfTabBarVisible(
        showShelfTab: Bool, shelfSelected: Bool
    ) -> Bool {
        showShelfTab || shelfSelected
    }

    /// The spend perimeter is a peripheral-vision cue for the collapsed notch.
    /// When the panel is open, the cost badge already carries the signal, and a
    /// full-panel red ring reads as an error state.
    public static func spendStrokeVisible(
        isExpanded: Bool, isCenteredClosed: Bool
    ) -> Bool {
        !isExpanded && !isCenteredClosed
    }

    /// The black island chrome stays transparent for the centered idle strip
    /// because the physical notch already supplies the surface. A notification
    /// replaces that strip, so it must restore the opaque chrome: white card
    /// text otherwise sits directly on the window behind the notch.
    public static func islandChromeVisible(
        isExpanded: Bool, isCenteredClosed: Bool, hasActiveNotification: Bool
    ) -> Bool {
        isExpanded || !isCenteredClosed || hasActiveNotification
    }

    /// Structured v2 roster layout. Replaces flat `agentCount * rowHeight`
    /// math so approval cards, working rows, and idle rows can each have
    /// their own height without clipping the panel.
    public struct RosterLayoutMetrics: Equatable, Sendable {
        public let approvalCardCount: Int
        public let approvalChoiceRowCount: Int
        public let workingRowCount: Int
        public let idleRowCount: Int
        public let groupCount: Int
        public let isComposing: Bool
        public let hasAwayDigest: Bool

        public init(
            approvalCardCount: Int = 0,
            approvalChoiceRowCount: Int = 0,
            workingRowCount: Int = 0,
            idleRowCount: Int = 0,
            groupCount: Int = 0,
            isComposing: Bool = false,
            hasAwayDigest: Bool = false
        ) {
            self.approvalCardCount = approvalCardCount
            self.approvalChoiceRowCount = approvalChoiceRowCount
            self.workingRowCount = workingRowCount
            self.idleRowCount = idleRowCount
            self.groupCount = groupCount
            self.isComposing = isComposing
            self.hasAwayDigest = hasAwayDigest
        }
    }

    /// Natural roster height for structured v2 rows.
    public static func rosterHeight(_ roster: RosterLayoutMetrics) -> CGFloat {
        CGFloat(max(roster.approvalCardCount, 0)) * approvalCardHeight
            + CGFloat(max(roster.approvalChoiceRowCount, 0)) * approvalChoiceRowHeight
            + CGFloat(max(roster.workingRowCount, 0)) * workingRowHeight
            + CGFloat(max(roster.idleRowCount, 0)) * idleRowHeight
            + CGFloat(max(roster.groupCount, 0)) * sectionHeaderHeight
            + (roster.isComposing ? replyComposerHeight : 0)
            + (roster.hasAwayDigest ? awayDigestHeight : 0)
    }

    /// Expanded panel height from structured v2 roster rows. The legacy
    /// flat-count overload below stays untouched for current callers.
    public static func expandedSize(
        topInset: CGFloat, roster: RosterLayoutMetrics,
        shelfTabVisible: Bool = false, overflowCount: Int = 0,
        headerHeight: CGFloat = headerHeight, footerVisible: Bool = true
    ) -> CGSize {
        let chrome =
            (shelfTabVisible ? shelfTabBarHeight + dividerHeight : 0)
            + CGFloat(max(overflowCount, 0)) * overflowRowHeight
        let contentH =
            headerHeight + chrome + rosterHeight(roster)
            + (footerVisible ? footerHeight : 0) + contentSpacing
        let h = topInset + contentH
        return CGSize(width: expandedWidth, height: min(h, maxExpandedHeight))
    }

    /// Desktop strip hotkeys use Control + Option only. Space toggles the
    /// Desktop HUD; the existing strip letter shortcuts stay untouched.
    public enum DesktopHotkeyAction: Sendable, Equatable {
        case toggleDesktopHUD
    }

    public static func desktopHotkeyAction(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> DesktopHotkeyAction? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.option) else { return nil }
        guard !flags.contains(.shift), !flags.contains(.command) else { return nil }
        return keyCode == 49 ? .toggleDesktopHUD : nil
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

        /// The strip is a window-management mode, not an always-on HUD.
        /// Suspend its overlays and tiling whenever the active app is full
        /// screen, even if the island itself stays visible.
        static func shouldShowStrip(
            isEnabled: Bool, inFullScreen: Bool
        ) -> Bool {
            isEnabled && !inFullScreen
        }

        /// Converts an AppKit screen frame (origin bottom-left) into the
        /// global window-server frame (origin top-left of the primary display).
        static func cgScreenRect(
            appKitFrame: CGRect, primaryMaxY: CGFloat
        ) -> CGRect {
            CGRect(
                x: appKitFrame.origin.x,
                y: primaryMaxY - appKitFrame.maxY,
                width: appKitFrame.width,
                height: appKitFrame.height
            )
        }

        /// True when a window covers an entire display, within a small
        /// tolerance for rounded corners and backing-scale rounding.
        static func coversScreen(
            windowFrame: CGRect, screenFrame: CGRect, tolerance: CGFloat = 2.0
        ) -> Bool {
            abs(windowFrame.minX - screenFrame.minX) <= tolerance
                && abs(windowFrame.minY - screenFrame.minY) <= tolerance
                && abs(windowFrame.width - screenFrame.width) <= tolerance
                && abs(windowFrame.height - screenFrame.height) <= tolerance
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
        /// Parallel to `choices`: option descriptions when the prompt has
        /// them. Empty means every option is label-only.
        public let details: [String]

        init(variance: ApprovalVariance?, choices: [String]?, details: [String]? = nil) {
            self.variance = variance ?? .yesNo
            self.choices = choices ?? []
            self.details = details ?? []
        }

        static func make(
            variance: ApprovalVariance?, choices: [String]?, details: [String]? = nil
        ) -> ApprovalControls {
            ApprovalControls(variance: variance, choices: choices, details: details)
        }

        /// Description for the option at `index`, or nil when the prompt did
        /// not include one.
        func detail(at index: Int) -> String? {
            guard index >= 0, index < details.count else { return nil }
            let detail = details[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? nil : detail
        }

        /// 1-based row for a free-text answer when the prompt offers one
        /// ("Type your own answer", "Other", ...). Nil when typing goes
        /// straight into the prompt.
        var customChoiceNumber: Int? {
            Self.customChoiceNumber(in: choices)
        }

        static func customChoiceNumber(in choices: [String]) -> Int? {
            for (index, label) in choices.enumerated() {
                let lower = label.lowercased()
                if lower.contains("type your own")
                    || lower.contains("type an answer")
                    || lower.contains("write your own")
                    || lower.contains("custom answer")
                    || lower == "other"
                    || lower.hasPrefix("other ")
                    || lower == "something else"
                {
                    return index + 1
                }
            }
            return nil
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

        /// Multi-select Submit is valid only with at least one option
        /// picked. Sending an empty selection pushes a blank line into the
        /// agent's terminal, so every Submit button gates on this.
        static func canSubmitMulti(selection: Set<Int>) -> Bool {
            !selection.isEmpty
        }
    }

    /// Whether a live pane excerpt reads like a real prompt. Pane tails
    /// usually hold whatever scrolled by (chat transcripts, build logs),
    /// not the question — without a prompt signal the card must fall
    /// back to Review instead of showing random transcript text.
    /// Keywords match whole words only, so "confirming the render" never
    /// counts but "confirm deploy" does. Numbered options match `1.` / `2)`
    /// at a line start only, so version strings like `1.3` never count.
    static func looksLikePrompt(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if text.contains("?") { return true }
        let lower = text.lowercased()
        let phraseSignals = [
            "allow once", "(y/n)", "[y/n]", " y/n ", "press ",
            "❯", "›", "»",
        ]
        if phraseSignals.contains(where: { lower.contains($0) }) { return true }
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let wordSet = Set(words.filter { !$0.isEmpty })
        let keywords: Set<String> = [
            "approve", "approves", "deny", "denies", "allow", "allows",
            "confirm", "confirms", "pick", "picks", "choose", "chooses",
            "select", "selects", "option", "options", "answer", "answers",
        ]
        if !wordSet.isDisjoint(with: keywords) { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in trimmed.components(separatedBy: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, first.isNumber else { continue }
            let rest = line.drop(while: { $0.isNumber })
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return true }
        }
        return false
    }

    /// What a blocked event asks of the user. Options always win: when an
    /// event carries two or more choices it is a question, even if the
    /// underlying kind is an approval — answering directly beats blanket
    /// approval, and approving a question answers nothing. `actionable`
    /// means this surface would otherwise offer Allow/Deny (the existing
    /// concreteness gate lives with the caller).
    enum PromptSurfaceKind: Sendable, Equatable {
        case permission
        case question
        case waiting
    }

    static func promptSurfaceKind(
        eventKind: AgentEventKind, actionable: Bool, choiceCount: Int
    ) -> PromptSurfaceKind {
        if choiceCount >= 2 { return .question }
        if eventKind == .accessRequest && actionable { return .permission }
        return .waiting
    }

    /// Risky prompts that may require a second click when the user opts in.
    /// Patterns are case-insensitive substrings.
    public static let defaultRiskyPromptPatterns = [
        "git push", "deploy", "rm -rf", "sudo", "migrate", "force",
    ]

    /// Normalizes the Settings pattern editor: one pattern per line,
    /// trimmed, empty lines dropped, case-insensitive duplicates removed.
    public static func normalizedRiskyPatterns(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    public static func requiresSecondaryConfirm(
        text: String, patterns: [String]
    ) -> Bool {
        guard !patterns.isEmpty else { return false }
        let lower = text.lowercased()
        return patterns.contains {
            !$0.isEmpty && lower.contains($0.lowercased())
        }
    }

    /// Questions always accept free text: choices must never trap an answer.
    static func promptAcceptsFreeText(surface: PromptSurfaceKind) -> Bool {
        surface == .question
    }

    /// Maximum stacked closed-notification cards. New events never silently
    /// replace older ones; overflow drops the lowest-priority oldest first.
    static let maxNotificationQueueCount = 5

    /// Priority rank for closed-notification queue order. Approvals and
    /// questions outrank failure and completion notices; ties break oldest
    /// first so the queue is first-come, first-served within a rank.
    static func notificationQueueRank(_ kind: AgentEventKind) -> Int {
        switch kind {
        case .accessRequest: return 0
        case .waiting: return 1
        case .failed: return 2
        case .completed: return 3
        case .progress, .started: return 4
        case .idle, .cancelled, .clear: return 5
        }
    }

    /// Insert an event into the closed-notification queue: same-id replaces
    /// in place (content refresh, never a duplicate), otherwise appends,
    /// sorts by rank then age, and caps the length.
    static func notificationQueueInsert(
        _ queue: [AgentEvent], event: AgentEvent, cap: Int = maxNotificationQueueCount
    ) -> [AgentEvent] {
        var next = queue.filter { $0.id != event.id }
        next.append(event)
        next.sort {
            let left = notificationQueueRank($0.kind)
            let right = notificationQueueRank($1.kind)
            if left != right { return left < right }
            return $0.createdAt < $1.createdAt
        }
        if next.count > max(cap, 1) {
            next = Array(next.prefix(max(cap, 1)))
        }
        return next
    }

    /// Remove one event from the queue by id. No-op when absent.
    static func notificationQueueRemove(
        _ queue: [AgentEvent], id: UUID
    ) -> [AgentEvent] {
        queue.filter { $0.id != id }
    }

    /// Clamp a selected queue index after insert/remove so the stepper never
    /// points past the end.
    static func notificationQueueClampIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
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

    /// Compact token counts for session rows: 950 -> "950", 38_400 ->
    /// "38.4k", 118_000_000 -> "118M". Raw counts are unreadable at scale.
    public static func compactTokenCount(_ count: Int) -> String {
        let n = max(count, 0)
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1_000.0
            return k >= 100 ? "\(Int(k.rounded()))k" : String(format: "%.1fk", k)
        }
        if n < 1_000_000_000 {
            let m = Double(n) / 1_000_000.0
            return m >= 100 ? "\(Int(m.rounded()))M" : String(format: "%.1fM", m)
        }
        let b = Double(n) / 1_000_000_000.0
        return b >= 100 ? "\(Int(b.rounded()))B" : String(format: "%.1fB", b)
    }

    /// Day-bucket label for session grouping. Today and Yesterday read
    /// instantly; older days show the weekday and date.
    public static func sessionDayLabel(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        return date.formatted(
            .dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// Contribution-streak math over active day-starts. Current counts
    /// consecutive active days ending today (or yesterday when today is
    /// quiet); longest is the best run anywhere. Zero gap tolerance, like
    /// every streak clone since GitHub removed native streaks.
    public static func usageStreak(
        activeDays: [Date], now: Date = Date()
    ) -> (current: Int, longest: Int) {
        let calendar = Calendar.current
        let days = Set(activeDays.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return (0, 0) }
        let today = calendar.startOfDay(for: now)
        var day: Date? =
            days.contains(today)
            ? today : calendar.date(byAdding: .day, value: -1, to: today)
        var current = 0
        while let active = day, days.contains(active) {
            current += 1
            day = calendar.date(byAdding: .day, value: -1, to: active)
        }
        var longest = 0
        for day in days {
            guard
                let prev = calendar.date(byAdding: .day, value: -1, to: day),
                !days.contains(prev)
            else {
                continue
            }
            var run = 0
            var cursor = day
            while days.contains(cursor) {
                run += 1
                guard
                    let next = calendar.date(byAdding: .day, value: 1, to: cursor)
                else {
                    break
                }
                cursor = next
            }
            longest = max(longest, run)
        }
        return (current, longest)
    }

    /// Bounded, thread-safe memo for pure string cleanup. Transcript tails and
    /// SwiftUI renders ask for the same headlines repeatedly, and the cleaner
    /// runs roughly eighteen regex passes per call.
    private final class HUDCleanCache: @unchecked Sendable {
        static let shared = HUDCleanCache()
        private struct Key: Hashable {
            let limit: Int
            let text: String
        }

        private let lock = NSLock()
        private var values: [Key: String] = [:]
        private var order: [Key] = []

        func value(limit: Int, text: String) -> String? {
            let key = Key(limit: limit, text: text)
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: String, limit: Int, text: String) {
            let key = Key(limit: limit, text: text)
            lock.lock()
            defer { lock.unlock() }
            if values.updateValue(value, forKey: key) == nil {
                order.append(key)
            }
            while order.count > 768 {
                values.removeValue(forKey: order.removeFirst())
            }
        }
    }

    /// Bounded memo for the garbage/suppression predicate, which is queried
    /// both directly and at the end of every clean pass.
    private final class HUDSuppressionCache: @unchecked Sendable {
        static let shared = HUDSuppressionCache()
        private let lock = NSLock()
        private var values: [String: Bool] = [:]
        private var order: [String] = []

        func value(for text: String) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return values[text]
        }

        func store(_ value: Bool, for text: String) {
            lock.lock()
            defer { lock.unlock() }
            if values.updateValue(value, forKey: text) == nil {
                order.append(text)
            }
            while order.count > 768 {
                values.removeValue(forKey: order.removeFirst())
            }
        }
    }

    /// Precompiled expressions for the cleaner. NSRegularExpression matching is
    /// thread-safe; compiling the same pattern on every call is not free.
    private final class HUDRegexes: @unchecked Sendable {
        static let shared = HUDRegexes()
        let bareSyslog = try? NSRegularExpression(
            pattern:
                "^\\d{4}-\\d{2}-\\d{2}[\\sT][0-9:.]+(?:[+-]\\d{4}|Z)?\\s+[a-zA-Z0-9_.-]+$",
            options: [])
        let leadingDate = try? NSRegularExpression(
            pattern: "^\\d{4}-\\d{2}-\\d{2}", options: [])
        let markdownLink = try? NSRegularExpression(
            pattern: "\\[([^\\]]+)\\]\\([^\\)]+\\)", options: [])
        let pathWithExtension = try? NSRegularExpression(
            pattern: "/(?:[^\\s/]+/)+([^\\s/]+\\.[a-zA-Z0-9_]+)", options: [])
    }

    private static let maxCachedTextBytes = 2048

    /// Strips ANSI escape sequences, control characters, braille spinners, log envelopes,
    /// markdown links, and paths to format clean single-line HUD strings.
    /// Suppresses raw JSON blobs, diff chunks, hostnames, and internal daemon pings.
    public static func cleanHUDText(_ text: String, maxCharacters: Int = 60) -> String {
        let cacheable = text.utf8.count <= maxCachedTextBytes
        if cacheable,
            let hit = HUDCleanCache.shared.value(limit: maxCharacters, text: text)
        {
            return hit
        }
        let result = cleanHUDTextUncached(text, maxCharacters: maxCharacters)
        if cacheable {
            HUDCleanCache.shared.store(result, limit: maxCharacters, text: text)
        }
        return result
    }

    private static func cleanHUDTextUncached(
        _ text: String, maxCharacters: Int
    ) -> String {
        if isBareSyslog(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return ""
        }
        // 1. Strip ANSI escape sequences, control characters, and braille spinner patterns
        var s = LogFormatter.stripControlCharacters(text)
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        // 2. Strip XML/HTML tags (e.g. <thinking>, </thinking>, <command>)
        s = s.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression)

        // 3. Strip log envelope metadata (timestamp=... level=... run=... msg=...)
        s = s.replacingOccurrences(
            of: "(?:timestamp|time)=[0-9T:.Z+-]+\\s*",
            with: "",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "(?:timestamp|time)=\"[^\"]*\"\\s*",
            with: "",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "(?:level|lvl)=[a-zA-Z0-9_-]+\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: "^\\[?(?:INFO|WARN|ERROR|DEBUG|TRACE)\\]?\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: "\\[(?:INFO|WARN|ERROR|DEBUG|TRACE)\\]\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: "(?:run|run_id)=[a-zA-Z0-9_-]+\\s*",
            with: "",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "(?:message|msg)=\"?([^\"]*)\"?",
            with: "$1",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "(?:service|endpoint)=[a-zA-Z0-9._/-]+\\s*",
            with: "",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "(?:count|errors|durationMs)=\\d+\\s*",
            with: "",
            options: .regularExpression)

        // 4. Strip bare ISO and syslog timestamps (\d{4}-\d{2}-\d{2}[ T]...) and relative time (+40ms)
        // Syslog lines often carry a process prefix after the timestamp
        // ("2026-10-16 09:12:48.169514-0500 bantay: Running task"). Drop the
        // timestamp and the process name together so the status text remains.
        s = s.replacingOccurrences(
            of:
                "^\\d{4}-\\d{2}-\\d{2}[\\sT][0-9:.]+(?:[+-]\\d{4}|Z)?\\s+[a-zA-Z0-9_.-]+:\\s*",
            with: "",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "\\b\\d{4}-\\d{2}-\\d{2}[\\sT][0-9:.]+(?:[+-]\\d{4}|Z)?\\b\\s*",
            with: "",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "\\b\\d{4}-\\d{2}-\\d{2}\\b\\s*",
            with: "",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "^[a-zA-Z0-9_.-]+\\[\\d+(?::\\d+)?\\]:\\s*",
            with: "",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: "\\+\\d+ms\\s*",
            with: "",
            options: .regularExpression)

        // 5. Strip terminal progress brackets (e.g. [===> ] 45%)
        s = s.replacingOccurrences(
            of: "\\[[=>\\-\\s]+\\]\\s*\\d*%?\\s*",
            with: "",
            options: .regularExpression)

        // 6. Strip markdown links: [text](url) -> text
        if let regex = HUDRegexes.shared.markdownLink {
            let range = NSRange(location: 0, length: s.utf16.count)
            s = regex.stringByReplacingMatches(
                in: s, options: [], range: range, withTemplate: "$1")
        }

        // 7. Strip raw file URLs
        s = s.replacingOccurrences(of: "file:///[^\\s)]+", with: "", options: .regularExpression)

        // 8. Replace absolute filesystem paths with their last component (basename)
        if let regex = HUDRegexes.shared.pathWithExtension {
            let range = NSRange(location: 0, length: s.utf16.count)
            s = regex.stringByReplacingMatches(
                in: s, options: [], range: range, withTemplate: "$1")
        }

        // 9. Strip bold/italic/code markdown delimiters
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "`", with: "")

        // 10. Collapse excess whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // A syslog timestamp plus a lone process name carries no status.
        if isBareSyslog(trimmed) { return "" }

        // 11. Reject unparsed JSON, diff markers, compiler trace noise, hostnames, and shell fallbacks
        if isSuppressedGarbage(trimmed) {
            return ""
        }

        if maxCharacters > 0, trimmed.count > maxCharacters {
            let prefix = String(trimmed.prefix(maxCharacters - 3))
            return prefix.trimmingCharacters(in: .whitespaces) + "..."
        }
        return trimmed
    }

    /// True for a syslog timestamp followed by a lone process name:
    /// `2026-10-16 09:12:48.169514-0500 bantay`. Such a line has no status.
    private static func isBareSyslog(_ text: String) -> Bool {
        guard let regex = HUDRegexes.shared.bareSyslog else { return false }
        return regex.firstMatch(
            in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)
        ) != nil
    }

    /// True if the string is raw unparsed JSON, a diff chunk, internal daemon noise,
    /// or a multiplexer hostname/shell fallback.
    public static func isSuppressedGarbage(_ text: String) -> Bool {
        let cacheable = text.utf8.count <= maxCachedTextBytes
        if cacheable, let hit = HUDSuppressionCache.shared.value(for: text) {
            return hit
        }
        let result = isSuppressedGarbageUncached(text)
        if cacheable {
            HUDSuppressionCache.shared.store(result, for: text)
        }
        return result
    }

    private static func isSuppressedGarbageUncached(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if isBareSyslog(trimmed) { return true }
        let lower = trimmed.lowercased()

        // Unparsed JSON blobs or brackets
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            || trimmed.hasPrefix("}") || trimmed.hasPrefix("]")
            || lower.contains("\"tool_calls\"") || lower.contains("\"tool_use\"")
            || lower.contains("\"type\":") || lower.contains("\"session_id\":")
        {
            return true
        }

        // Git diff chunks, compiler trace markers, or raw syslog dates
        if trimmed.hasPrefix("@@") || trimmed.hasPrefix("diff --git")
            || trimmed.hasPrefix("[diff_block") || trimmed.hasPrefix("::error")
            || trimmed.hasPrefix("Created At:") || trimmed.hasPrefix("File Path:")
            || trimmed.hasPrefix("Completed At:")
            || hasLeadingISODate(trimmed)
        {
            return true
        }

        // Internal daemon chatter and maintenance pings
        if lower.contains("service=") || lower.contains("prune=")
            || lower.contains("catalog request") || lower.contains("catalog response")
            || lower.contains("catalog fetched") || lower.contains("subscribing")
            || lower.contains("watching parent process")
            || lower.contains("ignoring retired") || lower.contains("process_role=")
            || lower.contains("duplicate skill name") || lower.contains("run_id=")
            || lower.hasPrefix("cleanup ")
        {
            return true
        }

        // Multiplexer hostnames (e.g. MacBook.local)
        if lower.hasSuffix(".local") || lower.hasSuffix(".lan") || lower.hasSuffix(".internal") {
            return true
        }

        // Shell prompts (e.g. user@host:~$, user@host:~#, host% )
        if trimmed.contains("@")
            && (trimmed.hasSuffix("$") || trimmed.hasSuffix("#")
                || trimmed.hasSuffix("%") || trimmed.contains(":~"))
        {
            return true
        }
        if trimmed.hasSuffix(" %") || trimmed.hasSuffix(" $") || trimmed.hasSuffix(" #")
            || trimmed == "$" || trimmed == "#" || trimmed == "%"
        {
            return true
        }

        // Multiplexer bare shell names
        let shells: Set<String> = [
            "zsh", "bash", "sh", "fish", "csh", "tcsh", "node", "python", "python3", "default",
            "terminal", "tmux", "zellij", "main", "window", "pane",
        ]
        if shells.contains(lower) {
            return true
        }

        return false
    }

    private static func hasLeadingISODate(_ text: String) -> Bool {
        guard let regex = HUDRegexes.shared.leadingDate else { return false }
        return regex.firstMatch(
            in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)
        ) != nil
    }

    /// Whether the roster should react to single-key shortcuts (Y/N/digits).
    /// Requires the island window to be key (clicked/global hotkey focus).
    public static func shortcutKey(for char: Character) -> ApprovalShortcut? {
        switch char.lowercased() {
        case "y": return .approve
        case "n": return .deny
        case "r": return .reply
        case "0"..."9": return .option(Int(String(char)) ?? 0)
        default: return nil
        }
    }

    /// Global ⌥-key actions dispatched from the key-down monitor. Physical
    /// keyCodes are layout-independent: Y=approve, N=deny, S=snooze.
    /// There is no island toggle shortcut: Option+Space belongs to launchers,
    /// so the island toggles through hover and the menu bar instead.
    public enum HotkeyAction: Sendable {
        case approveTop
        case denyTop
        case snooze15
        case openSettings
    }

    /// Map a key-down event to a global hotkey action. Requires Option and
    /// only Option — any extra modifier (Shift/Control/Command) disqualifies
    /// so the combo never collides with app shortcuts. Unknown keyCodes are
    /// nil. Facet gating lives in the caller (`updateGlobalHotkeyMonitor`).
    public static func hotkeyAction(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> HotkeyAction? {
        let hasOption = modifiers.contains(.option)
        let extraModifier =
            modifiers.contains(.shift)
            || modifiers.contains(.control)
            || modifiers.contains(.command)
        guard hasOption, !extraModifier else { return nil }
        switch keyCode {
        case 16: return .approveTop
        case 45: return .denyTop
        case 1: return .snooze15
        case 43: return .openSettings
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
    /// the feature is on, and either the island is NOT showing the event or
    /// the display is locked (the user can't see the notch). Progress/
    /// completion noise never notifies.
    static func shouldPostNotification(
        islandVisible: Bool, notifyWhenHidden: Bool, displayLocked: Bool,
        kind: AgentEventKind
    ) -> Bool {
        guard notifyWhenHidden, kind == .accessRequest || kind == .waiting else { return false }
        return !islandVisible || displayLocked
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
        case reply
        case option(Int)
    }

    public static func cornerRadius(expanded: Bool) -> CGFloat {
        expanded ? expandedCornerRadius : closedCornerRadius
    }

    /// Fixed window size — always the expanded size plus corner-radius overhang.
    public static func windowSize() -> CGSize {
        CGSize(width: expandedWidth + expandedCornerRadius * 2, height: maxExpandedHeight)
    }

    /// The closed pill content size. Height = topInset (the menu-bar row) plus
    /// the pill height so approval controls and idle chips are never clipped —
    /// trimming to just topInset cut off the bottom of the taller approval
    /// pill.
    public static func closedSize(
        topInset: CGFloat, notchWidth: CGFloat, hasNotification: Bool = false,
        cardHeight: CGFloat = notificationHeight
    ) -> CGSize {
        if hasNotification {
            return CGSize(
                width: min(max(notchWidth, notificationWidth), expandedWidth),
                height: topInset + notificationTopGap + cardHeight)
        }
        return CGSize(width: min(max(notchWidth, 0), expandedWidth), height: topInset + pillHeight)
    }

    /// One TUI-style choice row in a closed notification: a number, a label,
    /// and optional context. Distinct from the taller control-plane row.
    public static let notificationChoiceRowHeight: CGFloat = 21
    public static let notificationChoiceDetailLineHeight: CGFloat = 11

    /// Card height for a notification. Approvals get the taller detail card
    /// plus one row per choice; completion and failure notices keep the
    /// compact height.
    static func notificationCardHeight(
        for kind: AgentEventKind?,
        choices: [String] = [],
        details: [String] = [],
        hasFreeText: Bool = false,
        hasFailure: Bool = false
    ) -> CGFloat {
        switch kind {
        case .accessRequest, .waiting: break
        default: return notificationHeight
        }
        var height = approvalNotificationHeight
        let shown = min(choices.count, ApprovalControls.maxDisplayedOptions)
        if shown > 0 {
            height += CGFloat(shown) * notificationChoiceRowHeight
            for index in 0..<shown {
                let detail =
                    index < details.count
                    ? details[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if !detail.isEmpty {
                    // Long descriptions wrap to two lines at the card width.
                    height += notificationChoiceDetailLineHeight * (detail.count > 76 ? 2 : 1)
                }
            }
            height += 6
        }
        if hasFreeText { height += 26 }
        if hasFailure { height += 30 }
        return height
    }

    /// Content origin for a closed notification: below the notch plus a small
    /// gap, never inside the notch cutout.
    public static func notificationTopOffset(topInset: CGFloat) -> CGFloat {
        topInset + notificationTopGap
    }

    /// The expanded roster content size, height-capped.
    public static func expandedSize(topInset: CGFloat, agentCount: Int) -> CGSize {
        expandedSize(topInset: topInset, agentCount: agentCount, queueCount: 0)
    }

    public static func contentHeight(
        isExpanded: Bool, topInset: CGFloat, agentCount: Int, queueCount: Int = 0,
        shelfTabVisible: Bool = false, overflowCount: Int = 0, groupCount: Int = 0,
        footerVisible: Bool = true, hasNotification: Bool = false,
        cardHeight: CGFloat = notificationHeight
    ) -> CGFloat {
        if isExpanded {
            return expandedSize(
                topInset: topInset, agentCount: agentCount, queueCount: queueCount,
                shelfTabVisible: shelfTabVisible, overflowCount: overflowCount,
                groupCount: groupCount, footerVisible: footerVisible
            ).height - topInset
        }
        if hasNotification {
            return cardHeight
        }
        return pillHeight
    }

    public static func contentHeightForTasks(
        isExpanded: Bool, topInset: CGFloat, taskCount: Int, sectionCount: Int = 2,
        shelfTabVisible: Bool = false
    ) -> CGFloat {
        if isExpanded {
            return expandedSize(
                topInset: topInset, agentCount: 0, queueCount: 0,
                shelfTabVisible: shelfTabVisible, taskCount: taskCount,
                sectionCount: sectionCount, isTasksTab: true
            ).height - topInset
        }
        return pillHeight
    }

    /// F13 stable roster viewport: reserve one row even when the roster is
    /// empty, then cap growth at the available viewport height. `groupCount`
    /// adds the grouped section-header rows to the natural height so the
    /// scroll area fits its headers without scrolling when they fit.
    static func stableRosterHeight(
        agentCount: Int, availableHeight: CGFloat, rowHeight: CGFloat = rowHeight,
        groupCount: Int = 0
    ) -> CGFloat {
        let natural =
            CGFloat(max(agentCount, 0)) * rowHeight
            + CGFloat(max(groupCount, 0)) * sectionHeaderHeight
        return max(min(max(natural, rowHeight), max(availableHeight, 0)), 0)
    }

    /// Determines whether a display has a hardware notch based on safe-area and auxiliary regions.
    public static func hasNotch(safeTop: CGFloat, auxLeft: CGFloat, auxRight: CGFloat) -> Bool {
        safeTop > 0 && (auxLeft > 0 || auxRight > 0)
    }

    public static func notchWidth(
        screenWidth: CGFloat, auxLeft: CGFloat, auxRight: CGFloat, safeTop: CGFloat
    ) -> CGFloat {
        guard
            hasNotch(safeTop: safeTop, auxLeft: auxLeft, auxRight: auxRight),
            auxLeft > 0, auxRight > 0
        else { return notchlessFallbackWidth }
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

    /// Content cross-fade policy for the `isExpanded` flip. `.synced` rides the
    /// smooth background morph (opacity + top-anchored scale); `.instant` is
    /// the reduce-motion path (opacity only, driven by the 0.1s linear morph).
    public static func contentTransition(reduceMotion: Bool) -> ContentTransitionKind {
        reduceMotion ? .instant : .synced
    }

    /// The content transition and the background morph are always coordinated:
    /// both smooth (spring + synced) without reduce motion, both near-instant
    /// (linear + instant) with it. This is the invariant the notch animation
    /// fix enforces so text never pops before the background finishes morphing.
    public static func morphMatchesContent(reduceMotion: Bool) -> Bool {
        switch reduceMotion {
        case true:
            return morphStyle(reduceMotion: true) == .linear
                && contentTransition(reduceMotion: true) == .instant
        case false:
            return morphStyle(reduceMotion: false) == .spring
                && contentTransition(reduceMotion: false) == .synced
        }
    }

    public static func hoverScale(isHovered: Bool, isExpanded: Bool) -> CGFloat {
        guard isHovered else { return 1 }
        return isExpanded ? hoverBounceExpanded : hoverBounceClosed
    }

    public static func shouldExpand(hovering: Bool, hasAgents: Bool) -> Bool {
        hovering
    }

    /// Hover-expansion is suppressed while a notification popup is on screen.
    /// Otherwise the panel morphs out from under the pointer before the
    /// popup's Approve/Deny buttons can be clicked.
    public static func shouldExpandOnHover(
        hovering: Bool, isExpanded: Bool, hasPopup: Bool
    ) -> Bool {
        hovering && !isExpanded && !hasPopup
    }

    /// Stable pane identity used by every approval surface. Standalone agents
    /// have no multiplexer pane id, so the synthetic `standalone:<source>` id
    /// keeps the notch, Notification Center, and menu-bar actions in agreement.
    public static func actionablePaneId(paneId: String?, source: String?) -> String? {
        if let paneId, !paneId.isEmpty { return paneId }
        guard let source, !source.isEmpty else { return nil }
        return "standalone:\(source)"
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
        kind == "accessRequest" || kind == "access_request" || kind == "waiting"
    }

    /// Clean an approval prompt without destroying what the user is deciding
    /// on. The HUD cleaner shortens absolute paths and rejects JSON, which is
    /// the opposite of what a security prompt needs; this keeps the command,
    /// file path, or question intact and only removes terminal control codes
    /// and excess whitespace.
    public static func cleanApprovalDetail(
        _ text: String, maxCharacters: Int = 360
    ) -> String {
        var s = LogFormatter.stripControlCharacters(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = s.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map { line in
            String(line)
                .replacingOccurrences(
                    of: "[\\t ]+", with: " ", options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
        }
        s = lines.joined(separator: "\n")
        s = s.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        guard maxCharacters > 0, s.count > maxCharacters else { return s }
        let prefix = String(s.prefix(maxCharacters - 3))
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    /// True when a title or message says only that an agent is blocked, with
    /// no command, path, tool, or question attached. Generic text must not
    /// displace the live pane excerpt.
    public static func isGenericApprovalText(_ text: String?) -> Bool {
        guard let text else { return true }
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }
        let generic: Set<String> = [
            "needs input", "needs approval", "agent requires input",
            "agent needs input", "agent needs approval", "approval required",
            "permission required", "waiting", "blocked",
            "claude needs approval", "claude needs your input",
            "claude needs your approval", "opencode needs approval",
        ]
        if generic.contains(lower) { return true }
        return lower.hasPrefix("agent requires input")
    }

    /// Distill a terminal pane tail into a short approval excerpt. Blank
    /// lines, separator rules, and status-bar chrome drop out; the last few
    /// meaningful lines (usually the prompt itself) stay.
    public static func approvalExcerpt(from raw: String, maxLines: Int = 4) -> String {
        guard !raw.isEmpty else { return "" }
        let cleaned = LogFormatter.cleanedTail(
            raw, maxLines: 18, maxLineLength: 200)
        let meaningful = cleaned.filter { line in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return false }
            let lower = stripped.lowercased()
            if lower.contains("esc to interrupt") { return false }
            if lower.hasPrefix("press ") && lower.contains(" to ") { return false }
            if lower.hasPrefix("tokens:") || lower.hasPrefix("context:") {
                return false
            }
            return stripped.unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0)
            }
        }
        return meaningful.suffix(max(maxLines, 1)).joined(separator: "\n")
    }

    // MARK: - Diff-stat cache (plan 016 1a)

    /// Cache key for a per-agent `git diff --shortstat` summary. `id` alone
    /// is not unique (standalone agents share `paneId == nil`), and a summary
    /// is only valid for the cwd it was computed in — both go in the key so
    /// late-arriving old-cwd results can never clobber a fresh new-cwd value.
    public struct DiffStatCacheKey: Hashable, Sendable {
        public let id: String
        public let cwd: String

        public init(id: String, cwd: String) {
            self.id = id
            self.cwd = cwd
        }
    }

    /// Pure diff-stat cache behavior: parse `git diff --shortstat` output and
    /// prune dead (id, cwd) keys so one agent churning many cwds can't grow
    /// the cache without bound.
    public enum DiffStatCache {
        /// First capture group of `pattern` matched against `raw`, or nil.
        /// NSRegularExpression (not a bare-slash regex literal) so the pure
        /// harness `swiftc` line compiles it.
        private static func capture(_ pattern: String, in raw: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, range: nsRange),
                let range = Range(match.range(at: 1), in: raw)
            else { return nil }
            return String(raw[range])
        }

        /// Parse `git diff --shortstat` output (e.g. " 1 file changed, 2
        /// insertions(+), 3 deletions(-)") into "+N −M". Insertion-only and
        /// deletion-only output work; empty or garbage input returns nil.
        public static func parseShortstat(_ raw: String) -> String? {
            let inserted = capture("(\\d+) insertion", in: raw)
            let deleted = capture("(\\d+) deletion", in: raw)
            guard inserted != nil || deleted != nil else { return nil }
            return "+\(inserted ?? "0") −\(deleted ?? "0")"
        }

        /// Remove every key not present in `liveKeys` (drop stale (id, cwd)
        /// entries on write).
        public static func prune(
            _ cache: [DiffStatCacheKey: String],
            liveKeys: Set<DiffStatCacheKey>
        ) -> [DiffStatCacheKey: String] {
            cache.filter { liveKeys.contains($0.key) }
        }
    }

    // MARK: - Peek overlay (plan 016 3a)

    /// Gap between the island edge and a peek panel docked beside it.
    public static let peekGap: CGFloat = 8

    /// Convert a SwiftUI `.global` frame (window content space, top-left
    /// origin) into AppKit screen coordinates (bottom-left origin). The island
    /// panel is borderless, so its content fills the window frame.
    public static func screenRect(fromGlobalRect rect: CGRect, windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + rect.minX,
            y: windowFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    /// Calculates the peek panel frame docked beside or below the island.
    public static func peekFrame(
        anchor islandFrame: CGRect, screenFrame: CGRect, size: CGSize, scale: CGFloat = 1
    ) -> CGRect {
        let w = min(max(size.width, 0), screenFrame.width)
        let h = min(max(size.height, 0), screenFrame.height)
        guard w > 0, h > 0 else {
            return alignedToBackingPixelGrid(.zero, scale: scale)
        }
        var x: CGFloat
        var y: CGFloat
        var width = w
        var height = h

        let rightRoom = screenFrame.maxX - (islandFrame.maxX + peekGap)
        let leftRoom = islandFrame.minX - peekGap - screenFrame.minX
        if rightRoom > 0, rightRoom >= leftRoom {
            x = islandFrame.maxX + peekGap
            width = min(w, rightRoom)
            y = islandFrame.minY
        } else if leftRoom > 0 {
            x = islandFrame.minX - peekGap - min(w, leftRoom)
            width = min(w, leftRoom)
            y = islandFrame.minY
        } else {
            let roomBelow = screenFrame.maxY - (islandFrame.maxY + peekGap)
            if roomBelow > 0 { height = min(h, roomBelow) }
            x = islandFrame.midX - w / 2
            y = islandFrame.maxY + peekGap
        }

        x = min(max(x, screenFrame.minX), screenFrame.maxX - width)
        y = min(max(y, screenFrame.minY), screenFrame.maxY - height)
        return alignedToBackingPixelGrid(
            CGRect(x: x, y: y, width: width, height: height), scale: scale)
    }

    // MARK: - Keyboard row navigation (plan 016 4b)

    /// Next focusable row index after `current`, or nil when `current` is the
    /// last row (or the roster has fewer than two rows). Never wraps. The UI
    /// seeds `current` with -1 when nothing is focused yet so the first
    /// arrow-down focuses row 0.
    public static func rowIndex(after current: Int, count: Int) -> Int? {
        let next = current + 1
        return next >= 0 && next < count ? next : nil
    }

    /// Previous focusable row index before `current`, or nil when `current`
    /// is the first row (or the roster has fewer than two rows). Never wraps.
    /// The UI seeds `current` with `count` when nothing is focused yet so the
    /// first arrow-up focuses the last row.
    public static func rowIndex(before current: Int, count: Int) -> Int? {
        let prev = current - 1
        return prev >= 0 && prev < count ? prev : nil
    }
}

/// Cleans raw terminal output by stripping ANSI escapes and control characters.
public enum LogFormatter: Sendable {
    public static func cleanedTail(
        _ raw: String, maxLines: Int, maxLineLength: Int
    ) -> [String] {
        let lineCap = max(maxLines, 1)
        let lengthCap = max(maxLineLength, 1)
        return raw.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map(stripControlCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.count > lengthCap ? String($0.prefix(lengthCap)) : $0 }
            .suffix(lineCap)
            .map { $0 }
    }

    /// Remove ANSI escape sequences (CSI, OSC, and bare two-char escapes) and
    /// any remaining C0/C1 control characters. Newlines never reach here (the
    /// input is already split), so every control scalar below 0x20 or in
    /// 0x7F...0x9F is dropped; CJK (U+4E00+) and emoji (U+1F300+) are untouched.
    public static func cleanAnsi(_ text: String) -> String {
        stripControlCharacters(text)
    }

    public static func stripControlCharacters(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        enum State {
            case normal, escape, csi, osc, oscEsc
        }
        var state: State = .normal
        for char in text {
            guard let scalar = char.unicodeScalars.first else { continue }
            let value = scalar.value
            switch state {
            case .normal:
                if char == "\u{1B}" {
                    state = .escape
                } else if value < 0x20 || (0x7F...0x9F).contains(value)
                    || (0x2800...0x28FF).contains(value)
                {
                    continue
                } else {
                    result.append(char)
                }
            case .escape:
                if char == "[" {
                    state = .csi
                } else if char == "]" {
                    state = .osc
                } else {
                    state = .normal  // bare two-char escape consumed
                }
            case .csi:
                if (0x40...0x7E).contains(value) { state = .normal }
            case .osc:
                if char == "\u{07}" || char == "\u{00}" {
                    state = .normal
                } else if char == "\u{1B}" {
                    state = .oscEsc
                }
            case .oscEsc:
                if char == "\\" {
                    state = .normal
                } else if char != "\u{1B}" {
                    state = .osc
                }
            }
        }
        return result
    }
}
