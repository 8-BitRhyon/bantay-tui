import AppKit
import SwiftUI
import UserNotifications

@MainActor
struct NotchStatusView: View {
    @EnvironmentObject var eventManager: AgentEventManager
    @AppStorage("idleStyle") private var idleStyleRaw = IslandMetrics.IdleStyle.project.rawValue
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var opacity: Double = 0
    @State private var showDetail = false
    @State private var hoveredRow: String?
    @State private var showThoughtBubble = false
    @State private var composingPaneId: String?
    @State private var promptText = ""
    /// Delivery feedback for the compose box. Kept visible after a failed
    /// send so the draft is never silently discarded.
    @State private var composeNotice: String?
    /// Free-text answer for the closed card. Choices never trap an answer.
    @State private var cardAnswer = ""
    /// Inline failure from the last card action, with a retry closure.
    @State private var cardFailure: String?
    @State private var cardRetry: (() -> Void)?
    /// One-shot feedback for a delivered card action. The card holds for a
    /// short commit beat before it leaves so the input feels acknowledged.
    @State private var commitToken = 0
    @State private var commitTask: Task<Void, Never>?
    /// Drives the refusal shake when delivery fails.
    @State private var shakeTrigger: CGFloat = 0
    /// Second-click arming for risky prompts (opt-in).
    @State private var confirmArmed = false
    @State private var confirmTask: Task<Void, Never>?
    @State private var composeNoticeTask: Task<Void, Never>?
    @State private var pulse = false
    @State private var queueSelections: [String: Set<Int>] = [:]
    @State private var showWelcome = false
    @State private var now = Date()
    @State private var selectedTab: ShelfTab = .agents

    private var showTasks: Bool { selectedTab == .tasks }
    private var showAttention: Bool { selectedTab == .attention }
    private var showHistory: Bool { selectedTab == .history }
    private var showShelf: Bool { selectedTab == .shelf }
    private var showMedia: Bool { selectedTab == .media }

    @State private var historyMode: HistoryMode = .timeline
    /// Read-only mirror of `NotchHUDConfig.shared.panelPinned` so the header
    /// icon stays reactive; the config is the single behavioral source of
    /// truth (all logic reads it, and it is the only writer of the defaults).
    @AppStorage("panelPinned") private var panelPinned = false
    /// Live "peek" tail for a hovered/expanded agent — shows what the agent is
    /// actually doing inline (the core promise of the control plane).
    @State private var peekingPaneId: String?
    @State private var peekText: String = ""
    @State private var peekTask: Task<Void, Never>?
    @State private var clipboardItems: [ClipboardItem] = []
    @State private var notificationQueue: [AgentEvent] = []
    @State private var queueIndex = 0
    @State private var notificationDismissTask: Task<Void, Never>? = nil
    /// Live pane excerpt for approvals whose event carries no command or
    /// prompt (multiplexer status events). Fetched asynchronously.
    @State private var notificationDetail: String = ""
    @State private var notificationDetailTask: Task<Void, Never>?
    /// Brief glow on the shelf panel when a drop lands (user feedback).
    @State private var shelfDropGlow = false
    /// The persisted, thumbnail-rendering shelf (ShelfStore owns files).
    @ObservedObject private var shelfStore = ShelfStore.shared
    @State private var lastChangeCount = NSPasteboard.general.changeCount
    @State private var legacyKeyMonitor: Any?
    /// Keyboard-navigation cursor over `mergedRoster` (plan 016 4b). Nil means
    /// no row is focused; arrow keys move it, Enter activates, Esc clears.
    @State private var focusedRow: Int?
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @FocusState private var promptFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let adapter: any PlexerAdapter = PlexerFactory.makeAdapter()

    /// Docked idle chips sit flush in the notch row; only expanded/center drop
    /// below the menu bar. Matches the BoringNotch idle look.
    private var chipTopOffset: CGFloat {
        IslandMetrics.effectiveTopOffset(
            side: NotchHUDConfig.shared.islandDockSide, isExpanded: isExpanded,
            topInset: AppDelegate.topInset)
    }

    private var hasTransientEvent: Bool { eventManager.currentEvent != nil }

    /// True in centered idle: the pill spans the notch (black bar behind it)
    /// and details split to both sides.
    private var isCenteredIdle: Bool {
        !isExpanded && !hasTransientEvent
            && NotchHUDConfig.shared.islandDockSide == .center
    }

    /// Centered closed state, including non-actionable working/completed
    /// events. Approval events are handled before this state in `content`.
    private var isCenteredClosed: Bool {
        !isExpanded && NotchHUDConfig.shared.islandDockSide == .center
    }

    private var closedPillWidth: CGFloat {
        let full = min(AppDelegate.notchWidth, IslandMetrics.expandedWidth)
        guard !hasTransientEvent else { return full }
        let config = NotchHUDConfig.shared
        let style = IslandMetrics.IdleStyle(rawValue: idleStyleRaw) ?? .project
        if isCenteredIdle {
            return full
        }
        if style == .project {
            let projects = IslandMetrics.compactProjectLabels(
                projects: eventManager.agents.map { $0.projectContext?.project },
                sources: eventManager.agents.map(\.source),
                startedAt: eventManager.agents.map(\.startedAt))
            let lead = IslandMetrics.cleanHUDText(projects.first ?? "", maxCharacters: 14)
            var width = IslandMetrics.idleProjectChipWidth(
                nameLength: lead.isEmpty ? 6 : lead.count,
                agentCount: eventManager.agents.count,
                projectCount: max(projects.count, 1))
            if config.avoidMenuBarIcons {
                let clearance = IslandMetrics.MenuBarClearance.maxIdleWidth(
                    side: config.islandDockSide, notchWidth: AppDelegate.notchWidth,
                    screenWidth: AppDelegate.islandScreen()?.frame.width
                        ?? AppDelegate.notchWidth,
                    auxLeft: AppDelegate.auxLeftWidth, auxRight: AppDelegate.auxRightWidth)
                width = min(width, max(clearance, IslandMetrics.idleChipWidth))
            }
            return max(width, IslandMetrics.idleChipWidth)
        }
        var width = IslandMetrics.idleClosedWidth(
            style: style,
            agentCount: eventManager.agents.count,
            maxChips: config.clampedIdleMaxChips,
            nameLengths: eventManager.agents.map(\.source.count),
            notchWidth: AppDelegate.notchWidth)
        if config.avoidMenuBarIcons {
            let clearance = IslandMetrics.MenuBarClearance.maxIdleWidth(
                side: config.islandDockSide, notchWidth: AppDelegate.notchWidth,
                screenWidth: AppDelegate.islandScreen()?.frame.width
                    ?? AppDelegate.notchWidth,
                auxLeft: AppDelegate.auxLeftWidth, auxRight: AppDelegate.auxRightWidth)
            let fit = IslandMetrics.idleFitChips(
                agentCount: eventManager.agents.count,
                maxChips: config.clampedIdleMaxChips,
                nameLengths: eventManager.agents.map(\.source.count),
                availableWidth: max(clearance - IslandMetrics.idleOverflowPad, 0))
            width = IslandMetrics.idleStripWidth(
                style: config.idleStyle,
                agentCount: min(eventManager.agents.count, max(fit, 1)),
                maxChips: max(fit, 1),
                nameLengths: eventManager.agents.map(\.source.count))
            width = min(width, max(clearance, IslandMetrics.idleChipWidth))
        }
        return width
    }

    /// Chips actually shown in the idle strip: respects the menu-bar
    /// clearance fit (fallback to the configured cap).
    private var idleShownCount: Int {
        let config = NotchHUDConfig.shared
        let count = visibleAgents.count
        guard !isCenteredIdle, config.avoidMenuBarIcons else {
            return IslandMetrics.idleShownChips(
                agentCount: count, maxChips: config.clampedIdleMaxChips)
        }
        let clearance = IslandMetrics.MenuBarClearance.maxIdleWidth(
            side: config.islandDockSide, notchWidth: AppDelegate.notchWidth,
            screenWidth: AppDelegate.islandScreen()?.frame.width ?? AppDelegate.notchWidth,
            auxLeft: AppDelegate.auxLeftWidth, auxRight: AppDelegate.auxRightWidth)
        return IslandMetrics.idleFitChips(
            agentCount: count, maxChips: config.clampedIdleMaxChips,
            nameLengths: visibleAgents.map(\.source.count),
            availableWidth: max(clearance - IslandMetrics.idleOverflowPad, 0))
    }

    private var hasActiveNotification: Bool {
        !isExpanded && activeNotification != nil
    }

    /// The card on screen: the selected queue entry, clamped. Older entries
    /// are never silently replaced; the stepper reaches every queued card.
    private var activeNotification: AgentEvent? {
        guard !notificationQueue.isEmpty else { return nil }
        let index = IslandMetrics.notificationQueueClampIndex(
            queueIndex, count: notificationQueue.count)
        return notificationQueue[index]
    }

    private var activeNotificationCardHeight: CGFloat {
        IslandMetrics.notificationCardHeight(for: activeNotification?.kind)
    }

    /// Closed notifications start below the physical notch. Idle chips still
    /// sit flush in the notch row; only the card content moves down.
    private var contentTopOffset: CGFloat {
        if hasActiveNotification {
            return IslandMetrics.notificationTopOffset(topInset: AppDelegate.topInset)
        }
        return chipTopOffset
    }

    private var islandWidth: CGFloat {
        if isExpanded {
            return IslandMetrics.expandedWidth
        }
        if hasActiveNotification {
            return IslandMetrics.notificationWidth
        }
        if isCenteredClosed {
            return IslandMetrics.windowSize().width
        }
        return closedPillWidth
    }

    /// Idle placement: slide the closed chip beside the notch (left/right) or
    /// keep it centered underneath it. Position anchoring stays 100% stable
    /// regardless of transient event state (eliminates position jumping).
    private var islandOffsetX: CGFloat {
        guard !isExpanded else { return 0 }
        if hasActiveNotification { return 0 }
        return IslandMetrics.dockOffset(
            side: NotchHUDConfig.shared.islandDockSide,
            notchWidth: AppDelegate.notchWidth,
            chipWidth: closedPillWidth)
    }

