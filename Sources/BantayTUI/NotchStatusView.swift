import AppKit
import SwiftUI
import UserNotifications

@MainActor
struct NotchStatusView: View {
    @EnvironmentObject var eventManager: AgentEventManager
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var opacity: Double = 0
    @State private var showDetail = false
    @State private var hoveredRow: String?
    @State private var showThoughtBubble = false
    @State private var composingPaneId: String?
    @State private var promptText = ""
    @State private var pulse = false
    @State private var queueSelections: [String: Set<Int>] = [:]
    @State private var showWelcome = false
    @State private var glowPulse = false
    @State private var now = Date()
    @State private var showShelf = false
    @State private var showAttention = false
    @State private var showTasks = false
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
    /// Brief white border flash when the global hotkey fires (item 10).
    @State private var hotkeyBlink = false
    /// Cancels the pending hotkey-blink reset so rapid presses extend the
    /// flash rather than stacking resets.
    @State private var hotkeyBlinkResetTask: Task<Void, Never>?
    /// Namespace for tab bar underline matchedGeometryEffect (item 11).
    @Namespace private var tabBarNamespace
    private let adapter = HerdrSocketAdapter()

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
        if isCenteredIdle {
            return full
        }
        var width = IslandMetrics.idleClosedWidth(
            style: config.idleStyle,
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

    private var islandWidth: CGFloat {
        if isExpanded {
            return IslandMetrics.expandedWidth
        }
        if isCenteredIdle {
            return min(AppDelegate.notchWidth, IslandMetrics.expandedWidth)
        }
        return closedPillWidth
    }

    /// Idle placement: slide the closed chip beside the notch (left/right) or
    /// keep it centered underneath it. Position anchoring stays 100% stable
    /// regardless of transient event state (eliminates position jumping).
    private var islandOffsetX: CGFloat {
        guard !isExpanded else { return 0 }
        return IslandMetrics.dockOffset(
            side: NotchHUDConfig.shared.islandDockSide,
            notchWidth: AppDelegate.notchWidth,
            chipWidth: closedPillWidth)
    }

    /// Number of section headers the grouped roster will draw (0 when
    /// grouping is off). Fed into the height math so the panel grows to fit
    /// its headers instead of clipping the roster against the rounded bottom.
    private var rosterGroupCount: Int {
        guard NotchHUDConfig.shared.expandedGroupByState else { return 0 }
        return IslandMetrics.groupHeaderCount(kinds: visibleAgents.map(\.kind))
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
            } else {
                return IslandMetrics.expandedSize(
                    topInset: chipTopOffset, agentCount: mergedRoster.count,
                    queueCount: 0,
                    shelfTabVisible: NotchHUDConfig.shared.showShelfTab,
                    overflowCount: 0,
                    groupCount: rosterGroupCount,
                    footerVisible: false
                ).height
            }
        }
        return IslandMetrics.closedSize(topInset: chipTopOffset, notchWidth: islandWidth).height
    }

    private var contentHeight: CGFloat {
        if showTasks {
            return IslandMetrics.contentHeightForTasks(
                isExpanded: isExpanded,
                topInset: chipTopOffset,
                taskCount: TaskStore.shared.tasks.count,
                sectionCount: 3,
                shelfTabVisible: NotchHUDConfig.shared.showShelfTab
            )
        } else {
            return IslandMetrics.contentHeight(
                isExpanded: isExpanded, topInset: chipTopOffset,
                agentCount: mergedRoster.count, queueCount: 0,
                shelfTabVisible: NotchHUDConfig.shared.showShelfTab,
                overflowCount: 0,
                groupCount: rosterGroupCount,
                footerVisible: false)
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

    /// The roster as rendered: muted sources dropped, approval variance and
    /// choices attached from the manager's pending-approval bookkeeping.
    private var mergedRoster: [AgentSnapshot] {
        eventManager.mergeApprovals(into: visibleAgents)
    }

    private var cornerRad: CGFloat { IslandMetrics.cornerRadius(expanded: isExpanded) }

    private var activeHoverScale: CGFloat {
        max(
            pulse ? 1.03 : 1, IslandMetrics.hoverScale(isHovered: isHovered, isExpanded: isExpanded)
        )
    }

    private var morphAnimation: Animation {
        switch IslandMetrics.morphStyle(reduceMotion: reduceMotion) {
        case .spring:
            .smooth(duration: IslandMetrics.morphDuration, extraBounce: 0)
        case .linear:
            .linear(duration: 0.1)
        }
    }

    /// Content cross-fade for the `isExpanded` flip, coordinated with the
    /// background morph: opacity + top-anchored scale when motion is on (the
    /// text fades as the notch morphs, no pop), opacity-only under reduce
    /// motion (the short linear morph drives it, so it snaps near-instantly).
    /// Centered idle is a pure fade: the split strip is full-window-width and
    /// scale would make it appear to sweep laterally while the pill morphs.
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
                .offset(y: chipTopOffset)
        }
        .overlay(edgeGlow)
        .scaleEffect(activeHoverScale, anchor: .top)
        .frame(
            width: islandWidth + cornerRad * 2,
            height: islandHeight,
            alignment: .top
        )
        .clipped()
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
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showTasks)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showShelf)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showAttention)
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
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { date in
            // Only advance the clock while something on screen shows it
            // (expanded + elapsed time, or a live peek open) — otherwise the
            // 1s tick would recompute the whole body every second while idle.
            if (isExpanded && NotchHUDConfig.shared.showElapsedTime)
                || peekingPaneId != nil
            {
                now = date
            }
            pollClipboard(at: date)
        }
        .onChange(of: hasSeenOnboarding) { seen in
            if !seen { showWelcome = true }
        }
        .focusable()
        .modifier(FocusEffectDisabledCompat())
        .modifier(
            ShortcutKeyPressModifier { char in
                guard let shortcut = IslandMetrics.shortcutKey(for: char) else {
                    return false
                }
                handleShortcut(shortcut)
                return true
            }
        )
        .modifier(
            NavigationKeyPressModifier { keyCode in
                handleNavigationKey(keyCode)
            }
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .notchHotkeyPressed)
        ) { _ in
            if isExpanded {
                expandTo(false)
            } else if !eventManager.agents.isEmpty {
                expandTo(true)
            } else {
                // Nothing to expand — blink the pill so the user knows the
                // hotkey was received (item 10: hotkey feedback). Cancel any
                // pending reset so rapid presses extend the blink instead of
                // stacking resets that truncate it.
                hotkeyBlinkResetTask?.cancel()
                withAnimation(.easeOut(duration: 0.12)) { hotkeyBlink = true }
                hotkeyBlinkResetTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.15)) { hotkeyBlink = false }
                }
            }
        }
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
            RoundedRectangle(cornerRadius: cornerRad, style: .continuous)
                .strokeBorder(
                    Color(hex: IslandMetrics.glowBlockedColor).opacity(glowPulse ? 0.95 : 0.25),
                    lineWidth: 2
                )
                .frame(width: islandWidth, height: islandHeight)
                .allowsHitTesting(false)
                .onAppear {
                    if reduceMotion {
                        glowPulse = true
                    } else {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            glowPulse = true
                        }
                    }
                }
        }
    }

    /// Single-key roster shortcuts (Y/N/digits) when the island is key and
    /// shortcuts are enabled. Applies to the top pending approval.
    private func handleShortcut(_ shortcut: IslandMetrics.ApprovalShortcut) {
        guard NotchHUDConfig.shared.keyboardShortcuts,
            composingPaneId == nil,
            !eventManager.isResolving(agent: approvalQueueAgents.first),
            let agent = approvalQueueAgents.first,
            let paneId = agent.paneId
        else {
            return
        }
        switch shortcut {
        case .approve:
            // Multi-select: Y submits the toggled selection; otherwise plain
            // approve. The pill and the roster share queueSelections (keyed
            // by pane id), so digits + Y work consistently from both.
            if agent.approval.isMulti {
                let numbers = IslandMetrics.ApprovalControls.selectionNumbers(
                    queueSelections[paneId] ?? [])
                eventManager.performAction(paneId: paneId) {
                    $0.approveMulti(paneId: paneId, selections: numbers)
                }
                queueSelections.removeValue(forKey: paneId)
            } else {
                eventManager.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
            }
        case .deny:
            eventManager.performAction(paneId: paneId) { $0.deny(paneId: paneId) }
        case .option(let number):
            if agent.approval.isMulti {
                queueSelections[paneId] = IslandMetrics.ApprovalControls.toggling(
                    queueSelections[paneId] ?? [], index: number - 1)
            } else {
                eventManager.performAction(paneId: paneId) {
                    $0.approveChoice(paneId: paneId, choice: number)
                }
            }
        }
    }

    /// Arrow-key / Enter / Esc roster navigation (plan 016 4b). Pure cursor
    /// movement delegates to `IslandMetrics.rowIndex`; Enter activates the
    /// focused row's primary action; Esc clears focus. Returns true when
    /// handled.
    private func handleNavigationKey(_ keyCode: UInt16) -> Bool {
        guard composingPaneId == nil, isExpanded else { return false }
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
            guard let paneId = agent.paneId else { return }
            eventManager.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
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
                isExpanded,
                composingPaneId == nil
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
            handleShortcut(shortcut)
            return nil
        }
    }

    private func removeLegacyKeyMonitor() {
        if let monitor = legacyKeyMonitor {
            NSEvent.removeMonitor(monitor)
            legacyKeyMonitor = nil
        }
    }

    /// Fetch a live output tail for `paneId` off the main actor and show it in
    /// the peek region. Debounced by `peekingPaneId` so rapid hovers don't
    /// stack fetches; the adapter does blocking I/O, hence the detached task.
    /// The inline cleaner is the hoisted pure `LogFormatter.cleanedTail`
    /// (plan 016 3a), so the 6-line hover tail and the full overlay share one
    /// tested cleaner.
    private func fetchPeek(paneId: String) {
        guard peekingPaneId != paneId else { return }
        peekingPaneId = paneId
        peekTask?.cancel()
        peekTask = Task.detached { [adapter] in
            let tail = await adapter.captureTail(paneId: paneId, lines: 6)
            let cleaned = LogFormatter.cleanedTail(tail, maxLines: 6, maxLineLength: 120)
                .joined(separator: "\n")
            await MainActor.run {
                if self.peekingPaneId == paneId {
                    self.peekText = cleaned
                }
            }
        }
    }

    private func endPeek() {
        peekingPaneId = nil
        peekTask?.cancel()
        peekTask = nil
    }

    /// Cancels composing on Escape. `.onKeyPress` is macOS 14+; on older
    /// systems the compose row's ✕ button remains the cancel affordance.
    private struct EscapeCancelsModifier: ViewModifier {
        var onEscape: () -> Void
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 14.0, *) {
                content.onKeyPress(.escape) {
                    onEscape()
                    return .handled
                }
            } else {
                content
            }
        }
    }

    /// Hides the focus ring around the island (macOS 14+).
    private struct FocusEffectDisabledCompat: ViewModifier {
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 14.0, *) {
                content.focusEffectDisabled()
            } else {
                content
            }
        }
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
            return .white.opacity(isExpanded ? 0.09 : 0.04)
        }
    }

    private var islandBackground: some View {
        Rectangle()
            .fill(.black)
            .mask(islandMask)
            .frame(width: islandWidth + cornerRad * 2, height: islandHeight)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRad, style: .continuous)
                    .strokeBorder(
                        hotkeyBlink
                            ? .white.opacity(0.45)
                            : spendStrokeColor,
                        lineWidth: hotkeyBlink ? 1.5 : 1
                    )
                    .frame(width: islandWidth, height: islandHeight)
                    .animation(.easeOut(duration: 0.12), value: hotkeyBlink)
            }
    }

    private var islandMask: some View {
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

    /// Notch-hugging corner wing. The blend version (`destinationOut` inside a
    /// mask) flakes into a stray solid square on macOS 26, so this is a pure
    /// path silhouette: the cap sliver the square-minus-rounded-cut composite
    /// actually produces. Verified pixel-identical to the blend's output at 4×
    /// (213 px vs 209 px, ±antialiasing).
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
        } else if let event = eventManager.currentEvent, let paneId = event.paneId,
            IslandMetrics.requiresApproval(event.kind.rawValue)
        {
            approvalPill(event: event, paneId: paneId)
                .transition(contentTransition)
        } else if isCenteredClosed {
            if eventManager.agents.isEmpty && eventManager.currentEvent == nil {
                // True empty idle: nothing to show, but the pill must stay
                // tappable to expand.
                Color.clear
                    .frame(width: islandWidth, height: islandHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { expandTo(true) }
            } else {
                // Center-docked idle with agents/events: leak details to BOTH
                // sides of the physical notch (working → left, needs-you +
                // failures → right). Hidden-behind-the-notch was a regression
                // that made the app look dead at idle.
                centeredSplitStrip
                    .transition(contentTransition)
                    .onTapGesture { expandTo(true) }
            }
        } else if let event = eventManager.currentEvent {
            closedPill(
                color: event.kind.color,
                label: event.kind.label,
                title: showDetail ? event.title : nil,
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
            agentStrip
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

    /// Centered idle strip: the pill covers the notch and the window spans
    /// the full width, so agent details leak out to both sides — working
    /// Centered idle/closed live strip: details split to BOTH sides of the physical
    /// notch cutout. Active/working status renders in the LEFT wing, needs-you/failures
    /// render in the RIGHT wing. The center camera area contains ZERO text/icons.
    @ViewBuilder
    private var centeredSplitStrip: some View {
        let agents = eventManager.agents
        let needsYou = agents.filter { $0.kind == .accessRequest || $0.kind == .waiting }
        let working = agents.filter { $0.kind.isOngoing && $0.kind != .accessRequest }
        let failed = agents.filter { $0.kind == .failed }
        let left = working.prefix(3)
        let windowW = IslandMetrics.windowSize().width
        let sideWidth =
            (windowW
                - IslandMetrics.notchWidth(
                    screenWidth: AppDelegate.islandScreen()?.frame.width ?? windowW,
                    auxLeft: AppDelegate.auxLeftWidth,
                    auxRight: AppDelegate.auxRightWidth,
                    safeTop: AppDelegate.topInset)) / 2
        let notchPad: CGFloat = 8

        HStack(spacing: 0) {
            // Left wing: working agents OR transient ongoing progress (e.g. "Working").
            // ALWAYS stays to the left of the physical camera notch cutout.
            HStack(spacing: IslandMetrics.idleChipGap) {
                if !left.isEmpty {
                    ForEach(Array(left.enumerated()), id: \.element.id) { _, agent in
                        HStack(spacing: IslandMetrics.idleChipDotGap) {
                            Circle()
                                .fill(Color(hex: agent.kind.color))
                                .frame(
                                    width: IslandMetrics.idleDotSize,
                                    height: IslandMetrics.idleDotSize)
                            Text(agent.source)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, IslandMetrics.idleChipHPad)
                        .frame(height: 20)
                        .background(Color.white.opacity(0.10), in: Capsule())
                    }
                    if working.count > left.count {
                        Text("+\(working.count - left.count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                } else if let event = eventManager.currentEvent, event.kind.isOngoing {
                    HStack(spacing: IslandMetrics.idleChipDotGap) {
                        Circle()
                            .fill(Color(hex: event.kind.color))
                            .frame(
                                width: IslandMetrics.idleDotSize,
                                height: IslandMetrics.idleDotSize)
                        Text(event.title ?? event.kind.label)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, IslandMetrics.idleChipHPad)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.10), in: Capsule())
                }
            }
            .frame(maxWidth: sideWidth, alignment: .leading)
            .padding(.leading, notchPad)

            Spacer(minLength: 0)

            // Right wing: needs-you count (amber) and failed count (red).
            HStack(spacing: 5) {
                if !needsYou.isEmpty {
                    Circle().fill(Color(hex: AgentEventKind.accessRequest.color))
                        .frame(width: 7, height: 7)
                    Text("\(needsYou.count) need you")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
                if !failed.isEmpty {
                    Circle().fill(Color(hex: AgentEventKind.failed.color))
                        .frame(width: 7, height: 7)
                    Text("\(failed.count) failed")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, IslandMetrics.idleChipHPad)
            .frame(height: 20)
            .background(
                (needsYou.isEmpty && failed.isEmpty)
                    ? Color.clear : Color.white.opacity(0.10), in: Capsule()
            )
            .frame(maxWidth: sideWidth, alignment: .trailing)
            .padding(.trailing, notchPad)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
        .contentShape(Rectangle())
    }

    private func closedPill(
        color: String, label: String, title: String?,
        dots: [AgentEventKind] = [], action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if NotchHUDConfig.shared.showNotchMascot {
                    MascotView(
                        archetype: NotchHUDConfig.shared.selectedMascotArchetype,
                        state: currentMascotState,
                        size: 13
                    )
                } else {
                    Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                if let title {
                    Text("·").foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !dots.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(dots.prefix(5).enumerated()), id: \.offset) { _, kind in
                            Circle().fill(Color(hex: kind.color)).frame(width: 4, height: 4)
                        }
                        if dots.count > 5 {
                            Text("+\(dots.count - 5)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
            }
            .frame(width: islandWidth, height: islandHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Idle (closed) live strip: per-agent chips beside the notch, in the style
    /// the user picked. Tap to expand the full roster. Clipped strictly to
    /// islandWidth so chips never overflow container boundaries (fixes UI leak).
    @ViewBuilder
    private var agentStrip: some View {
        let agents = eventManager.agents
        let shown = idleShownCount
        let overflow = max(agents.count - shown, 0)
        ZStack {
            switch NotchHUDConfig.shared.idleStyle {
            case .dots:
                HStack(spacing: 4) {
                    ForEach(Array(agents.prefix(shown).enumerated()), id: \.offset) { _, agent in
                        Circle()
                            .fill(Color(hex: agent.kind.color))
                            .frame(
                                width: IslandMetrics.idleDotSize, height: IslandMetrics.idleDotSize)
                    }
                    if overflow > 0 {
                        Text("+\(overflow)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, IslandMetrics.idleChipHPad)
            case .summary:
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: AgentEventKind.idle.color))
                        .frame(width: 7, height: 7)
                    Text("\(agents.count) agent\(agents.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            case .names:
                HStack(spacing: IslandMetrics.idleChipGap) {
                    ForEach(Array(agents.prefix(shown).enumerated()), id: \.offset) { _, agent in
                        HStack(spacing: IslandMetrics.idleChipDotGap) {
                            Circle()
                                .fill(Color(hex: agent.kind.color))
                                .frame(
                                    width: IslandMetrics.idleDotSize,
                                    height: IslandMetrics.idleDotSize)
                            Text(agent.source)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, IslandMetrics.idleChipHPad)
                        .frame(height: 20)
                        .background(Color.white.opacity(0.10), in: Capsule())
                    }
                    if overflow > 0 {
                        Text("+\(overflow)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
        }
        .frame(width: islandWidth, height: islandHeight)
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) { recentCompletionBadge }
    }

    @ViewBuilder
    private var recentCompletionBadge: some View {
        if !eventManager.recentCompletions.isEmpty {
            Text("\(eventManager.recentCompletions.count) recent")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Color.teal.opacity(0.85), in: Capsule())
                .offset(x: -5, y: -4)
                .accessibilityLabel(
                    "\(eventManager.recentCompletions.count) recent agent completions")
        }
    }

    private func approvalPill(event: AgentEvent, paneId: String) -> some View {
        let variance = event.effectiveVariance
        let choices = event.choices ?? []
        let pill = HStack(spacing: 8) {
            Circle().fill(Color(hex: event.kind.color)).frame(width: 7, height: 7)
            Text(event.kind.label)
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
                Text("·").foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            approvalActions(variance: variance, choices: choices, paneId: paneId)
            approvalActionButton(
                systemName: "arrow.up.right", color: .white.opacity(0.6), help: "Focus pane"
            ) {
                adapter.paneFocus(paneId: paneId)
            }
        }
        .frame(width: islandWidth, height: IslandMetrics.pillHeight)
        .contentShape(Rectangle())
        return pill
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
                eventManager.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
            }
            approvalActionButton(
                systemName: "xmark.circle.fill", color: .red, help: "Deny",
                disabled: resolving
            ) {
                eventManager.performAction(paneId: paneId) { $0.deny(paneId: paneId) }
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
                                eventManager.performAction(paneId: paneId) {
                                    $0.approveChoice(paneId: paneId, choice: opt.id)
                                }
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
                        eventManager.performAction(paneId: paneId) {
                            $0.approveChoice(paneId: paneId, choice: opt.id)
                        }
                    }
                }
            } else {
                approvalActionButton(
                    systemName: "checkmark.circle.fill", color: .green, help: "Approve",
                    disabled: resolving
                ) {
                    eventManager.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
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
                eventManager.performAction(paneId: paneId) {
                    $0.approveMulti(paneId: paneId, selections: numbers)
                }
                queueSelections.removeValue(forKey: paneId)
            }
        }
    }

    private func approvalActionButton(
        systemName: String, color: Color, help: String, disabled: Bool = false,
        label: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(disabled ? color.opacity(0.3) : color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScalePressButtonStyle())
        .help(help)
        .accessibilityLabel(label ?? help)
        .disabled(disabled)
    }

    private func approvalActionButton(
        label: Text, color: Color, help: String, disabled: Bool = false,
        accessibilityLabel: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(disabled ? color.opacity(0.3) : color)
                .padding(.horizontal, 6)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScalePressButtonStyle())
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
        .disabled(disabled)
    }

    /// Affordance that opens the full-log + diff preview overlay (plan 016
    /// 3a). One overlay at a time; the controller cancels any in-flight fetch
    /// when the overlay is dismissed.
    private func peekButton(agent: AgentSnapshot) -> some View {
        Button {
            PeekPanelController.shared.show(agent: agent, adapter: adapter)
        } label: {
            Image(systemName: "eye")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScalePressButtonStyle())
        .help("View live output + git diff")
        .accessibilityLabel("View live output for \(agent.source)")
    }

    private var expandedList: some View {
        let counts = IslandMetrics.agentCounts(
            kinds: visibleAgents.map(\.kind))
        return VStack(spacing: 0) {
            headerBar(counts: counts)

            if NotchHUDConfig.shared.showShelfTab {
                shelfTabBar
            }

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

            if showTasks {
                TaskWidgetView()
            } else if showAttention {
                attentionContent
            } else if showShelf {
                shelfContent
            } else {
                rosterContent
            }
        }
        .frame(width: islandWidth, height: contentHeight, alignment: .top)
    }

    /// One list: blocked agents render as rows with inline approve/deny
    /// controls, everything else as plain rows. No separate queue section.
    @ViewBuilder
    private var rosterContent: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if visibleAgents.isEmpty {
                    // Item 4: structured empty state for new users. Lives
                    // inside the scroll viewport so it isn't clipped by the
                    // panel height when the roster is empty.
                    VStack(spacing: 8) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.25))
                        Text("No agents detected")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                        Text("Start Claude Code, Codex, or opencode\nand they'll appear here.")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundColor(.white.opacity(0.3))
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: rosterScrollHeight)
                } else if NotchHUDConfig.shared.expandedGroupByState {
                    groupedAgentRows
                } else {
                    flatAgentRows
                }
            }
        }
        .frame(height: rosterScrollHeight)
        .scrollIndicators(.hidden)
    }

    /// F8 triage view: only agents that need you (blocked) or failed.
    /// Reuses the merged roster so approval variance/choices render.
    private var attentionContent: some View {
        let rows = IslandMetrics.attentionFilter(mergedRoster)
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text("Nothing needs you")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandMetrics.rowHeight)
            }
            ForEach(rows) { agent in
                agentRow(agent: agent)
            }
            Spacer(minLength: 0)
        }
    }

    /// Roster scroll area: natural row height from the rendered roster
    /// (muted sources excluded), capped so header/tabs always stay visible
    /// inside the island (scrolls when 6+ rows overflow). The roster includes
    /// blocked agents as inline rows, so their height is counted in
    /// `agentCount` — no separate queue section to subtract.
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
        return IslandMetrics.stableRosterHeight(
            agentCount: mergedRoster.count, availableHeight: available,
            groupCount: rosterGroupCount)
    }

    /// Item 11: underline tab bar with matchedGeometryEffect for a sliding
    /// indicator, replacing the capsule pills. Feels more native on macOS.
    private var shelfTabBar: some View {
        HStack(spacing: 12) {
            shelfTabButton(title: "Agents", selected: !showShelf && !showAttention && !showTasks) {
                showShelf = false
                showAttention = false
                showTasks = false
            }
            if NotchHUDConfig.shared.showTasksTab {
                shelfTabButton(title: "Tasks", selected: showTasks) {
                    showShelf = false
                    showAttention = false
                    showTasks = true
                }
            }
            if NotchHUDConfig.shared.attentionFilterEnabled {
                shelfTabButton(
                    title: "Attention", selected: showAttention
                ) {
                    showShelf = false
                    showAttention = true
                    showTasks = false
                }
            }
            shelfTabButton(title: "Shelf", selected: showShelf) {
                showAttention = false
                showShelf = true
                showTasks = false
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
    }

    private func shelfTabButton(title: String, selected: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? .white : .white.opacity(0.9))
                    .padding(.horizontal, 8)
                // Item 11: sliding underline indicator.
                if selected {
                    Rectangle()
                        .fill(.white)
                        .frame(height: 1.5)
                        .matchedGeometryEffect(id: "tabIndicator", in: tabBarNamespace)
                } else {
                    Rectangle()
                        .fill(.clear)
                        .frame(height: 1.5)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(ScalePressButtonStyle())
        .accessibilityValue(selected ? "selected" : "not selected")
        .animation(.easeInOut(duration: 0.2), value: selected)
    }

    private var shelfContent: some View {
        VStack(spacing: 0) {
            if shelfStore.files.isEmpty && clipboardItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Drop files here to keep them")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                    Text(retentionHint)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
            }
            if !shelfStore.files.isEmpty {
                // Thumbnail card strip — the actual "shelf" feel.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelfStore.files) { file in
                            shelfCard(file)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .frame(height: 84)
            }
            ForEach(clipboardItems) { item in
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill").font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                    Text(item.text)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(0)
                    Spacer(minLength: 4)
                    Button(action: {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(item.text, forType: .string)
                    }) {
                        Image(systemName: "arrow.uturn.left").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                    .accessibilityLabel("Copy text to clipboard")
                    .layoutPriority(1)
                }
                .padding(.horizontal, 16)
                .frame(height: IslandMetrics.rowHeight)
            }
            Spacer(minLength: 0)
        }
        // Glow feedback when a drop lands.
        .overlay {
            if shelfDropGlow {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.blue.opacity(0.8), lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: shelfDropGlow)
        // Drops are handled at the window level (KeyablePanel posts
        // .notchFilesDropped → handleFilesDropped). No SwiftUI .dropDestination
        // here: registering it alongside the window's NSDraggingDestination
        // creates two competing targets and the drop gets refused.
    }

    /// "kept for X" hint driven by the configured retention.
    private var retentionHint: String {
        let keep = ShelfKeepDuration.from(
            configRaw: NotchHUDConfig.shared.shelfKeepDuration)
        switch keep {
        case .forever: return "Files stay until you remove them."
        default: return "Files auto-expire after \(keep.rawValue.lowercased())."
        }
    }

    /// One thumbnail card: icon, name, hover actions (QuickLook / open /
    /// remove), draggable back out. Mirrors NotchDrop's DropItemView.
    private func shelfCard(_ file: ShelfFile) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
                if let icon = file.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "doc.fill").font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .topTrailing) {
                // Remove (⌥-style): a small ✕ always present, like NotchDrop's
                // option-key reveal but simpler to discover.
                Button(action: { shelfStore.remove(file) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .background(Color.black.opacity(0.6).clipShape(Circle()))
                }
                .buttonStyle(ScalePressButtonStyle())
                .help("Remove from shelf")
                .offset(x: 4, y: -4)
            }
            Text(file.name)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 64)
        }
        .frame(width: 68)
        .contentShape(Rectangle())
        .draggable(file.url)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
        .onTapGesture(count: 1) { ShelfQuickLook.show(file.url) }
        .help("Click: preview · Double-click: open")
        // Item 9: right-click context menu for shelf cards.
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(file.url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Divider()
            Button("Remove") { shelfStore.remove(file) }
        }
    }

    private var spendGaugeBadge: some View {
        let cost = eventManager.usage.costUSD
        let budget = max(NotchHUDConfig.shared.dailyBudgetUSD, 0.5)
        let ratio = cost / budget
        let formattedCost = String(format: "$%.2f", cost)
        let formattedBudget =
            budget >= 10 && budget.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "$%.0f", budget)
            : String(format: "$%.2f", budget)
        let color: Color = ratio >= 1.0 ? .red : (ratio >= 0.7 ? .orange : .cyan)
        return HStack(spacing: 3) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text("\(formattedCost)/\(formattedBudget)")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .monospacedDigit()
                .foregroundColor(color)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .help("Daily AI Spend: \(formattedCost) of \(formattedBudget) limit")
    }

    private var tokenRateBadge: some View {
        // Use the manager's already-published rate (computed off-main with an
        // mtime memo). Scanning transcripts synchronously in the body would
        // beachball the expanded panel on every 1s clock tick.
        let tpm = Int(eventManager.usageRate.tokensPerMinute ?? 0)
        let rateText: String = {
            if tpm >= 1000 {
                return String(format: "⚡%.1fk/m", Double(tpm) / 1000.0)
            } else {
                return "⚡\(tpm)/m"
            }
        }()
        return HStack(spacing: 2) {
            Text(rateText)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .monospacedDigit()
                .foregroundColor(.cyan)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Color.cyan.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .help("Live token processing rate over the last minute")
        .accessibilityLabel("Token rate \(tpm) tokens per minute")
    }

    /// True when a real usage/cost source is live (kilo's SQLite ledger is
    /// the only one the app reads for real numbers today). Gates badges that
    /// would otherwise show fabricated zeros/percentages.
    private var hasUsageData: Bool {
        KiloUsageAdapter.detect() || eventManager.usage.totalTokens > 0
            || (eventManager.usageRate.tokensPerMinute ?? 0) > 0
    }

    private var quotaAxiBadge: some View {
        let active = Array(Set(eventManager.agents.map(\.source)))
        let quotas = QuotaAxiTracker.fallbackQuotas(
            activeProviders: active,
            costUSD: eventManager.usage.costUSD,
            budgetUSD: NotchHUDConfig.shared.dailyBudgetUSD
        )
        let minQuota = quotas.min(by: { $0.remainingPercent < $1.remainingPercent })
        let percentInt = Int(minQuota?.remainingPercent ?? 100)
        let color: Color = percentInt <= 20 ? .red : (percentInt <= 50 ? .orange : .green)

        return HStack(spacing: 3) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text("Q:\(percentInt)%")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .monospacedDigit()
                .foregroundColor(color)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .help("Live Provider Quota: \(minQuota?.provider ?? "AI") \(percentInt)% remaining")
        .accessibilityLabel("Quota remaining \(percentInt) percent")
    }

    private var currentMascotState: MascotState {
        MascotEvaluator.evaluate(
            agents: mergedRoster,
            quotaLow: false,
            recentCompletion: eventManager.currentEvent?.kind == .completed
        )
    }

    private func headerBar(counts: IslandMetrics.AgentCounts) -> some View {
        HStack(spacing: 6) {
            if NotchHUDConfig.shared.showNotchMascot {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        showThoughtBubble.toggle()
                    }
                } label: {
                    MascotView(
                        archetype: NotchHUDConfig.shared.selectedMascotArchetype,
                        state: currentMascotState,
                        size: 15
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showThoughtBubble, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(NotchHUDConfig.shared.selectedMascotArchetype.displayName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.yellow)
                            Spacer(minLength: 0)
                            Text("Lv.\(NotchHUDConfig.shared.mascotLevel)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        Text(
                            "“\(NotchHUDConfig.shared.selectedMascotArchetype.personalityQuote(for: currentMascotState))”"
                        )
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(3)
                    }
                    .padding(8)
                    .frame(width: 190)
                    .background(Color.black.opacity(0.9))
                }
                .help(
                    "\(NotchHUDConfig.shared.selectedMascotArchetype.displayName): “\(NotchHUDConfig.shared.selectedMascotArchetype.personalityQuote(for: currentMascotState))”"
                )
                .accessibilityLabel(
                    "\(NotchHUDConfig.shared.selectedMascotArchetype.displayName): \(currentMascotState.statusText)"
                )
            }
            if counts.needsInput > 0 {
                Text("\(counts.needsInput) need you")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundColor(.yellow)
            }
            if counts.working > 0 {
                Text("\(counts.working) working")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
            if counts.needsInput == 0 && counts.working == 0 {
                Text("Agents")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.white)
            }
            if NotchHUDConfig.shared.enableSpendGlow {
                spendGaugeBadge
            }
            if NotchHUDConfig.shared.showTokenRate {
                tokenRateBadge
            }
            // Quota badge only when a real usage source exists — a synthetic
            // "Q:100%" from fallbackQuotas with no ledger is a lie.
            if NotchHUDConfig.shared.enableQuotaAxiGauge, hasUsageData {
                quotaAxiBadge
            }
            Spacer(minLength: 4)
            if let title = eventManager.currentEvent?.title {
                Text(title)
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
            Button {
                if NotchHUDConfig.shared.panelPinned {
                    NotchHUDConfig.shared.panelPinned = IslandMetrics.pinAfterCollapse(
                        reason: .explicitUnpin,
                        wasPinned: true,
                        persistAcrossCollapse: true)
                } else {
                    NotchHUDConfig.shared.panelPinned = true
                }
            } label: {
                Image(systemName: panelPinned ? "pin.fill" : "pin")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(panelPinned ? .white : .white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalePressButtonStyle())
            .help(panelPinned ? "Unpin panel" : "Pin panel open")
            .accessibilityLabel(panelPinned ? "Unpin panel" : "Pin panel open")
            .accessibilityValue(panelPinned ? "pinned" : "unpinned")

            Button {
                AppDelegate.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalePressButtonStyle())
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
        }
        .padding(.horizontal, 14)
        .frame(height: IslandMetrics.headerHeight)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    private var groupedAgentRows: some View {
        let grouped = Dictionary(grouping: mergedRoster) { agent in
            IslandMetrics.expandedGroupRank(agent.kind)
        }
        return VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { rank in
                let rows = grouped[rank] ?? []
                if !rows.isEmpty {
                    sectionHeader(
                        IslandMetrics.groupLabel(rank: rank), count: rows.count,
                        color: rows.first?.kind.color ?? "#8a8aa8")
                    ForEach(rows) { agent in
                        agentRow(agent: agent)
                    }
                }
            }
            recentActivitySection
        }
    }

    private func sectionHeader(_ title: String, count: Int, color: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: color)).frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.sectionHeaderHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) agents")
    }

    /// "What happened recently" — the last few completions/failures, newest
    /// first. Answers "did it actually do work" without opening the peek
    /// overlay: source + done/failed + what it was doing + when.
    @ViewBuilder
    private var recentActivitySection: some View {
        let recents = eventManager.recentCompletions
        if !recents.isEmpty {
            sectionHeader("Recent", count: recents.count, color: "#8a8aa8")
            ForEach(recents) { recent in
                HStack(spacing: 8) {
                    Circle()
                        .fill(
                            recent.kind == .failed
                                ? Color(hex: AgentEventKind.failed.color)
                                : Color(hex: AgentEventKind.completed.color)
                        )
                        .frame(width: 6, height: 6)
                    // Item 12: truncation consistency — agent source uses .tail
                    // so the differentiator at the end stays visible.
                    Text(recent.source)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let title = recent.title {
                        Text(title)
                            .font(.system(size: 8.5, weight: .regular))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    // Item 8: show duration on completed rows when available.
                    if let duration = recent.duration {
                        Text(
                            IslandMetrics.elapsedLabel(
                                since: Date(timeIntervalSinceNow: -duration), now: Date())
                        )
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.3))
                    }
                    Text(IslandMetrics.elapsedLabel(since: recent.createdAt, now: now))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .frame(height: IslandMetrics.rowHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(recent.source) \(recent.kind == .failed ? "failed" : "completed")"
                        + (recent.title.map { ": \($0)" } ?? ""))
            }
        }
    }

    private var flatAgentRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(mergedRoster.enumerated()), id: \.element.id) { index, agent in
                VStack(spacing: 0) {
                    // Item 13: 1px separator between rows (not before first).
                    if index > 0 {
                        Rectangle().fill(.white.opacity(0.04)).frame(height: 1)
                    }
                    agentRow(agent: agent)
                        .background(
                            focusedRow == index
                                ? Color.accentColor.opacity(0.18) : Color.clear
                        )
                }
                // Item 1: staggered appear animation per row.
                .transition(.opacity.combined(with: .offset(y: 4)))
                .animation(
                    .easeOut(duration: 0.2).delay(Double(index) * 0.03),
                    value: mergedRoster.count)
            }
            recentActivitySection
        }
    }

    /// Row height: always the compact height — choice/multi prompts render
    /// numbered buttons ("1", "2", "3") that fit inline, with the full option
    /// text in each button's tooltip and the agent's title carrying context.
    private func rowHeight(for agent: AgentSnapshot) -> CGFloat {
        _ = agent
        return IslandMetrics.rowHeight
    }

    /// Inline approve/deny (or choice / multi-select) controls for a blocked
    /// agent row. Same logic the old queue cards used, rendered compactly in
    /// the row's trailing action cluster.
    @ViewBuilder
    private func inlineApprovalControls(agent: AgentSnapshot) -> some View {
        if let paneId = agent.paneId {
            let controls = agent.approval
            let resolving = eventManager.isResolving(paneId: paneId)
            if controls.isYesNo {
                approvalActionButton(
                    systemName: "checkmark.circle.fill", color: .green, help: "Approve",
                    disabled: resolving
                ) {
                    eventManager.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
                }
                approvalActionButton(
                    systemName: "xmark.circle.fill", color: .red, help: "Deny",
                    disabled: resolving
                ) {
                    eventManager.performAction(paneId: paneId) { $0.deny(paneId: paneId) }
                }
            } else if controls.isMulti {
                let labels = controls.displayedLabels()
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    let optionText =
                        controls.choices.indices.contains(index)
                        ? controls.choices[index] : "Option \(label)"
                    approvalActionButton(
                        label: Text(label),
                        color: queueSelections[paneId]?.contains(
                            IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                        ) == true ? .green : .white.opacity(0.6),
                        help: optionText,
                        disabled: false,
                        accessibilityLabel: optionText
                    ) {
                        queueSelections[paneId] = IslandMetrics.ApprovalControls.toggling(
                            queueSelections[paneId] ?? [], index: index)
                    }
                }
                let overflow = controls.overflowCount()
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
                approvalActionButton(
                    systemName: "checkmark.circle.fill", color: .green, help: "Submit",
                    disabled: resolving
                ) {
                    let numbers = IslandMetrics.ApprovalControls.selectionNumbers(
                        queueSelections[paneId] ?? [])
                    eventManager.performAction(paneId: paneId) {
                        $0.approveMulti(paneId: paneId, selections: numbers)
                    }
                    queueSelections.removeValue(forKey: paneId)
                }
            } else {
                let labels = controls.displayedLabels()
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    let optionText =
                        controls.choices.indices.contains(index)
                        ? controls.choices[index] : "Option \(label)"
                    approvalActionButton(
                        label: Text(label),
                        color: .white,
                        help: optionText,
                        disabled: resolving,
                        accessibilityLabel: optionText
                    ) {
                        eventManager.performAction(paneId: paneId) {
                            $0.approveChoice(
                                paneId: paneId,
                                choice: IslandMetrics.ApprovalControls.optionNumber(
                                    forIndex: index))
                        }
                    }
                }
                let overflow = controls.overflowCount()
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
                if controls.optionLabels.isEmpty {
                    approvalActionButton(
                        systemName: "checkmark.circle.fill", color: .green, help: "Approve",
                        disabled: resolving
                    ) {
                        eventManager.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
                    }
                }
            }
        }
    }

    private func agentRow(agent: AgentSnapshot) -> some View {
        let composing = composingPaneId == agent.paneId
        return HStack(spacing: 8) {
            // Item 2: pulsing dot for working agents. The pulse modifier is on
            // the dot itself (a same-color overlay composites to constant
            // color and is invisible), and only .progress/.started pulse —
            // blocked rows shouldn't read as "busy". `enabled` carries the
            // reduce-motion + kind gate so the modifier type-checks fast.
            Circle().fill(Color(hex: agent.kind.color)).frame(width: 6, height: 6)
                .modifier(
                    PulsingDotModifier(
                        enabled: (agent.kind == .progress || agent.kind == .started)
                            && !reduceMotion))
            if composing {
                TextField("Ask agent…", text: $promptText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($promptFocused)
                    .onSubmit { submitPrompt() }
                    .modifier(
                        EscapeCancelsModifier { cancelComposing() }
                    )
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08))
                    )
                    .layoutPriority(0)
                Button(action: submitPrompt) {
                    Image(systemName: "paperplane.fill").font(.system(size: 9))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .help("Send prompt (Return)")
                .layoutPriority(1)
                Button(action: cancelComposing) {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundColor(
                        .white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
                .layoutPriority(1)
            } else {
                Button(action: { beginComposing(agent) }) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                if let ctx = agent.projectContext {
                                    // Item 12: .tail truncation so the
                                    // differentiating suffix stays visible.
                                    Text(ctx.project)
                                        .font(
                                            .system(
                                                size: 10.5, weight: .semibold, design: .monospaced)
                                        )
                                        .foregroundColor(.white).lineLimit(1).truncationMode(
                                            .tail)
                                    if let branch = ctx.branch {
                                        Text(branch)
                                            .font(
                                                .system(
                                                    size: 8.5, weight: .medium, design: .monospaced)
                                            )
                                            .foregroundColor(.white.opacity(0.4))
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text(agent.source)
                                        .font(
                                            .system(
                                                size: 10.5, weight: .semibold, design: .monospaced)
                                        )
                                        .foregroundColor(.white).lineLimit(1).truncationMode(
                                            .tail)
                                }
                            }
                            HStack(spacing: 5) {
                                if agent.kind == .failed, let reason = agent.message {
                                    // Failure reason (rate_limit/auth/billing…)
                                    // must be visible, not just "Failed".
                                    Text(reason)
                                        .font(.system(size: 8.5, weight: .medium))
                                        .foregroundColor(Color(hex: AgentEventKind.failed.color))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                } else if let live = agent.title ?? agent.message,
                                    agent.kind.isOngoing
                                {
                                    Text(live)
                                        .font(.system(size: 8.5, weight: .medium))
                                        .foregroundColor(.white.opacity(0.75))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                } else {
                                    Text(agent.kind.label)
                                        .font(.system(size: 8.5, weight: .medium))
                                        .foregroundColor(.secondary).lineLimit(1)
                                }
                                if NotchHUDConfig.shared.showElapsedTime,
                                    let startedAt = agent.startedAt,
                                    agent.kind.isOngoing
                                {
                                    Text(IslandMetrics.elapsedLabel(since: startedAt, now: now))
                                        .font(
                                            .system(size: 8.5, weight: .medium, design: .monospaced)
                                        )
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                        }
                        Spacer(minLength: 4)
                        if let title = agent.title, !agent.kind.isOngoing {
                            Text(title)
                                .font(.system(size: 9, weight: .regular))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
                if let paneId = agent.paneId {
                    if agent.kind == .accessRequest || agent.kind == .waiting {
                        // Approval controls stay visible — those need attention.
                        inlineApprovalControls(agent: agent)
                            .layoutPriority(1)
                    }
                    // Focus/stop/peek are revealed on row hover to keep rows
                    // calm (BoringNotch HoverButton pattern). Always
                    // reachable: hover or tab already shows the row bg.
                    let rowHovered = hoveredRow == agent.id
                    Button(action: { focusAgentPane(paneId) }) {
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Focus pane")
                    .accessibilityLabel("Focus \(agent.source)")
                    .layoutPriority(1)
                    .opacity(rowHovered ? 1 : 0)
                    // Item 3: asymmetric hover timing.
                    .animation(
                        rowHovered
                            ? .easeOut(duration: 0.12)
                            : .easeOut(duration: 0.06),
                        value: rowHovered)
                    Button(action: {
                        eventManager.performAction(paneId: paneId) {
                            $0.stop(paneId: paneId)
                        }
                    }) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Stop (Ctrl-C)")
                    .accessibilityLabel("Stop \(agent.source)")
                    .layoutPriority(1)
                    .opacity(rowHovered ? 1 : 0)
                    .animation(
                        rowHovered
                            ? .easeOut(duration: 0.12)
                            : .easeOut(duration: 0.06),
                        value: rowHovered)
                    peekButton(agent: agent)
                        .layoutPriority(1)
                        .opacity(rowHovered ? 1 : 0)
                        .animation(
                            rowHovered
                                ? .easeOut(duration: 0.12)
                                : .easeOut(duration: 0.06),
                            value: rowHovered)
                } else if agent.kind == .accessRequest || agent.kind == .waiting {
                    // Standalone agent (opencode/Claude outside herdr): there
                    // is no pane to send keys to, so an Approve/Deny would be
                    // a silent phantom. The honest action is to raise the
                    // terminal where the prompt is waiting.
                    Button(action: {
                        _ = TerminalFocusser.focus(
                            preferredBundleID: NotchHUDConfig.shared.preferredTerminalBundleID)
                    }) {
                        Image(systemName: "terminal.fill").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Open terminal — answer there (no herdr pane)")
                    .accessibilityLabel("Open terminal for \(agent.source)")
                    .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: rowHeight(for: agent))
        .background(hoveredRow == agent.id ? Color.white.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .modifier(AgentRowAccessibility(agent: agent))
        .onHover { hovering in hoveredRow = hovering ? agent.id : nil }
        .contextMenu {
            if let paneId = agent.paneId {
                Button("Focus Pane") { focusAgentPane(paneId) }
            }
            if let title = agent.title {
                Button("Copy Title") { copyToClipboard(title) }
            }
            if let workspaceId = agent.workspaceId {
                Button("Open Workspace in Finder") {
                    openWorkspaceInFinder(workspaceId)
                }
            }
            Divider()
            if NotchHUDConfig.shared.mutedSources.contains(agent.source) {
                Button("Unmute \(agent.source)") {
                    NotchHUDConfig.shared.mutedSources.remove(agent.source)
                }
            } else {
                Button("Mute \(agent.source)") {
                    NotchHUDConfig.shared.mutedSources.insert(agent.source)
                }
            }
        }
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

    /// Route the focus button through `PaneFocusRouter` (plan 017 WI-3)
    /// when the active multiplexer is tmux/zellij AND the current adapter is
    /// that same kind: select the pane inside the mux, then raise the
    /// terminal app. herdr (raw pane-id passthrough) and every mismatch
    /// keep the adapter's own focus behavior unchanged.
    private func focusAgentPane(_ paneId: String) {
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
        withAnimation(morphAnimation) {
            isExpanded = expanded
        }
    }

    /// A file drag has entered the island window: expand and open the shelf
    /// tab so the drop target is visible and armed. Mirrors NotchDrop's
    /// drop-on-notch behavior.
    private func handleFileDragEntered() {
        NSLog("bantay-drop: handleFileDragEntered")
        showAttention = false
        showShelf = true
        expandTo(true)
    }

    /// Files were dropped onto the notch: land them on the shelf.
    private func handleFilesDropped(_ urls: [URL]) {
        NSLog("bantay-drop: handleFilesDropped count=%d", urls.count)
        // The ShelfStore owns persistence, copy-to-storage, and retention.
        ShelfStore.shared.add(urls: urls)
        // Show the shelf so the landed files are immediately visible.
        showAttention = false
        showShelf = true
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
        if IslandMetrics.shouldExpand(hovering: hovering, hasAgents: !eventManager.agents.isEmpty) {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(IslandMetrics.hoverCooldown * 1000)))
                guard !Task.isCancelled else { return }
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
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.15)) { pulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 0.25)) { pulse = false }
                }
            }
            if event.playSound && eventManager.shouldPlaySound(for: event) {
                playSound(for: event)
            }
            // Approvals landing while the island is hidden (snoozed / startup)
            // must never vanish silently — Notification Center fallback.
            // Effective visibility follows the same policy that drives
            // show/hide, so a snoozed or startup-hidden island counts as
            // hidden even if the window has not finished dismissing.
            let config = NotchHUDConfig.shared
            let islandVisible = IslandMetrics.VisibilityPolicy.shouldShow(
                islandEnabled: config.islandEnabled,
                snoozed: config.isSnoozed,
                hideAtStartup: config.hideAtStartup,
                didShowOnce: AppDelegate.didShowOnce,
                hasWork: eventManager.currentEvent != nil || !eventManager.agents.isEmpty,
                showWhenIdle: config.showIslandWhenIdle,
                forced: AppDelegate.isForcedVisible)
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
                    choices: event.choices)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) { showDetail = true }
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
            !eventManager.agents.contains(where: { $0.paneId == composingPaneId })
        {
            cancelComposing()
        }
    }

    private func beginComposing(_ agent: AgentSnapshot) {
        guard agent.paneId != nil else { return }
        composingPaneId = agent.paneId
        AppDelegate.composingPaneId = agent.paneId
        promptText = ""
        DispatchQueue.main.async { promptFocused = true }
    }

    private func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paneId = composingPaneId, !text.isEmpty {
            Task.detached { [adapter] in
                await adapter.agentPrompt(paneId: paneId, text: text)
            }
        }
        cancelComposing()
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
            "org.wezfurlong.wezterm", "com.ghostty.app", "dev.warp.Warp-Stable",
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        ]
        return terminals.contains(bundleID)
    }
}