    /// Structured v2 layout metrics for the inbox: approval cards, working
    /// rows, and idle rows each carry their own height so the panel fits
    /// its content instead of clipping against uniform-row math.
    private var rosterMetrics: IslandMetrics.RosterLayoutMetrics {
        let blocked = approvalQueueAgents.count
        let choiceRows = approvalQueueAgents.reduce(0) { total, agent in
            let controls = agent.approval
            guard !controls.isYesNo else { return total }
            return total + min(controls.choices.count, 6)
        }
        let working = mergedRoster.filter {
            $0.kind != .accessRequest && $0.kind != .waiting
                && ($0.isWorking || $0.kind == .failed)
        }.count
        let idle = max(mergedRoster.count - blocked - working, 0)
        var groups = 0
        if blocked > 0 { groups += 1 }
        if working > 0 { groups += 1 }
        if idle > 0 { groups += 1 }
        return IslandMetrics.RosterLayoutMetrics(
            approvalCardCount: blocked,
            approvalChoiceRowCount: choiceRows,
            workingRowCount: working,
            idleRowCount: idle,
            groupCount: groups)
    }

    /// Panel size for the agents inbox. Falls back to the legacy two-row
    /// minimum when the roster is empty so the empty state never clips.
    private var agentPanelSize: CGSize {
        let shelfVisible = NotchHUDConfig.shared.showShelfTab
        if mergedRoster.isEmpty {
            return IslandMetrics.expandedSize(
                topInset: chipTopOffset, agentCount: 2, queueCount: 0,
                shelfTabVisible: shelfVisible, overflowCount: 0, groupCount: 0,
                footerVisible: false)
        }
        return IslandMetrics.expandedSize(
            topInset: chipTopOffset, roster: rosterMetrics,
            shelfTabVisible: shelfVisible, footerVisible: false)
    }

    private var islandHeight: CGFloat {
        if isExpanded {
            if showTasks {
                return IslandMetrics.expandedSize(
                    topInset: chipTopOffset, agentCount: 0, queueCount: 0,
                    shelfTabVisible: NotchHUDConfig.shared.showShelfTab,
                    overflowCount: 0, groupCount: 0, footerVisible: false,
                    taskCount: TaskStore.shared.tasks.count, sectionCount: 3,
                    isTasksTab: true
                ).height
            } else if showHistory {
                return min(
                    max(historyContentHeight + chipTopOffset, IslandMetrics.minExpandedHeight),
                    IslandMetrics.maxExpandedHeight)
            } else if showShelf || showMedia {
                let itemCount =
                    showShelf
                    ? max(shelfStore.files.count + clipboardItems.count, 2) : 3
                return IslandMetrics.expandedSize(
                    topInset: chipTopOffset, agentCount: itemCount,
                    queueCount: 0,
                    shelfTabVisible: NotchHUDConfig.shared.showShelfTab,
                    overflowCount: 0, groupCount: 0, footerVisible: false
                ).height
            } else {
                return agentPanelSize.height
            }
        }
        if hasActiveNotification {
            return IslandMetrics.closedSize(
                topInset: AppDelegate.topInset,
                notchWidth: IslandMetrics.notificationWidth,
                hasNotification: true,
                cardHeight: activeNotificationCardHeight
            ).height
        }
        return IslandMetrics.closedSize(topInset: chipTopOffset, notchWidth: islandWidth).height
    }

    private var historyContentHeight: CGFloat {
        380
    }

    private var contentHeight: CGFloat {
        if hasActiveNotification {
            return activeNotificationCardHeight
        }
        if showHistory {
            return historyContentHeight
        }
        if showTasks {
            return IslandMetrics.contentHeightForTasks(
                isExpanded: isExpanded,
                topInset: chipTopOffset,
                taskCount: TaskStore.shared.tasks.count,
                sectionCount: 3,
                shelfTabVisible: NotchHUDConfig.shared.showShelfTab
            )
        } else if showShelf || showMedia {
            let itemCount =
                showShelf
                ? max(shelfStore.files.count + clipboardItems.count, 2) : 3
            return IslandMetrics.contentHeight(
                isExpanded: isExpanded, topInset: chipTopOffset,
                agentCount: itemCount, queueCount: 0,
                shelfTabVisible: NotchHUDConfig.shared.showShelfTab,
                overflowCount: 0,
                groupCount: 0,
                footerVisible: false)
        } else {
            return agentPanelSize.height - chipTopOffset
        }
    }

    private var contentFrameWidth: CGFloat {
        islandWidth
    }

    /// Agents blocked on an approval — pinned at the top of the expanded
    /// control plane. Muted sources are excluded so they cannot queue up.
    private var approvalQueueAgents: [AgentSnapshot] {
        mergedRoster.filter {
            $0.kind == .accessRequest || $0.kind == .waiting
        }
    }

    /// Roster minus muted sources; everything user-visible derives from this.
    private var visibleAgents: [AgentSnapshot] {
        let muted = NotchHUDConfig.shared.mutedSources
        guard !muted.isEmpty else { return eventManager.agents }
        return eventManager.agents.filter { !muted.contains($0.source) }
    }

    /// Keyboard-navigation target for reply and review shortcuts: the
    /// focused row when set, otherwise the top approval.
    private var focusedAgent: AgentSnapshot? {
        guard let focusedRow, mergedRoster.indices.contains(focusedRow) else { return nil }
        return mergedRoster[focusedRow]
    }

    /// The roster as rendered: muted sources dropped, approval variance and
    /// choices attached from the manager's pending-approval bookkeeping.
    private var mergedRoster: [AgentSnapshot] {
        eventManager.mergeApprovals(into: visibleAgents)
    }

    private var cornerRad: CGFloat {
        if isExpanded {
            return IslandMetrics.expandedCornerRadius
        }
        if hasActiveNotification {
            return IslandMetrics.notificationCornerRadius
        }
        return IslandMetrics.closedCornerRadius
    }

    private var morphAnimation: Animation {
        switch IslandMetrics.morphStyle(reduceMotion: reduceMotion) {
        case .spring:
            .smooth(duration: IslandMetrics.morphDuration, extraBounce: 0)
        case .linear:
            .linear(duration: 0.1)
        }
    }

    /// Content transition coordinated with the background shape morph.
    private var contentTransition: AnyTransition {
        guard IslandMetrics.contentTransition(reduceMotion: reduceMotion) == .synced else {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity.animation(.easeOut(duration: 0.05)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            islandBackground
            content
                .frame(width: contentFrameWidth, height: contentHeight, alignment: .top)
                .offset(y: contentTopOffset)
            if let composeNotice, isExpanded {
                Text(composeNotice)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            composeNotice.hasPrefix("Sent")
                                ? BantayTheme.statusCompleted.opacity(0.9)
                                : BantayTheme.statusFailed.opacity(0.9))
                    )
                    .padding(.bottom, 8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(edgeGlow)
        .overlay(SystemHUDOverlayView(), alignment: .bottom)
        .frame(
            width: isExpanded ? islandWidth : (islandWidth + cornerRad * 2),
            height: islandHeight,
            alignment: .top
        )
        .clipped()
        .shadow(
            color: Color.black.opacity(isExpanded ? 0.50 : 0),
            radius: isExpanded ? 16 : 0,
            x: 0,
            y: isExpanded ? 8 : 0
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        IslandHitTracker.interactiveRect = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global)) { newFrame in
                        IslandHitTracker.interactiveRect = newFrame
                    }
            }
        )
        .onHover { hovering in
            eventManager.setActive(hovering)
            handleHover(hovering)
        }
        .frame(
            width: IslandMetrics.windowSize().width,
            height: IslandMetrics.windowSize().height,
            alignment: .top
        )
        .offset(x: islandOffsetX)
        .animation(morphAnimation, value: isExpanded)
        .background(Color.clear.allowsHitTesting(false))
        .opacity(opacity)
        .animation(morphAnimation, value: isExpanded)
        .onAppear {
            if !ProcessInfo.processInfo.isOperatingSystemAtLeast(
                .init(majorVersion: 14, minorVersion: 0, patchVersion: 0))
            {
                installLegacyKeyMonitor()
            }
            handleAppear()
        }
        .onDisappear { removeLegacyKeyMonitor() }
        .onChange(of: isExpanded) { _ in
            if !isExpanded { cancelComposing() }
            // Clear recents on COLLAPSE, not expand: marking them seen when
            // the panel opens would wipe the very list you just expanded to
            // see. "Since you last looked" semantics — the recents are a
            // what-happened-while-away buffer.
            if !isExpanded { eventManager.markRecentCompletionsSeen() }
            eventManager.setActive(isExpanded)
        }
        .onChange(of: eventManager.currentEvent) { _ in handleEventChange() }
        .onChange(of: eventManager.agents) { _ in handleAgentsChange() }
        .onReceive(
            NotificationCenter.default.publisher(for: .notchVisibilityChanged)
        ) { _ in
            updateIslandVisibility()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .notchFileDragEntered)
        ) { _ in
            handleFileDragEntered()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .notchFilesDropped)
        ) { note in
            if let urls = note.userInfo?["urls"] as? [URL] {
                handleFilesDropped(urls)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .notchCollapseRequested)
        ) { _ in
            if isExpanded { expandTo(false) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .notchExpandRequested)
        ) { _ in
            if !isExpanded { expandTo(true) }
        }
        .onReceive(
            Timer.publish(every: 2, on: .main, in: .common).autoconnect()
        ) { date in
            // Elapsed labels render minutes; a two-second wake keeps clipboard
            // history responsive while halving idle timer wakeups. Advance
            // the clock only when the visible label can actually change.
            if peekingPaneId != nil {
                now = date
            } else if isExpanded && NotchHUDConfig.shared.showElapsedTime,
                date.timeIntervalSince(now) >= 5
            {
                now = date
            }
            pollClipboard(at: date)
        }
        .onChange(of: activeNotification?.id) { _ in
            cardAnswer = ""
            cardFailure = nil
            cardRetry = nil
            confirmArmed = false
            commitTask?.cancel()
            commitTask = nil
        }
        .onChange(of: hasSeenOnboarding) { seen in
            if !seen { showWelcome = true }
        }
        .focusable()
        .modifier(FocusEffectDisabledCompat())
        .modifier(
            ShortcutKeyPressModifier { char in
                guard canHandleRosterShortcuts,
                    let shortcut = IslandMetrics.shortcutKey(for: char)
                else {
                    return false
                }
                return handleShortcut(shortcut)
            }
        )
        .modifier(
            NavigationKeyPressModifier { keyCode in
                handleNavigationKey(keyCode)
            }
        )
        .sheet(isPresented: $showWelcome) {
            WelcomeView()
        }
    }

    /// Peripheral-vision cue: pulsing amber/red border when agents are
    /// blocked on an approval. Respects reduced motion (steady glow).
    @ViewBuilder
    private var edgeGlow: some View {
        let blocked = !approvalQueueAgents.isEmpty
        let config = NotchHUDConfig.shared
        if config.edgeGlowEnabled && blocked && !isExpanded {
            EdgeGlowView(
                cornerRadius: cornerRad,
                width: islandWidth,
                height: islandHeight,
                reduceMotion: reduceMotion
            )
        }
    }

    @MainActor
    static func isTextInputFocused(in window: NSWindow?) -> Bool {
        guard let window = window ?? AppDelegate.window,
            let responder = window.firstResponder
        else {
            return false
        }
        return responder is NSText || responder is NSTextField
    }

    private var canHandleRosterShortcuts: Bool {
        isExpanded
            && selectedTab == .agents
            && composingPaneId == nil
            && !Self.isTextInputFocused(in: AppDelegate.window)
    }

    /// Single-key roster shortcuts (Y/N/digits) when the island is key and
    /// shortcuts are enabled. Applies to the top pending approval.
    /// Returns true when an action was performed, false otherwise.
    @discardableResult
    private func handleShortcut(_ shortcut: IslandMetrics.ApprovalShortcut) -> Bool {
        if shortcut == .reply {
            guard NotchHUDConfig.shared.keyboardShortcuts,
                canHandleRosterShortcuts,
                let agent = approvalQueueAgents.first ?? focusedAgent
            else {
                return false
            }
            beginComposing(agent)
            return true
        }
        guard NotchHUDConfig.shared.keyboardShortcuts,
            canHandleRosterShortcuts,
            !eventManager.isResolving(agent: approvalQueueAgents.first),
            let agent = approvalQueueAgents.first,
            let paneId = IslandMetrics.actionablePaneId(
                paneId: agent.paneId, source: agent.source)
        else {
            return false
        }
        switch shortcut {
        case .approve:
            // Multi-select: Y submits the toggled selection; otherwise plain
            // approve. The pill and the roster share queueSelections (keyed
            // by pane id), so digits + Y work consistently from both.
            if agent.approval.isMulti {
                let numbers = IslandMetrics.ApprovalControls.selectionNumbers(
                    queueSelections[paneId] ?? [])
                eventManager.approveMulti(paneId: paneId, selections: numbers)
                queueSelections.removeValue(forKey: paneId)
            } else {
                eventManager.approve(paneId: paneId)
            }
            return true
        case .deny:
            eventManager.deny(paneId: paneId)
            return true
        case .reply:
            // Handled before the approval guard above; reply needs no pane.
            return true
        case .option(let number):
            if agent.approval.isMulti {
                queueSelections[paneId] = IslandMetrics.ApprovalControls.toggling(
                    queueSelections[paneId] ?? [], index: number - 1)
            } else {
                eventManager.approveChoice(paneId: paneId, choice: number)
            }
            return true
        }
    }

    /// Arrow-key / Enter / Esc roster navigation (plan 016 4b). Pure cursor
    /// movement delegates to `IslandMetrics.rowIndex`; Enter activates the
    /// focused row's primary action; Esc clears focus. Returns true when
    /// handled.
    private func handleNavigationKey(_ keyCode: UInt16) -> Bool {
        guard canHandleRosterShortcuts else { return false }
        let count = mergedRoster.count
        let current = focusedRow
        switch keyCode {
        case 126:  // up arrow
            focusedRow = IslandMetrics.rowIndex(before: current ?? 0, count: count)
            return focusedRow != current || current != nil
        case 125:  // down arrow
            focusedRow = IslandMetrics.rowIndex(after: current ?? -1, count: count)
            return true
        case 36:  // return
            guard let index = focusedRow, mergedRoster.indices.contains(index) else {
                return false
            }
            activateRow(mergedRoster[index])
            return true
        case 53:  // escape
            focusedRow = nil
            return true
        default:
            return false
        }
    }

    /// Primary keyboard action for a focused roster row: queue rows approve,
    /// roster rows expand/peek. Mirrors the hover/click primary action.
    private func activateRow(_ agent: AgentSnapshot) {
        if approvalQueueAgents.contains(where: {
            $0.paneId == agent.paneId
                && ($0.kind == .accessRequest || $0.kind == .waiting)
        }) {
            guard
                let paneId = IslandMetrics.actionablePaneId(
                    paneId: agent.paneId, source: agent.source)
            else { return }
            eventManager.approve(paneId: paneId)
        } else {
            showDetail = true
            fetchPeek(paneId: agent.paneId ?? agent.source)
        }
    }

    /// macOS 13 fallback for the single-key roster shortcuts: `.onKeyPress`
    /// is macOS 14+. Mirrors its scope (panel key, expanded, not composing).
    /// Also routes arrow/Enter/Esc navigation keys.
    private func installLegacyKeyMonitor() {
        guard legacyKeyMonitor == nil else { return }
        legacyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === AppDelegate.window,
                canHandleRosterShortcuts
            else {
                return event
            }
            let keyCode = event.keyCode
            if handleNavigationKey(keyCode) {
                return nil
            }
            guard NotchHUDConfig.shared.keyboardShortcuts,
                let char = event.charactersIgnoringModifiers?.first,
                let shortcut = IslandMetrics.shortcutKey(for: char)
            else {
                return event
            }
            if handleShortcut(shortcut) {
                return nil
            }
            return event
        }
    }

    private func removeLegacyKeyMonitor() {
        if let monitor = legacyKeyMonitor {
            NSEvent.removeMonitor(monitor)
            legacyKeyMonitor = nil
        }
    }

    /// Fetches a live output tail asynchronously to display in the hover peek area.
    private func fetchPeek(paneId: String) {
        guard peekingPaneId != paneId else { return }
        peekingPaneId = paneId
        peekTask?.cancel()
        peekTask = Task.detached { [adapter] in
            var raw = ""
            if !paneId.hasPrefix("standalone:") {
                raw = await adapter.captureTail(paneId: paneId, lines: 6)
            }
            var cleaned = LogFormatter.cleanedTail(raw, maxLines: 6, maxLineLength: 120)
                .joined(separator: "\n")
            if cleaned.isEmpty {
                let agentName = paneId.replacingOccurrences(of: "standalone:", with: "")
                cleaned = AgentDetector.recentTranscriptOutput(forAgent: agentName, maxLines: 6)
                    .joined(separator: "\n")
            }
            await MainActor.run {
                if self.peekingPaneId == paneId {
                    self.peekText = cleaned
                }
            }
        }
    }

    private func endPeek() {
        peekingPaneId = nil
        peekText = ""
        peekTask?.cancel()
        peekTask = nil
    }

    /// Single-key roster shortcuts via `.onKeyPress` on macOS 14+. On older
    /// systems the local key monitor (installed in onAppear) covers them.
    private struct ShortcutKeyPressModifier: ViewModifier {
        var handle: (_ character: Character) -> Bool
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 14.0, *) {
                content.onKeyPress { press in
                    guard let char = press.characters.first, handle(char) else {
                        return .ignored
                    }
                    return .handled
                }
            } else {
                content
            }
        }
    }

    /// Arrow-key / Enter / Esc roster navigation via `.onKeyPress(keys:)` on
    /// macOS 14+. The keys set is the physical arrow/return/escape keys, so it
    /// works regardless of keyboard layout.
    private struct NavigationKeyPressModifier: ViewModifier {
        var handle: (_ keyCode: UInt16) -> Bool
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 14.0, *) {
                content
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        handle(126) ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        handle(125) ? .handled : .ignored
                    }
                    .onKeyPress(.return, phases: .down) { _ in
                        handle(36) ? .handled : .ignored
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        handle(53) ? .handled : .ignored
                    }
            } else {
                content
            }
        }
    }

    // MARK: - Island chrome

    private var spendStrokeColor: Color {
        guard NotchHUDConfig.shared.enableSpendGlow else {
            return .white.opacity(isExpanded ? 0.09 : 0.04)
        }
        let cost = eventManager.usage.costUSD
        let budget = max(NotchHUDConfig.shared.dailyBudgetUSD, 0.5)
        let ratio = cost / budget
        if ratio >= 1.0 {
            return .red
        } else if ratio >= 0.70 {
            return .orange
        } else {
            return .white.opacity(isExpanded ? 0.22 : 0.04)
        }
    }

    private var islandBackground: some View {
        Rectangle()
            .fill(
                isExpanded
                    ? LinearGradient(
                        colors: [Color(hex: "12141D"), Color(hex: "08090F")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    : LinearGradient(
                        colors: [Color.black, Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
            )
            .mask(islandMask)
            .frame(
                width: isExpanded ? islandWidth : (islandWidth + cornerRad * 2),
                height: islandHeight
            )
            .overlay {
                if isExpanded || !isCenteredClosed {
                    RoundedRectangle(cornerRadius: cornerRad, style: .continuous)
                        .strokeBorder(
                            spendStrokeColor,
                            lineWidth: 1
                        )
                        .frame(width: islandWidth, height: islandHeight)
                }
            }
            .opacity(isCenteredClosed && !isExpanded ? 0 : 1)
            .overlay {
                if isExpanded {
                    RoundedRectangle(cornerRadius: cornerRad, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1
                        )
                        .frame(width: islandWidth, height: islandHeight)
                }
            }
    }

    @ViewBuilder
    private var islandMask: some View {
        if isExpanded {
            RoundedRectangle(cornerRadius: cornerRad, style: .continuous)
                .frame(width: islandWidth, height: islandHeight)
        } else {
            Rectangle()
                .fill(.black)
                .frame(width: islandWidth, height: islandHeight)
                .clipShape(.rect(bottomLeadingRadius: cornerRad, bottomTrailingRadius: cornerRad))
                .overlay(alignment: .topTrailing) {
                    cornerCutout(topLeading: true)
                        .offset(x: cornerRad + IslandMetrics.contentSpacing - 0.5, y: -0.5)
                }
                .overlay(alignment: .topLeading) {
                    cornerCutout(topLeading: false)
                        .offset(x: -cornerRad - IslandMetrics.contentSpacing + 0.5, y: -0.5)
                }
        }
    }

    /// Path silhouette rendering the notch-hugging corner cutout wings.
    private func cornerCutout(topLeading: Bool) -> some View {
        let extent = cornerRad + IslandMetrics.contentSpacing
        let shape = Path { path in
            if topLeading {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: cornerRad, y: 0))
                path.addArc(
                    center: CGPoint(x: cornerRad, y: cornerRad), radius: cornerRad,
                    startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
            } else {
                path.move(to: CGPoint(x: extent, y: 0))
                path.addLine(to: CGPoint(x: extent - cornerRad, y: 0))
                path.addArc(
                    center: CGPoint(x: extent - cornerRad, y: cornerRad), radius: cornerRad,
                    startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
            }
            path.closeSubpath()
        }
        return
            shape
            .fill(.black)
            .frame(width: extent, height: extent)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            expandedList
                .transition(contentTransition)
        } else if let notif = activeNotification {
            notchNotificationCard(event: notif)
                .transition(contentTransition)
        } else if let event = eventManager.currentEvent,
            let paneId = IslandMetrics.actionablePaneId(
                paneId: event.paneId, source: event.source),
            IslandMetrics.requiresApproval(event.kind.rawValue)
        {
            approvalPill(event: event, paneId: paneId)
                .transition(contentTransition)
        } else if isCenteredClosed {
            CenteredSplitStripView(
                eventManager: eventManager,
                islandWidth: islandWidth,
                islandHeight: islandHeight
            )
            .transition(contentTransition)
            .onTapGesture { expandTo(true) }
        } else if let event = eventManager.currentEvent {
            ClosedPillView(
                color: event.kind.color,
                label: event.kind.label,
                title: showDetail ? event.title : nil,
                mascotState: currentMascotState,
                islandWidth: islandWidth,
                islandHeight: islandHeight,
                action: {
                    if let paneId = event.paneId { adapter.paneFocus(paneId: paneId) }
                }
            )
            .transition(contentTransition)
            .onChange(of: event.id) { _ in
                showDetail = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.3)) { showDetail = true }
                }
            }
        } else if !eventManager.agents.isEmpty {
            AgentIdleStripView(
                eventManager: eventManager,
                islandWidth: islandWidth,
                islandHeight: islandHeight,
                idleShownCount: idleShownCount
            )
            .transition(contentTransition)
            .onTapGesture { expandTo(true) }
        } else if isExpanded {
            expandedList
                .transition(contentTransition)
        } else {
            emptyBar
                .transition(contentTransition)
        }
    }

    private var emptyBar: some View {
        Rectangle().fill(.clear).frame(width: islandWidth, height: IslandMetrics.pillHeight)
    }

    @ViewBuilder
    private func notchNotificationCard(event: AgentEvent) -> some View {
        let paneId = IslandMetrics.actionablePaneId(
            paneId: event.paneId, source: event.source)
        let agent = mergedRoster.first {
            (event.paneId != nil && $0.paneId == event.paneId)
                || $0.source == event.sourceKey
        }
        if event.kind == .accessRequest || event.kind == .waiting {
            approvalNotificationCard(event: event, paneId: paneId, agent: agent)
        } else {
            compactNotificationCard(event: event, paneId: paneId, agent: agent)
        }
    }

    /// Approval popup with the exact pending request. The command, path, or
    /// question gets three wrapped monospaced lines; source, project, cwd and
    /// the tool hint sit around it. A live pane excerpt fills in when the
    /// event carries no title (multiplexer status events).
    private func approvalNotificationCard(
        event: AgentEvent, paneId: String?, agent: AgentSnapshot?
    ) -> some View {
        let controls = notificationApprovalControls(
            event: event, agent: agent, detail: notificationDetail)
        let resolving = paneId.map { eventManager.isResolving(paneId: $0) } ?? false
        let projectLabel = notificationProjectLabel(event: event, agent: agent)
        let hasTitle = !IslandMetrics.isGenericApprovalText(event.title)
        let canApprove = canApproveNotification(event: event, agent: agent)
        let surface = IslandMetrics.promptSurfaceKind(
            eventKind: event.kind,
            actionable: canApprove,
            choiceCount: controls.choices.count)
        let detail: String = {
            if let title = event.title, hasTitle {
                let cleaned = IslandMetrics.cleanApprovalDetail(title)
                if !cleaned.isEmpty { return cleaned }
            }
            if !notificationDetail.isEmpty {
                let cleaned = IslandMetrics.cleanApprovalDetail(notificationDetail)
                if !cleaned.isEmpty { return cleaned }
            }
            if let message = event.message,
                !IslandMetrics.isGenericApprovalText(message)
            {
                let cleaned = IslandMetrics.cleanApprovalDetail(message)
                if !cleaned.isEmpty { return cleaned }
            }
            return surface == .question ? "Agent has a question" : "Agent requires input"
        }()
        let contextLine: String? = {
            var parts: [String] = []
            if let message = event.message,
                !IslandMetrics.isGenericApprovalText(message)
            {
                let cleaned = IslandMetrics.cleanApprovalDetail(
                    message, maxCharacters: 110)
                if !cleaned.isEmpty, cleaned != detail {
                    parts.append(cleaned)
                }
            }
            if let cwd = agent?.cwd, !cwd.isEmpty {
                let short = (cwd as NSString).abbreviatingWithTildeInPath
                parts.append(
                    short.count <= 68 ? short : "..." + String(short.suffix(65)))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }()
        let choiceSummary = notificationChoiceSummary(controls)
        let fromLivePane = !hasTitle && !notificationDetail.isEmpty

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(
                    systemName: surface == .permission
                        ? "exclamationmark.triangle.fill"
                        : (surface == .question
                            ? "questionmark.circle.fill" : "hourglass")
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: event.kind.color))
                Text(event.sourceKey.capitalized)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                if let projectLabel {
                    Text("· \(projectLabel)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(
                    fromLivePane
                        ? "LIVE PANE"
                        : (surface == .permission
                            ? "NEEDS INPUT"
                            : (surface == .question ? "QUESTION" : "WAITING"))
                )
                .font(.system(size: 8.5, weight: .bold))
                .textCase(.uppercase)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Color(hex: event.kind.color).opacity(0.25), in: Capsule()
                )
                .foregroundColor(Color(hex: event.kind.color))
                .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let paneId {
                    beginReplyFromCard(event: event, paneId: paneId, agent: agent)
                }
            }
            .help("Double-click to reply to this agent")

            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let paneId {
                        beginReplyFromCard(event: event, paneId: paneId, agent: agent)
                    }
                }
                .onTapGesture { withAnimation(morphAnimation) { expandTo(true) } }
                .help("Click to open the request. Double-click to reply.")

            if let contextLine {
                Text(contextLine)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.48))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let choiceSummary, !(surface == .question && controls.isMulti) {
                Text(choiceSummary)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            // Multi-select toggles get their own row so the footer never
            // collides with the options. Submit stays in the footer.
            if surface == .question, controls.isMulti, let paneId {
                notificationMultiOptions(
                    event: event, paneId: paneId, controls: controls,
                    resolving: resolving)
            }

            if IslandMetrics.promptAcceptsFreeText(surface: surface), let paneId {
                HStack(spacing: 6) {
                    TextField("Type an answer…", text: $cardAnswer)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white)
                        .onSubmit { sendCardAnswer(paneId: paneId) }
                    Button {
                        sendCardAnswer(paneId: paneId)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(
                                cardAnswer.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty ? .white.opacity(0.25) : .cyan)
                    }
                    .buttonStyle(.plain)
                    .help("Send this answer to the agent")
                    .disabled(
                        cardAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.07)))
            }

            if let cardFailure {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                    Text(cardFailure)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if cardRetry != nil {
                        Button("Retry") { cardRetry?() }
                            .font(.system(size: 8.5, weight: .bold))
                            .buttonStyle(.plain)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if notificationQueue.count > 1 {
                    queueStepper
                }
                Spacer(minLength: 0)
                if let paneId {
                    switch surface {
                    case .permission:
                        notificationApprovalActions(
                            event: event, paneId: paneId, controls: controls,
                            resolving: resolving)
                    case .question where !controls.isYesNo:
                        notificationApprovalActions(
                            event: event, paneId: paneId, controls: controls,
                            resolving: resolving)
                    default:
                        notificationActionButton(
                            title: "Review", systemName: "doc.text.magnifyingglass",
                            color: Color.white.opacity(0.8),
                            helpText: "Review the full request before deciding",
                            disabled: false
                        ) {
                            withAnimation(morphAnimation) { expandTo(true) }
                        }
                    }
                    TactileRowButton(
                        systemName: "arrow.up.right",
                        color: Color.white.opacity(0.6),
                        helpText: "Focus agent"
                    ) {
                        focusAgentPane(paneId)
                    }
                    .disabled(resolving)
                    .opacity(resolving ? 0.4 : 1)
                    TactileRowButton(
                        systemName: "chevron.down",
                        color: Color.white.opacity(0.6),
                        helpText: "Open control plane for this agent"
                    ) {
                        withAnimation(morphAnimation) { expandTo(true) }
                    }
                    notificationDismissButton(event.id, paneId: paneId)
                } else {
                    notificationDismissButton(event.id, paneId: nil)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(
            width: IslandMetrics.notificationWidth,
            height: IslandMetrics.approvalNotificationHeight
                + ((surface == .question && controls.isMulti)
                    ? IslandMetrics.multiOptionsExtraHeight(
                        optionCount: controls.choices.count) : 0)
                + (IslandMetrics.promptAcceptsFreeText(surface: surface) ? 26 : 0)
                + (cardFailure == nil ? 0 : 30)
        )
        .contentShape(Rectangle())
        .modifier(ShakeEffect(animatableData: reduceMotion ? 0 : shakeTrigger))
        .commitFlash(
            token: commitToken,
            cornerRadius: IslandMetrics.notificationCornerRadius,
            reduceMotion: reduceMotion)
    }

    /// Compact completion/failure notice. No approval controls, no extra
    /// height.
    private func compactNotificationCard(
        event: AgentEvent, paneId: String?, agent: AgentSnapshot?
    ) -> some View {
        let isCompleted = event.kind == .completed
        let isFailed = event.kind == .failed
        let projectLabel = notificationProjectLabel(event: event, agent: agent)
        let prompt =
            (event.title ?? event.message).map {
                IslandMetrics.cleanHUDText($0, maxCharacters: 96)
            }.flatMap { $0.isEmpty ? nil : $0 }
            ?? (isCompleted ? "Task completed successfully" : "Agent requires input")

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(hex: event.kind.color).opacity(0.18))
                    .frame(width: 36, height: 36)
                Circle()
                    .strokeBorder(Color(hex: event.kind.color).opacity(0.4), lineWidth: 1.5)
                    .frame(width: 36, height: 36)
                Image(
                    systemName: isCompleted
                        ? "checkmark.circle.fill"
                        : (isFailed ? "xmark.octagon.fill" : "bell.fill")
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color(hex: event.kind.color))
            }
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.sourceKey.capitalized)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    if let projectLabel {
                        Text("· \(projectLabel)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Text(event.kind.label)
                        .font(.system(size: 9, weight: .bold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: event.kind.color).opacity(0.25), in: Capsule())
                        .foregroundColor(Color(hex: event.kind.color))
                        .fixedSize()
                }

                Text(prompt)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if isCompleted {
                    TactileRowButton(
                        systemName: "safari",
                        title: "View Diff",
                        color: Color.blue.opacity(0.85),
                        helpText: "Open session viewer in browser"
                    ) {
                        let slug =
                            agent?.cwd.map {
                                URL(fileURLWithPath: $0).lastPathComponent
                            } ?? event.sourceKey
                        RichSessionViewer.openInBrowser(
                            agentName: event.sourceKey,
                            projectSlug: slug,
                            cwd: agent?.cwd,
                            isWorking: false,
                            sessionPath: agent?.sessionPath
                        )
                    }
                } else if isFailed, let paneId {
                    TactileRowButton(
                        systemName: "arrow.up.right",
                        title: "Focus",
                        color: Color.orange.opacity(0.85),
                        helpText: "Focus agent"
                    ) {
                        focusAgentPane(paneId)
                    }
                }
                notificationDismissButton(event.id, paneId: paneId)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(
            width: IslandMetrics.notificationWidth,
            height: IslandMetrics.notificationHeight
        )
        .contentShape(Rectangle())
    }

    private func notificationProjectLabel(
        event: AgentEvent, agent: AgentSnapshot?
    ) -> String? {
        let project =
            agent?.projectContext?.project
            ?? agent?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard let project, !project.isEmpty,
            project.lowercased() != event.sourceKey.lowercased()
        else { return nil }
        return project
    }

    private func notificationDismissButton(_ id: UUID, paneId: String?) -> some View {
        TactileRowButton(
            systemName: "xmark",
            color: Color.white.opacity(0.5),
            helpText: paneId == nil
                ? "Dismiss notification"
                : "Acknowledge until the request changes"
        ) {
            if let paneId {
                eventManager.acknowledgeApproval(paneId: paneId)
            }
            dismissNotification(id)
        }
    }

    /// Queue stepper: cycles the visible card without resolving anything.
    /// New arrivals never silently replace the card being read.
    private var queueStepper: some View {
        HStack(spacing: 2) {
            Button {
                cycleQueueIndex(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Previous notification")
            .accessibilityLabel("Previous notification")
            Text("\(queueIndex + 1) of \(notificationQueue.count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.55))
                .accessibilityLabel(
                    "Notification \(queueIndex + 1) of \(notificationQueue.count)")
            Button {
                cycleQueueIndex(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Next notification")
            .accessibilityLabel("Next notification")
        }
    }

    private func dismissNotification(_ id: UUID) {
        commitTask?.cancel()
        commitTask = nil
        let topBefore = activeNotification?.id
        withAnimation(morphAnimation) {
            notificationQueue = IslandMetrics.notificationQueueRemove(
                notificationQueue, id: id)
            queueIndex = IslandMetrics.notificationQueueClampIndex(
                queueIndex, count: notificationQueue.count)
        }
        if activeNotification?.id != topBefore {
            cancelNotificationDetail()
        }
    }

    /// Step the visible card through the queue. Detail follows the new top.
    private func cycleQueueIndex(by delta: Int) {
        guard notificationQueue.count > 1 else { return }
        let count = notificationQueue.count
        let next = (queueIndex + delta + count) % count
        withAnimation(morphAnimation) {
            queueIndex = next
        }
        cancelNotificationDetail()
        if let top = activeNotification,
            top.kind == .accessRequest || top.kind == .waiting
        {
            loadNotificationDetail(for: top)
        }
    }

    /// Fetch a live pane excerpt when the approval event has no concrete
    /// title. Multiplexer status events often say only "blocked"; the pane
    /// tail is where the actual command or question lives.
    private func loadNotificationDetail(for event: AgentEvent) {
        notificationDetailTask?.cancel()
        notificationDetail = ""
        guard event.kind == .accessRequest || event.kind == .waiting,
            IslandMetrics.isGenericApprovalText(event.title)
        else { return }

        let expectedID = event.id
        let paneId = event.paneId
        let source = event.sourceKey
        let agent = mergedRoster.first {
            (event.paneId != nil && $0.paneId == event.paneId)
                || $0.source == event.sourceKey
        }
        let sessionPath = agent?.sessionPath
        let cwd = agent?.cwd

        notificationDetailTask = Task.detached { [adapter] in
            var raw = ""
            if let paneId, !paneId.isEmpty,
                !paneId.hasPrefix(OpenCodeActionWriter.panePrefix),
                !paneId.hasPrefix("standalone:")
            {
                raw = await adapter.captureTail(paneId: paneId, lines: 18)
            }
            var excerpt = IslandMetrics.approvalExcerpt(from: raw, maxLines: 4)
            if excerpt.isEmpty {
                let transcript = AgentDetector.recentTranscriptOutput(
                    forAgent: source, sessionPath: sessionPath, cwd: cwd,
                    maxLines: 18)
                excerpt = transcript.suffix(4).joined(separator: "\n")
            }
            // Pane tails usually hold whatever scrolled by, not the prompt.
            // Without a prompt signal the card falls back to Review instead
            // of showing random transcript text as the request.
            if !IslandMetrics.looksLikePrompt(excerpt) {
                excerpt = ""
            }
            await MainActor.run {
                guard self.activeNotification?.id == expectedID else { return }
                self.notificationDetail = excerpt
            }
        }
    }

    private func cancelNotificationDetail() {
        notificationDetailTask?.cancel()
        notificationDetailTask = nil
        notificationDetail = ""
    }

    /// Approval shape for the popup. Prefers the merged roster row (which
    /// carries the decoded variance/choices) and falls back to parsing a
    /// numbered prompt out of the event title.
    private func notificationApprovalControls(
        event: AgentEvent, agent: AgentSnapshot?, detail: String
    ) -> IslandMetrics.ApprovalControls {
        let base =
            agent?.approval
            ?? IslandMetrics.ApprovalControls.make(
                variance: event.variance, choices: event.choices)
        guard base.isYesNo else { return base }
        let text = [event.title, event.message, detail]
            .compactMap { $0 }
            .joined(separator: "\n")
        let extracted = ChoiceExtractor.extractChoices(from: text)
        guard extracted.count >= 2 else { return base }
        return IslandMetrics.ApprovalControls.make(
            variance: .choices, choices: extracted.map(\.label))
    }

    /// A notification may approve only when the event is a real permission
    /// request with concrete detail. Generic blocked heartbeats get Review.
    private func canApproveNotification(
        event: AgentEvent, agent: AgentSnapshot?
    ) -> Bool {
        guard event.kind == .accessRequest else { return false }
        if let agent, !agent.approvalActionable { return false }
        if let agent, agent.approval.isYesNo, agent.approvalActionable { return true }
        let title = event.title ?? event.message
        return !IslandMetrics.isGenericApprovalText(title)
    }

    private func notificationChoiceSummary(
        _ controls: IslandMetrics.ApprovalControls
    ) -> String? {
        guard !controls.isYesNo, !controls.choices.isEmpty else { return nil }
        let cap = IslandMetrics.ApprovalControls.maxDisplayedOptions
        let shown = controls.choices.prefix(cap).enumerated().map {
            "\($0.offset + 1). \($0.element)"
        }
        var summary = shown.joined(separator: "  ")
        if controls.choices.count > cap {
            summary += "  +\(controls.choices.count - cap)"
        }
        return summary
    }

    @ViewBuilder
    private func notificationApprovalActions(
        event: AgentEvent, paneId: String, controls: IslandMetrics.ApprovalControls,
        resolving: Bool
    ) -> some View {
        if controls.isMulti {
            notificationMultiActions(
                event: event, paneId: paneId, controls: controls, resolving: resolving)
        } else if controls.isYesNo {
            notificationActionButton(
                title: "Approve", systemName: "checkmark", color: .green,
                helpText: "Approve request (Y)", disabled: resolving
            ) {
                performCardAction(
                    paneId: paneId, prompt: event.title ?? event.message ?? "",
                    onDelivered: { dismissNotification(event.id) }
                ) {
                    eventManager.approveResult(paneId: paneId)
                }
            }
            notificationActionButton(
                title: "Deny", systemName: "xmark", color: .red,
                helpText: "Deny request (N)", disabled: resolving
            ) {
                performCardAction(
                    paneId: paneId, prompt: event.title ?? event.message ?? "",
                    onDelivered: { dismissNotification(event.id) }
                ) {
                    eventManager.denyResult(paneId: paneId)
                }
            }
        } else {
            notificationChoiceActions(
                event: event, paneId: paneId, controls: controls, resolving: resolving)
        }
    }

    @ViewBuilder
    private func notificationChoiceActions(
        event: AgentEvent, paneId: String, controls: IslandMetrics.ApprovalControls,
        resolving: Bool
    ) -> some View {
        let cap = IslandMetrics.ApprovalControls.maxDisplayedOptions
        let options = Array(controls.choices.prefix(cap))
        if options.isEmpty {
            notificationActionButton(
                title: "Approve", systemName: "checkmark", color: .green,
                helpText: "Approve request (Y)", disabled: resolving
            ) {
                performCardAction(
                    paneId: paneId, prompt: event.title ?? event.message ?? "",
                    onDelivered: { dismissNotification(event.id) }
                ) {
                    eventManager.approveResult(paneId: paneId)
                }
            }
        } else {
            ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                approvalActionButton(
                    label: Text("\(index + 1)"),
                    color: .white,
                    help: label,
                    disabled: resolving,
                    accessibilityLabel: label
                ) {
                    performCardAction(
                        paneId: paneId, prompt: event.title ?? event.message ?? "",
                        onDelivered: { dismissNotification(event.id) }
                    ) {
                        eventManager.approveChoiceResult(
                            paneId: paneId, choice: index + 1)
                    }
                }
            }
            if controls.choices.count > cap {
                approvalActionButton(
                    label: Text("+\(controls.choices.count - cap)"),
                    color: .white.opacity(0.6),
                    help: "More options — open the inbox to answer",
                    accessibilityLabel: "More options, open inbox"
                ) {
                    withAnimation(morphAnimation) { expandTo(true) }
                }
            }
        }
    }

    @ViewBuilder
    private func notificationMultiActions(
        event: AgentEvent, paneId: String, controls: IslandMetrics.ApprovalControls,
        resolving: Bool
    ) -> some View {
        // Toggles live on their own row above the footer
        // (notificationMultiOptions). Only Submit stays in the footer so the
        // stepper and focus buttons never collide with the options.
        notificationMultiSubmit(
            event: event, paneId: paneId, resolving: resolving)
    }

    /// Labeled multi-select toggle grid, rendered above the card footer.
    /// Every option is a tappable chip with its number and label — never a
    /// bare number pointing at a text line. Two columns, capped at six with
    /// a `+N` inbox overflow, matching single-choice popups.
    @ViewBuilder
    private func notificationMultiOptions(
        event: AgentEvent, paneId: String, controls: IslandMetrics.ApprovalControls,
        resolving: Bool
    ) -> some View {
        let cap = IslandMetrics.ApprovalControls.maxDisplayedOptions
        let options = Array(controls.choices.prefix(cap))
        let selection = queueSelections[paneId] ?? []
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading, spacing: 6
        ) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                let number = IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                let selected = selection.contains(number)
                Button {
                    queueSelections[paneId] = IslandMetrics.ApprovalControls.toggling(
                        selection, index: index)
                } label: {
                    HStack(spacing: 5) {
                        Image(
                            systemName: selected
                                ? "checkmark.square.fill" : "square"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(
                            selected ? .green : .white.opacity(0.5))
                        Text("\(number) · \(label)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: IslandMetrics.multiOptionRowHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                selected
                                    ? Color.green.opacity(0.18)
                                    : Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .disabled(resolving)
                .help(label)
                .accessibilityLabel(
                    "Option \(number): \(label)\(selected ? ", selected" : "")")
            }
        }
        if controls.choices.count > cap {
            Button {
                withAnimation(morphAnimation) { expandTo(true) }
            } label: {
                Text("+\(controls.choices.count - cap) more — open inbox")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("More options — open the inbox to answer")
            .accessibilityLabel("More options, open inbox")
        }
    }

    /// Multi-select Submit for the card footer. Disabled until at least one
    /// option is picked; the picked numbers read back in the help text.
    @ViewBuilder
    private func notificationMultiSubmit(
        event: AgentEvent, paneId: String, resolving: Bool
    ) -> some View {
        let selection = queueSelections[paneId] ?? []
        let numbers = IslandMetrics.ApprovalControls.selectionNumbers(selection)
        let canSubmit = IslandMetrics.ApprovalControls.canSubmitMulti(selection: selection)
        approvalActionButton(
            systemName: "checkmark.circle.fill",
            color: canSubmit ? .green : .white.opacity(0.3),
            help: canSubmit
                ? "Submit selections (\(numbers.map(String.init).joined(separator: ", ")))"
                : "Pick at least one option first",
            disabled: resolving || !canSubmit
        ) {
            performCardAction(
                paneId: paneId, prompt: event.title ?? event.message ?? "",
                onDelivered: {
                    queueSelections.removeValue(forKey: paneId)
                    dismissNotification(event.id)
                }
            ) {
                eventManager.approveMultiResult(paneId: paneId, selections: numbers)
            }
        }
    }

    private func notificationActionButton(
        title: String, systemName: String, color: Color, helpText: String,
        disabled: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        TactileRowButton(
            systemName: systemName, title: title, color: color, helpText: helpText,
            action: action
        )
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func approvalPill(event: AgentEvent, paneId: String) -> some View {
        let agent = mergedRoster.first(where: {
            ($0.paneId != nil && $0.paneId == paneId)
                || $0.source == event.sourceKey
        })
        let effectiveVariance = agent?.approval.variance ?? event.effectiveVariance
        let effectiveChoices = agent?.approval.choices ?? event.choices ?? []
        let canApprove = canApprovePill(event: event, paneId: paneId)
        let surface = IslandMetrics.promptSurfaceKind(
            eventKind: event.kind,
            actionable: canApprove,
            choiceCount: effectiveChoices.count)
        let variance = effectiveVariance
        let choices = effectiveChoices
        let pill = HStack(spacing: 8) {
            Circle().fill(Color(hex: event.kind.color)).frame(width: 7, height: 7)
            Text(
                surface == .question
                    ? "Question"
                    : (surface == .waiting ? "Waiting" : event.kind.label)
            )
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            // Item 5: variance badge — distinguish yes/no from choice/multi.
            if variance != .yesNo {
                Text(variance.label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .frame(height: 14)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            if showDetail, let title = event.title, !title.isEmpty {
                let clean = IslandMetrics.cleanHUDText(title, maxCharacters: 40)
                if !clean.isEmpty {
                    Text("·").foregroundStyle(.secondary)
                    Text(clean)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            switch surface {
            case .permission:
                approvalActions(variance: variance, choices: choices, paneId: paneId)
            case .question where variance != .yesNo:
                approvalActions(variance: variance, choices: choices, paneId: paneId)
            default:
                approvalActionButton(
                    systemName: "doc.text.magnifyingglass", color: .white.opacity(0.8),
                    help: "Review the full request before deciding"
                ) {
                    withAnimation(morphAnimation) { expandTo(true) }
                }
            }
            approvalActionButton(
                systemName: "arrow.up.right", color: .white.opacity(0.6), help: "Focus pane"
            ) {
                focusAgentPane(paneId)
            }
        }
        .frame(width: islandWidth, height: IslandMetrics.pillHeight)
        .contentShape(Rectangle())
        return pill
    }

    private func canApprovePill(event: AgentEvent, paneId: String) -> Bool {
        guard event.kind == .accessRequest else { return false }
        if let agent = mergedRoster.first(where: {
            ($0.paneId != nil && $0.paneId == paneId)
                || $0.source == event.sourceKey
        }) {
            return agent.approvalActionable
        }
        let title = event.title ?? event.message
        return !IslandMetrics.isGenericApprovalText(title)
    }

    @ViewBuilder
    private func approvalActions(
        variance: ApprovalVariance, choices: [String], paneId: String
    ) -> some View {
        let resolving = eventManager.isResolving(paneId: paneId)
        switch variance {
        case .yesNo:
            approvalActionButton(
                systemName: "checkmark.circle.fill", color: .green, help: "Approve",
                disabled: resolving
            ) {
                eventManager.approve(paneId: paneId)
            }
            approvalActionButton(
                systemName: "xmark.circle.fill", color: .red, help: "Deny",
                disabled: resolving
            ) {
                eventManager.deny(paneId: paneId)
            }
        case .choices:
            let options: [ChoiceOption] = {
                if !choices.isEmpty {
                    return choices.enumerated().map {
                        ChoiceOption(id: $0.offset + 1, label: $0.element, fullText: $0.element)
                    }
                }
                if let title = eventManager.currentEvent?.title {
                    let extracted = ChoiceExtractor.extractChoices(from: title)
                    if !extracted.isEmpty { return extracted }
                }
                return []
            }()

            if !options.isEmpty {
                // Numbered buttons for the first four options; a "Choice ▾"
                // menu only when there are more than four (avoids duplicate
                // controls for the common 2–4 option case).
                if options.count > 4 {
                    Menu {
                        ForEach(options) { opt in
                            Button("\(opt.id). \(opt.label)") {
                                eventManager.approveChoice(paneId: paneId, choice: opt.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("Choice ▾")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.cyan, in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(resolving)
                    .help("Pick a choice answer for this agent")
                }
                ForEach(options.prefix(4)) { opt in
                    approvalActionButton(
                        label: Text("\(opt.id)"),
                        color: .white,
                        help: opt.label,
                        disabled: resolving
                    ) {
                        eventManager.approveChoice(paneId: paneId, choice: opt.id)
                    }
                }
            } else {
                approvalActionButton(
                    systemName: "checkmark.circle.fill", color: .green, help: "Approve",
                    disabled: resolving
                ) {
                    eventManager.approve(paneId: paneId)
                }
            }
        case .multi:
            ForEach(0..<choices.count, id: \.self) { index in
                approvalActionButton(
                    label: Text("\(index + 1)"),
                    color: queueSelections[paneId]?.contains(index + 1) == true
                        ? .green : .white.opacity(0.6),
                    help: choices[index]
                ) {
                    queueSelections[paneId] = IslandMetrics.ApprovalControls.toggling(
                        queueSelections[paneId] ?? [], index: index)
                }
            }
            approvalActionButton(
                systemName: "checkmark.circle.fill", color: .green, help: "Submit",
                disabled: resolving
            ) {
                let numbers = IslandMetrics.ApprovalControls.selectionNumbers(
                    queueSelections[paneId] ?? [])
                eventManager.approveMulti(paneId: paneId, selections: numbers)
                queueSelections.removeValue(forKey: paneId)
            }
        }
    }

    /// Affordance that opens the full-log + diff preview overlay (plan 016

    private var isQuotaLow: Bool {
        let config = NotchHUDConfig.shared
        let cost = eventManager.usage.costUSD
        let budget = max(config.dailyBudgetUSD, 0.5)
        let isBudgetExceeded = (cost / budget) >= 1.0
        let tpm = eventManager.usageRate.tokensPerMinute ?? 0
        let isHighBurn = tpm >= config.highBurnThresholdTPM
        return isBudgetExceeded || isHighBurn
    }

    private var currentMascotState: MascotState {
        MascotEvaluator.evaluate(
            agents: mergedRoster,
            quotaLow: isQuotaLow,
            recentCompletion: eventManager.currentEvent?.kind == .completed
        )
    }

    private var expandedList: some View {
        let counts = IslandMetrics.agentCounts(
            kinds: visibleAgents.map(\.kind))
        return VStack(spacing: 0) {
            NotchHeaderBarView(
                eventManager: eventManager,
                counts: counts,
                mascotState: currentMascotState,
                selectedTab: $selectedTab,
                historyMode: $historyMode,
                showThoughtBubble: $showThoughtBubble,
                panelPinned: panelPinned,
                onTogglePin: {
                    if NotchHUDConfig.shared.panelPinned {
                        NotchHUDConfig.shared.panelPinned = IslandMetrics.pinAfterCollapse(
                            reason: .explicitUnpin,
                            wasPinned: true,
                            persistAcrossCollapse: true)
                    } else {
                        NotchHUDConfig.shared.panelPinned = true
                    }
                },
                onOpenSettings: {
                    AppDelegate.showSettings(route: .agents)
                },
                onExpandTo: { expandTo($0) }
            )

            if let digest = AwayDigestStore.shared.currentDigest {
                AwayDigestCardView(digest: digest) {
                    AwayDigestStore.shared.dismiss()
                }
            }

            if NotchHUDConfig.shared.showShelfTab {
                NotchTabBarView(selectedTab: $selectedTab, shelfDropGlow: shelfDropGlow)
            }

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

            if showTasks {
                TaskWidgetView()
            } else if showAttention {
                NotchAttentionView(
                    mergedRoster: mergedRoster,
                    adapter: adapter,
                    hoveredRow: $hoveredRow,
                    composingPaneId: $composingPaneId,
                    promptText: $promptText,
                    promptFocused: $promptFocused,
                    queueSelections: $queueSelections,
                    reduceMotion: reduceMotion,
                    now: now,
                    onFocus: { focusAgent($0) },
                    onSubmitPrompt: { submitPrompt() },
                    onCancelComposing: { cancelComposing() },
                    onBeginComposing: { beginComposing($0) }
                )
            } else if showHistory {
                historyContent
            } else if showShelf {
                NotchShelfView(
                    shelfStore: shelfStore,
                    clipboardItems: clipboardItems,
                    shelfDropGlow: shelfDropGlow
                )
            } else if showMedia {
                NotchMediaView()
            } else {
                NotchRosterView(
                    visibleAgents: visibleAgents,
                    mergedRoster: mergedRoster,
                    recentCompletions: eventManager.recentCompletions,
                    rosterScrollHeight: rosterScrollHeight,
                    focusedRow: focusedRow,
                    adapter: adapter,
                    hoveredRow: $hoveredRow,
                    composingPaneId: $composingPaneId,
                    promptText: $promptText,
                    promptFocused: $promptFocused,
                    queueSelections: $queueSelections,
                    reduceMotion: reduceMotion,
                    now: now,
                    onFocus: { focusAgent($0) },
                    onSubmitPrompt: { submitPrompt() },
                    onCancelComposing: { cancelComposing() },
                    onBeginComposing: { beginComposing($0) }
                )
            }
        }
        .frame(width: islandWidth, height: contentHeight, alignment: .top)
    }

    /// Calculates scroll viewport height for the agent roster.
    private var rosterScrollHeight: CGFloat {
        let chrome =
            IslandMetrics.headerHeight
            + (NotchHUDConfig.shared.showShelfTab
                ? IslandMetrics.shelfTabBarHeight + IslandMetrics.dividerHeight : 0)
        let available = max(
            contentHeight - chrome - IslandMetrics.contentSpacing,
            0)
        // Reserve room for the structured empty state when there are no
        // agents, so it isn't clipped to a sliver of the viewport.
        if visibleAgents.isEmpty {
            return max(available, 92)
        }
        let natural = IslandMetrics.rosterHeight(rosterMetrics)
        return max(min(max(natural, IslandMetrics.workingRowHeight), max(available, 0)), 0)
    }

    private func cleanHUDText(_ text: String) -> String {
        IslandMetrics.cleanHUDText(text)
    }

    private var historyContent: some View {
        NotchHistoryView(historyMode: $historyMode)
    }

    /// Watch the system pasteboard; new non-empty text lands on the shelf.
    private func pollClipboard(at date: Date) {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let text = pb.string(forType: .string) else { return }
        clipboardItems = ClipboardHistory.merging(
            existing: clipboardItems, newText: text, now: date,
            limit: NotchHUDConfig.shared.clampedShelfLimit)
    }

    private func terminalPeekDrawer(text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let displayLines = Array(lines.suffix(4))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text("❯")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.green.opacity(0.7))
                    Text(String(line))
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    /// Best-effort: reveal the workspace directory in Finder. Falls back to
    /// the home directory when the workspace id is not a path.
    private func openWorkspaceInFinder(_ workspaceId: String) {
        var url: URL?
        if workspaceId.hasPrefix("/") {
            url = URL(fileURLWithPath: workspaceId)
        } else if let cwd = ProcessInfo.processInfo.environment["PWD"] {
            url = URL(fileURLWithPath: cwd)
        }
        let target = url ?? URL(fileURLWithPath: NSHomeDirectory())
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Focus an agent: routes to multiplexer pane when managed, or raises the standalone app/terminal.
    private func focusAgent(_ agent: AgentSnapshot) {
        if let paneId = agent.paneId, !paneId.hasPrefix("standalone:") {
            let kind = PlexerDetection.detect(env: ProcessInfo.processInfo.environment)
            if kind == adapter.kind, kind == .tmux || kind == .zellij {
                focusAgentPane(paneId)
                return
            }
        }
        let clean = StandaloneAgentDispatcher.cleanAgentName(from: agent.paneId ?? agent.source)
        focusStandaloneAgent(clean.isEmpty ? agent.source : clean, cwd: agent.cwd)
    }

    /// Raise the standalone application window (e.g. Antigravity IDE, Cursor) or terminal.
    private func focusStandaloneAgent(_ source: String, cwd: String? = nil) {
        _ = TerminalFocusser.focusStandalone(source: source, cwd: cwd)
    }

    /// Focuses an agent pane via multiplexer routing or terminal app activation.
    private func focusAgentPane(_ paneId: String) {
        if paneId.hasPrefix("standalone:") {
            let stripped = paneId.replacingOccurrences(of: "standalone:", with: "")
            let comps = stripped.split(separator: ":")
            let source = String(comps.first ?? "")
            let agent = eventManager.agents.first {
                ($0.paneId ?? "standalone:\($0.source)") == paneId
            }
            focusStandaloneAgent(source, cwd: agent?.cwd)
            return
        }
        let kind = PlexerDetection.detect(env: ProcessInfo.processInfo.environment)
        guard kind == adapter.kind, kind == .tmux || kind == .zellij else {
            adapter.focusPane(paneId: paneId)
            return
        }
        let target = PaneFocusRouter.resolveForFocus(
            paneId: paneId, kind: kind, tty: nil, pid: nil, panes: [])
        let action = PaneFocusRouter.route(target: target)
        switch action {
        case .none:
            return
        case .terminalOnly:
            _ = TerminalFocusser.focus(
                preferredBundleID: NotchHUDConfig.shared.preferredTerminalBundleID)
        case .muxFocus, .both:
            if let command = PaneFocusRouter.focusCommand(target: target) {
                ProcessRunner.launch(
                    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["env"] + command)
            }
            if action == .both {
                _ = TerminalFocusser.focus(
                    preferredBundleID: NotchHUDConfig.shared.preferredTerminalBundleID)
            }
        }
    }

    // MARK: - Behavior

    private func handleAppear() {
        if AppDelegate.pendingWelcome {
            AppDelegate.pendingWelcome = false
            showWelcome = true
        }
        // F11 1b: a latched pin re-expands across relaunch, but only while
        // agents exist and the visibility policy actually shows the island —
        // a pinned panel must not force-show while hidden at startup/snoozed.
        let config = NotchHUDConfig.shared
        if config.panelPinned
            && IslandMetrics.pinShouldExpand(hasAgents: !eventManager.agents.isEmpty)
            && IslandMetrics.VisibilityPolicy.shouldShow(
                islandEnabled: config.islandEnabled,
                snoozed: config.isSnoozed,
                hideAtStartup: config.hideAtStartup,
                didShowOnce: AppDelegate.didShowOnce,
                hasWork: true,
                showWhenIdle: config.showIslandWhenIdle,
                forced: AppDelegate.isForcedVisible)
        {
            expandTo(true)
        }
        updateIslandVisibility()
        withAnimation(.easeInOut(duration: 0.25)) { opacity = 1 }
        if eventManager.currentEvent != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) { showDetail = true }
            }
        }
    }

    private func expandTo(_ expanded: Bool) {
        if expanded {
            DesktopHUDController.shared.hide()
        }
        withAnimation(morphAnimation) {
            isExpanded = expanded
        }
    }

    /// A file drag has entered the island window: expand and open the shelf
    /// tab so the drop target is visible and armed. Mirrors NotchDrop's
    /// drop-on-notch behavior.
    private func handleFileDragEntered() {
        NSLog("bantay-drop: handleFileDragEntered")
        selectedTab = .shelf
        expandTo(true)
    }

    /// Files were dropped onto the notch: land them on the shelf.
    private func handleFilesDropped(_ urls: [URL]) {
        NSLog("bantay-drop: handleFilesDropped count=%d", urls.count)
        // The ShelfStore owns persistence, copy-to-storage, and retention.
        ShelfStore.shared.add(urls: urls)
        // Show the shelf so the landed files are immediately visible.
        selectedTab = .shelf
        expandTo(true)
        // Brief glow so the drop "lands" with feedback.
        withAnimation(.easeOut(duration: 0.4)) { shelfDropGlow = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.6)) { shelfDropGlow = false }
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        isHovered = hovering
        if hovering {
            guard
                IslandMetrics.shouldExpandOnHover(
                    hovering: hovering, isExpanded: isExpanded,
                    hasPopup: hasActiveNotification)
            else { return }
            hoverTask = Task { @MainActor in
                let delay = NotchHUDConfig.shared.hoverDelaySeconds
                if delay > 0.01 {
                    try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                }
                guard !Task.isCancelled, isHovered, !hasActiveNotification else { return }
                expandTo(true)
            }
        } else if IslandMetrics.shouldCollapseOnHoverExit(
            isExpanded: isExpanded, isComposing: composingPaneId != nil,
            isPinned: NotchHUDConfig.shared.panelPinned)
        {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(
                    for: .milliseconds(Int(IslandMetrics.hoverExitGrace * 1000)))
                guard !Task.isCancelled, !isHovered,
                    !NotchHUDConfig.shared.panelPinned
                else { return }
                expandTo(false)
            }
        }
    }

    private func handleEventChange() {
        eventManager.setActive(eventManager.currentEvent != nil)
        updateIslandVisibility()
        showDetail = false
        if let event = eventManager.currentEvent {
            if event.kind == .accessRequest || event.kind == .waiting
                || event.kind == .completed || event.kind == .failed
            {
                withAnimation(morphAnimation) {
                    notificationQueue = IslandMetrics.notificationQueueInsert(
                        notificationQueue, event: event)
                    queueIndex = 0
                }
                // Detail belongs to the visible top card: reload it whenever
                // the top is an approval, matching the old per-event refresh.
                if let top = activeNotification,
                    top.kind == .accessRequest || top.kind == .waiting
                {
                    loadNotificationDetail(for: top)
                } else {
                    cancelNotificationDetail()
                }
                notificationDismissTask?.cancel()
                if event.kind == .completed || event.kind == .failed {
                    notificationDismissTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        withAnimation(morphAnimation) {
                            dismissNotification(event.id)
                        }
                    }
                }
            } else {
                let visibleKinds = Set(notificationQueue.map(\.kind))
                let hasApprovalCard =
                    visibleKinds.contains(.accessRequest)
                    || visibleKinds.contains(.waiting)
                if !hasApprovalCard {
                    withAnimation(morphAnimation) {
                        notificationQueue = []
                        queueIndex = 0
                    }
                    cancelNotificationDetail()
                }
            }

            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.15)) { pulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 0.25)) { pulse = false }
                }
            }
            if event.playSound && eventManager.shouldPlaySound(for: event) {
                playSound(for: event)
            }
            // Dispatch notification if approval arrives while the island is hidden or snoozed.
            let config = NotchHUDConfig.shared
            let islandVisible = IslandMetrics.VisibilityPolicy.shouldShow(
                islandEnabled: config.islandEnabled,
                snoozed: config.isSnoozed,
                hideAtStartup: config.hideAtStartup,
                didShowOnce: AppDelegate.didShowOnce,
                hasWork: eventManager.currentEvent != nil || !eventManager.agents.isEmpty,
                showWhenIdle: config.showIslandWhenIdle,
                forced: AppDelegate.isForcedVisible)
            let agent = eventManager.agents.first {
                $0.paneId == event.paneId || $0.source == event.sourceKey
            }
            if IslandMetrics.shouldPostNotification(
                islandVisible: islandVisible,
                notifyWhenHidden: config.notifyWhenHidden,
                displayLocked: eventManager.displayLocked,
                kind: event.kind)
            {
                ApprovalNotificationController.shared.postApproval(
                    source: event.sourceKey,
                    paneId: event.paneId,
                    title: event.title ?? event.message,
                    choices: event.choices,
                    cwd: agent?.cwd,
                    sessionPath: agent?.sessionPath,
                    isMulti: agent?.approval.isMulti ?? (event.variance == .multi))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) { showDetail = true }
            }
        } else {
            // No current event: prune queued approvals whose pane is no
            // longer blocked, so answered prompts vanish while other panes'
            // cards stay. Transient notices clear with the event stream.
            let blocked = eventManager.agents.filter {
                $0.kind == .accessRequest || $0.kind == .waiting
            }
            func stillBlocked(_ item: AgentEvent) -> Bool {
                blocked.contains {
                    (item.paneId != nil && $0.paneId == item.paneId)
                        || $0.source == item.sourceKey
                }
            }
            let topBefore = activeNotification?.id
            withAnimation(morphAnimation) {
                notificationQueue = notificationQueue.filter { item in
                    switch item.kind {
                    case .accessRequest, .waiting:
                        return stillBlocked(item)
                    default:
                        return false
                    }
                }
                queueIndex = IslandMetrics.notificationQueueClampIndex(
                    queueIndex, count: notificationQueue.count)
            }
            if activeNotification?.id != topBefore {
                if let top = activeNotification,
                    top.kind == .accessRequest || top.kind == .waiting
                {
                    loadNotificationDetail(for: top)
                } else {
                    cancelNotificationDetail()
                }
            }
        }
    }

    private func updateIslandVisibility() {
        let config = NotchHUDConfig.shared
        let hasWork = eventManager.currentEvent != nil || !eventManager.agents.isEmpty
        let shouldShow = IslandMetrics.VisibilityPolicy.shouldShow(
            islandEnabled: config.islandEnabled,
            snoozed: config.isSnoozed,
            hideAtStartup: config.hideAtStartup,
            didShowOnce: AppDelegate.didShowOnce,
            hasWork: hasWork,
            showWhenIdle: config.showIslandWhenIdle,
            forced: AppDelegate.isForcedVisible)
        let visible = AppDelegate.window?.isVisible ?? false
        if shouldShow != visible {
            AppDelegate.dbg(
                "visibility: \(shouldShow ? "SHOW" : "HIDE") enabled=\(config.islandEnabled) snoozed=\(config.isSnoozed) hasWork=\(hasWork) idleShow=\(config.showIslandWhenIdle) forced=\(AppDelegate.isForcedVisible) cur=\(eventManager.currentEvent?.kind.rawValue ?? "nil") agents=\(eventManager.agents.count)"
            )
        }
        if shouldShow {
            AppDelegate.showAtNotch()
        } else {
            AppDelegate.hide()
        }
    }

    private func handleAgentsChange() {
        updateIslandVisibility()
        // Prune multi-select state for panes that are no longer blocked so a
        // new prompt never renders with stale pre-selected options.
        let blocked = Set(
            eventManager.agents
                .filter { $0.kind == .accessRequest || $0.kind == .waiting }
                .compactMap { $0.paneId ?? $0.source })
        let stale = queueSelections.keys.filter { !blocked.contains($0) }
        for pane in stale { queueSelections.removeValue(forKey: pane) }
        if IslandMetrics.shouldCollapse(
            isExpanded: isExpanded, hasAgents: !eventManager.agents.isEmpty)
        {
            // Zero agents is a pin-clearing collapse (nothing left to pin).
            let config = NotchHUDConfig.shared
            config.panelPinned = IslandMetrics.pinAfterCollapse(
                reason: .agentsEmpty, wasPinned: config.panelPinned,
                persistAcrossCollapse: true)
            expandTo(false)
        }
        if let composingPaneId,
            !eventManager.agents.contains(where: {
                ($0.paneId ?? "standalone:\($0.source)") == composingPaneId
            })
        {
            cancelComposing()
        }
    }

    /// Double-click on a closed card: open the inbox with the reply field
    /// already focused for that agent. Works for approvals, waiting states,
    /// and questions alike - replying is not limited to questions.
    private func beginReplyFromCard(
        event: AgentEvent, paneId: String, agent: AgentSnapshot?
    ) {
        let target =
            agent
            ?? mergedRoster.first {
                ($0.paneId != nil && $0.paneId == paneId)
                    || $0.source == event.sourceKey
            }
        if let target {
            beginComposing(target)
        } else {
            composingPaneId = paneId
            AppDelegate.composingPaneId = paneId
            promptText = ""
            promptFocused = true
        }
        withAnimation(morphAnimation) { expandTo(true) }
    }

    private func beginComposing(_ agent: AgentSnapshot) {
        let paneId = agent.paneId ?? "standalone:\(agent.source)"
        composingPaneId = paneId
        AppDelegate.composingPaneId = paneId
        promptText = ""
        DispatchQueue.main.async { promptFocused = true }
    }

    // MARK: - Closed-card actions

    /// Runs a card action and surfaces its transport result. A failure keeps
    /// the card open, names the reason, and offers Retry.
    private func performCardAction(
        paneId: String, prompt: String,
        onDelivered: (() -> Void)? = nil,
        action: @escaping () -> AgentEventManager.ActionResult
    ) {
        // A delivered action holds the card for one commit beat. Ignore input
        // during that window so a double-click cannot deliver twice.
        guard commitTask == nil else { return }
        let config = NotchHUDConfig.shared
        let needsConfirm =
            config.confirmRiskyPrompts
            && IslandMetrics.requiresSecondaryConfirm(
                text: prompt, patterns: config.riskyPromptPatterns)
        if needsConfirm && !confirmArmed {
            confirmArmed = true
            confirmTask?.cancel()
            confirmTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                confirmArmed = false
            }
            return
        }
        confirmTask?.cancel()
        confirmArmed = false
        let result = action()
        switch result {
        case .delivered:
            cardFailure = nil
            cardRetry = nil
            commitDelivered(onDelivered)
        case .failed(let failure):
            cardFailure = failure.message
            cardRetry = { [self] in
                performCardAction(
                    paneId: paneId, prompt: prompt, onDelivered: onDelivered,
                    action: action)
            }
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.28)) { shakeTrigger += 1 }
        }
    }

    /// Hold the card for one short commit beat so a delivered action reads as
    /// accepted before the card leaves. The hold is skipped when nothing is
    /// dismissed and when reduce-motion is on.
    private func commitDelivered(_ onDelivered: (() -> Void)?) {
        guard let onDelivered else { return }
        guard !reduceMotion else {
            onDelivered()
            return
        }
        commitTask?.cancel()
        commitToken += 1
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: InteractionMotion.commitHold)
            guard !Task.isCancelled else { return }
            commitTask = nil
            onDelivered()
        }
    }

    private func sendCardAnswer(paneId: String) {
        let text = cardAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        performCardAction(paneId: paneId, prompt: text) {
            eventManager.sendText(paneId: paneId, text: text)
        }
    }

    private func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let paneId = composingPaneId, !text.isEmpty else {
            cancelComposing()
            return
        }
        let targetAgent = eventManager.agents.first {
            ($0.paneId ?? "standalone:\($0.source)") == paneId
                || $0.paneId == paneId
                || $0.source == paneId
        }
        let label = targetAgent?.source ?? StandaloneAgentDispatcher.cleanAgentName(from: paneId)

        var delivered = false
        if paneId.hasPrefix("standalone:") {
            delivered = StandaloneAgentDispatcher.dispatchPrompt(
                agentName: StandaloneAgentDispatcher.cleanAgentName(from: paneId),
                text: text, cwd: targetAgent?.cwd, autoSend: true)
        } else if OpenCodeActionWriter.isOpenCodePane(paneId) {
            delivered = StandaloneAgentDispatcher.dispatchPrompt(
                agentName: "opencode", text: text, cwd: targetAgent?.cwd, autoSend: true)
        } else {
            // Multiplexer panes take text through the adapter directly; no
            // Accessibility or clipboard involved.
            let activeAdapter = eventManager.activeAdapter
            activeAdapter.sendLine(paneId: paneId, text: text)
            activeAdapter.focusPane(paneId: paneId)
            delivered = true
        }

        if delivered {
            showComposeNotice("Sent to \(label)")
            cancelComposing()
        } else {
            // Never clear a draft that did not reach the agent.
            showComposeNotice("Couldn't reach \(label). Grant Accessibility or open its terminal.")
            promptFocused = true
        }
    }

    private func showComposeNotice(_ text: String) {
        composeNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { composeNotice = text }
        composeNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.0))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { composeNotice = nil }
        }
    }

    private func cancelComposing() {
        composingPaneId = nil
        AppDelegate.composingPaneId = nil
        promptText = ""
        promptFocused = false
    }

    private func playSound(for event: AgentEvent) {
        let config = NotchHUDConfig.shared
        guard config.enableAgentAlerts else { return }
        guard !(config.muteInTerminal && isTerminalFocused()) else { return }
        // Quiet hours silence sounds only — the pill and queue stay visible,
        // so an approval can never be missed silently.
        guard !config.isInQuietHours() else { return }
        let soundName = config.soundName(for: event.kind)
        guard let sound = NSSound(named: soundName) else { return }
        sound.volume = config.soundVolume
        sound.play()
    }

    private func isTerminalFocused() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        let terminals: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "io.alacritty",
            "org.wezfurlong.wezterm", "com.ghostty.app", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.google.antigravity-ide",
        ]
        return terminals.contains(bundleID)
    }
}