/// Tactile scale-on-press feedback (make-interfaces-feel-better principle 12).
/// Applies a subtle scale(0.96) on press for buttons across the control plane.
struct ScalePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Item 2: breathing opacity cycle for working-agent status dots. The dot
/// pulses 0.4→1.0→0.4 over 1.5s, the universal "I'm busy" signifier. When
/// `enabled` is false (reduce-motion or a non-working kind) it's an identity
/// modifier, keeping the row's modifier type stable.
private struct PulsingDotModifier: ViewModifier {
    let enabled: Bool
    @State private var pulsing = false
    func body(content: Content) -> some View {
        if enabled {
            content
                .opacity(pulsing ? 0.35 : 1.0)
                .animation(
                    .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                    value: pulsing
                )
                .onAppear { pulsing = true }
        } else {
            content
        }
    }
}

/// Row accessibility in its own modifier so the (already heavy) agentRow
/// expression stays under the compiler's type-check budget.
private struct AgentRowAccessibility: ViewModifier {
    let agent: AgentSnapshot

    func body(content: Content) -> some View {
        content
            // `.contain` (not `.combine`) keeps the inline Approve/Deny/choice
            // buttons individually reachable by VoiceOver — a screen-reader
            // user must be able to act on approvals from the roster.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(agent.source), \(agent.kind.label)")
            .accessibilityValue(agent.title ?? agent.message ?? "")
            .accessibilityAction(named: "Approve") {
                if let paneId = agent.paneId,
                    agent.kind == .accessRequest || agent.kind == .waiting
                {
                    AgentEventManager.shared.performAction(paneId: paneId) {
                        $0.approve(paneId: paneId)
                    }
                }
            }
            .accessibilityAction(named: "Deny") {
                if let paneId = agent.paneId,
                    agent.kind == .accessRequest || agent.kind == .waiting
                {
                    AgentEventManager.shared.performAction(paneId: paneId) {
                        $0.deny(paneId: paneId)
                    }
                }
            }
    }
}
