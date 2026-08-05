import AppKit
import SwiftUI
import UserNotifications

struct NotchStatusView: View {
    @EnvironmentObject var eventManager: AgentEventManager
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var opacity: Double = 0
    @State private var showDetail = false
    @State private var hoveredRow: String?
    @State private var composingPaneId: String?
    @State private var promptText = ""
    @State private var pulse = false
    @State private var selectedChoices: Set<Int> = []
    @State private var queueSelections: [String: Set<Int>] = [:]
    @State private var showWelcome = false
    @State private var glowPulse = false
    @State private var now = Date()
    @State private var showShelf = false
    @State private var showAttention = false
    /// Read-only mirror of `NotchHUDConfig.shared.panelPinned` so the header
    /// icon stays reactive; the config is the single behavioral source of
    /// truth (all logic reads it, and it is the only writer of the defaults).
    @AppStorage("panelPinned") private var panelPinned = false
    /// Live "peek" tail for a hovered/expanded agent — shows what the agent is
    /// actually doing inline (the core promise of the control plane).
    @State private var peekingPaneId: String?
    @State private var peekText: String = ""
    @State private var peekTask: Task<Void, Never>?
    /// Per-agent `git diff --shortstat` summary ("+12 −3"), the glanceable
    /// "did this agent actually do work" meter (Codex/Conductor pattern).
    /// Keyed by (id, cwd): standalone agents share `paneId == nil` so id alone
    /// collides, and a summary is only valid for the cwd it was computed in.
    @State private var diffStats: [IslandMetrics.DiffStatCacheKey: String] = [:]
    @State private var clipboardItems: [ClipboardItem] = []
    @State private var shelfFiles: [ShelfFile] = []
    @State private var lastChangeCount = NSPasteboard.general.changeCount
    @State private var legacyKeyMonitor: Any?
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @FocusState private var promptFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// keep it centered underneath it. Active events center the pill.
    private var islandOffsetX: CGFloat {
        guard !isExpanded, !hasTransientEvent else { return 0 }
        return IslandMetrics.dockOffset(
            side: NotchHUDConfig.shared.islandDockSide,
            notchWidth: AppDelegate.notchWidth,
            chipWidth: closedPillWidth)
    }

    private var islandHeight: CGFloat {
        if isExpanded {
            return IslandMetrics.expandedSize(
                topInset: chipTopOffset, agentCount: eventManager.agents.count,
                queueCount: approvalQueueAgents.count,
                shelfTabVisible: NotchHUDConfig.shared.showShelfTab,
                overflowCount: expandedQueueSplit.overflow
            ).height
        }
        return IslandMetrics.closedSize(topInset: chipTopOffset, notchWidth: islandWidth).height
    }

    private var contentHeight: CGFloat {
        IslandMetrics.contentHeight(
            isExpanded: isExpanded, topInset: chipTopOffset,
            agentCount: eventManager.agents.count, queueCount: approvalQueueAgents.count,
            shelfTabVisible: NotchHUDConfig.shared.showShelfTab,
            overflowCount: expandedQueueSplit.overflow)
    }

    /// Approval-queue split used for both layout height and rendering.
    private var expandedQueueSplit: (shown: Int, overflow: Int) {
        IslandMetrics.queueSplit(
            blockedCount: approvalQueueAgents.count,
            cap: NotchHUDConfig.shared.clampedExpandedQueueCap)
    }

    /// Content frame width: the split centered strip spans the whole window
    /// so details leak on both sides of the notch; everything else is the
    /// island width.
    private var contentFrameWidth: CGFloat {
        isCenteredIdle ? IslandMetrics.windowSize().width : islandWidth
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

    var body: some View {
        ZStack(alignment: .top) {
            islandBackground
            content
                .frame(width: contentFrameWidth, height: contentHeight, alignment: .top)
                .offset(y: chipTopOffset)
                .clipped()
        }
        .overlay(edgeGlow)
        .scaleEffect(activeHoverScale, anchor: .top)
        .frame(width: islandWidth + cornerRad * 2, height: islandHeight, alignment: .top)
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
            if isExpanded { eventManager.markRecentCompletionsSeen() }
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
        .onReceive(
            NotificationCenter.default.publisher(for: .notchHotkeyPressed)
        ) { _ in
            if isExpanded {
                expandTo(false)
            } else if !eventManager.agents.isEmpty {
                expandTo(true)
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
            eventManager.performAction(paneId: paneId) { $0.approve(paneId: paneId) }
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

    /// macOS 13 fallback for the single-key roster shortcuts: `.onKeyPress`
    /// is macOS 14+. Mirrors its scope (panel key, expanded, not composing).
    private func installLegacyKeyMonitor() {
        guard legacyKeyMonitor == nil else { return }
        legacyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === AppDelegate.window,
                isExpanded,
                composingPaneId == nil,
                NotchHUDConfig.shared.keyboardShortcuts,
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

    /// Compute a `git diff --shortstat` summary for the agent's cwd off the
    /// main actor and cache it by (id, cwd). Cheap (one Process); only fetches
    /// once per (id, cwd) so the row isn't recomputing every poll. Runs
    /// through the non-blocking `ProcessRunner` with a timeout so a git
    /// process in a huge/mounted repo can never hang the row. The composite
    /// key means an old-cwd task that lands late writes its own (id, cwd)
    /// slot — never the agent's current one — and the prune then drops it.
    private func fetchDiffStats(_ agent: AgentSnapshot) {
        guard let cwd = agent.cwd else { return }
        let key = IslandMetrics.DiffStatCacheKey(id: agent.id, cwd: cwd)
        guard diffStats[key] == nil else { return }
        Task.detached {
            let result = await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", cwd, "diff", "--shortstat"],
                timeout: 3.0)
            let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let summary = IslandMetrics.DiffStatCache.parseShortstat(raw) else { return }
            await MainActor.run {
                if self.diffStats[key] == nil {
                    self.diffStats[key] = summary
                }
                let liveKeys = Set(
                    self.eventManager.agents.compactMap { agent in
                        agent.cwd.map { IslandMetrics.DiffStatCacheKey(id: agent.id, cwd: $0) }
                    }
                )
                self.diffStats = IslandMetrics.DiffStatCache.prune(
                    self.diffStats, liveKeys: liveKeys)
            }
        }
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

    // MARK: - Island chrome

    private var islandBackground: some View {
        Rectangle()
            .fill(.black)
            .mask(islandMask)
            .frame(width: islandWidth + cornerRad * 2, height: islandHeight)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRad, style: .continuous)
                    .strokeBorder(.white.opacity(isExpanded ? 0.09 : 0.04), lineWidth: 1)
                    .frame(width: islandWidth, height: islandHeight)
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

    private func cornerCutout(topLeading: Bool) -> some View {
        ZStack(alignment: topLeading ? .topLeading : .topTrailing) {
            Rectangle()
                .fill(.black)
                .frame(width: cornerRad, height: cornerRad)
            Rectangle()
                .fill(.white)
                .clipShape(
                    topLeading
                        ? .rect(topLeadingRadius: cornerRad)
                        : .rect(topTrailingRadius: cornerRad)
                )
                .frame(
                    width: cornerRad + IslandMetrics.contentSpacing,
                    height: cornerRad + IslandMetrics.contentSpacing
                )
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            expandedList
        } else if let event = eventManager.currentEvent, let paneId = event.paneId,
            IslandMetrics.requiresApproval(event.kind.rawValue)
        {
            approvalPill(event: event, paneId: paneId)
        } else if let event = eventManager.currentEvent {
            closedPill(
                color: event.kind.color,
                label: event.kind.label,
                title: showDetail ? event.title : nil,
                action: {
                    if let paneId = event.paneId { adapter.paneFocus(paneId: paneId) }
                }
            )
            .onChange(of: event.id) { _ in
                showDetail = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.3)) { showDetail = true }
                }
            }
        } else if !eventManager.agents.isEmpty {
            if isCenteredIdle {
                centerIdleStrip
                    .onTapGesture { expandTo(true) }
            } else {
                agentStrip
                    .onTapGesture { expandTo(true) }
            }
        } else if isExpanded {
            expandedList
        } else {
            emptyBar
        }
    }

    private var emptyBar: some View {
        Rectangle().fill(.clear).frame(width: islandWidth, height: IslandMetrics.pillHeight)
    }

    private func closedPill(
        color: String, label: String, title: String?,
        dots: [AgentEventKind] = [], action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
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
            .frame(width: islandWidth, height: IslandMetrics.pillHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Idle (closed) live strip: per-agent chips beside the notch, in the style
    /// the user picked. Tap to expand the full roster.
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
        .frame(width: islandWidth, height: IslandMetrics.pillHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) { recentCompletionBadge }
    }

    /// Centered idle: the pill spans the notch (black bar behind it) and
    /// important details split to both sides — counts/usage on the left,
    /// live agent chips on the right.
    private var centerIdleStrip: some View {
        let agents = eventManager.agents
        let counts = IslandMetrics.agentCounts(kinds: agents.map(\.kind))
        let sideWidth = IslandMetrics.centeredSideWidth(
            windowWidth: IslandMetrics.windowSize().width,
            notchWidth: AppDelegate.notchWidth)
        let shown = IslandMetrics.idleShownChips(
            agentCount: agents.count,
            maxChips: NotchHUDConfig.shared.clampedIdleMaxChips)
        let overflow = max(agents.count - shown, 0)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if counts.needsInput > 0 {
                    Circle()
                        .fill(Color(hex: AgentEventKind.accessRequest.color))
                        .frame(width: 6, height: 6)
                } else {
                    Circle()
                        .fill(Color(hex: AgentEventKind.progress.color))
                        .frame(width: 6, height: 6)
                }
                Text("\(agents.count) agent\(agents.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if counts.needsInput > 0 {
                    Text("· \(counts.needsInput) need you")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.yellow)
                        .lineLimit(1)
                }
                if NotchHUDConfig.shared.showUsageGauge,
                    eventManager.usage.totalTokens > 0
                {
                    Text(UsageTracker.compactTokens(eventManager.usage.totalTokens))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: sideWidth, alignment: .trailing)
            .lineLimit(1)
            .allowsHitTesting(false)

            Spacer(minLength: 0)

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
            .frame(width: sideWidth, alignment: .leading)
        }
        .frame(
            width: IslandMetrics.windowSize().width, height: IslandMetrics.pillHeight,
            alignment: .center
        )
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
            ForEach(0..<choices.count, id: \.self) { index in
                approvalActionButton(
                    label: Text("\(index + 1)"),
                    color: .white,
                    help: choices[index],
                    disabled: resolving
                ) {
                    eventManager.performAction(paneId: paneId) {
                        $0.approveChoice(paneId: paneId, choice: index + 1)
                    }
                }
            }
            if choices.isEmpty {
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
                    color: selectedChoices.contains(index) ? .green : .white.opacity(0.6),
                    help: choices[index]
                ) {
                    if selectedChoices.contains(index) {
                        selectedChoices.remove(index)
                    } else {
                        selectedChoices.insert(index)
                    }
                }
            }
            approvalActionButton(
                systemName: "checkmark.circle.fill", color: .green, help: "Submit",
                disabled: resolving
            ) {
                let selections = selectedChoices.sorted().map { $0 + 1 }
                eventManager.performAction(paneId: paneId) {
                    $0.approveMulti(paneId: paneId, selections: selections)
                }
                selectedChoices.removeAll()
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
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
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
                .foregroundColor(disabled ? color.opacity(0.3) : color)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
        .disabled(disabled)
    }

    /// ▸ affordance that opens the full-log + diff preview overlay (plan 016
    /// 3a). One overlay at a time; the controller cancels any in-flight fetch
    /// when the overlay is dismissed.
    private func peekButton(agent: AgentSnapshot) -> some View {
        Button {
            PeekPanelController.shared.show(agent: agent, adapter: adapter)
        } label: {
            Text("▸")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Peek full log + diff preview")
        .accessibilityLabel("Peek log for \(agent.source)")
    }

    private var expandedList: some View {
        let counts = IslandMetrics.agentCounts(
            kinds: visibleAgents.map(\.kind))
        let queue = approvalQueueAgents
        let queueSplit = expandedQueueSplit
        return VStack(spacing: 0) {
            headerBar(counts: counts)

            if NotchHUDConfig.shared.showShelfTab {
                shelfTabBar
            }

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

            if showAttention {
                attentionContent
            } else if showShelf {
                shelfContent
            } else {
                queueAndRoster(queue: queue, queueSplit: queueSplit, counts: counts)
            }
        }
        .frame(width: islandWidth, height: contentHeight, alignment: .top)
    }

    @ViewBuilder
    private func queueAndRoster(
        queue: [AgentSnapshot],
        queueSplit: (shown: Int, overflow: Int),
        counts: IslandMetrics.AgentCounts
    ) -> some View {
        VStack(spacing: 0) {
            if NotchHUDConfig.shared.expandedShowQueue {
                ForEach(queue.prefix(queueSplit.shown)) { agent in
                    approvalQueueCard(agent: agent)
                }
                if queueSplit.overflow > 0 {
                    Text("+\(queueSplit.overflow) more waiting")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(height: 18)
                }
            }

            if visibleAgents.isEmpty {
                Text("No active agents")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandMetrics.rowHeight)
            }

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if NotchHUDConfig.shared.expandedGroupByState {
                        groupedAgentRows
                    } else {
                        flatAgentRows
                    }
                }
            }
            .frame(height: rosterScrollHeight)
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)
            footerBar(counts: counts, queueCount: queue.count)
        }
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
                if agent.kind == .accessRequest || agent.kind == .waiting,
                    agent.paneId != nil
                {
                    approvalQueueCard(agent: agent)
                } else {
                    agentRow(agent: agent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Roster scroll area: natural row height from the rendered roster
    /// (muted sources excluded), capped so header/tabs/footer always stay
    /// visible inside the island (scrolls when 6+ rows overflow).
    private var rosterScrollHeight: CGFloat {
        let chrome =
            IslandMetrics.headerHeight + IslandMetrics.footerHeight
            + (NotchHUDConfig.shared.showShelfTab
                ? IslandMetrics.shelfTabBarHeight + IslandMetrics.dividerHeight : 0)
        let available =
            IslandMetrics.maxExpandedHeight - chipTopOffset - chrome - IslandMetrics.contentSpacing
        return IslandMetrics.stableRosterHeight(
            agentCount: mergedRoster.count, availableHeight: available)
    }

    private var shelfTabBar: some View {
        HStack(spacing: 4) {
            shelfTabButton(title: "Agents", selected: !showShelf && !showAttention) {
                showShelf = false
                showAttention = false
            }
            if NotchHUDConfig.shared.attentionFilterEnabled {
                shelfTabButton(
                    title: "Attention", selected: showAttention
                ) {
                    showShelf = false
                    showAttention = true
                }
            }
            shelfTabButton(title: "Shelf", selected: showShelf) {
                showAttention = false
                showShelf = true
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
            Text(title)
                .font(.system(size: 9, weight: selected ? .semibold : .medium))
                .foregroundColor(selected ? .white : .white.opacity(0.5))
                .padding(.horizontal, 8)
                .frame(height: 16)
                .background(
                    selected ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var shelfContent: some View {
        VStack(spacing: 0) {
            if clipboardItems.isEmpty && shelfFiles.isEmpty {
                Text("Drop files here or copy text — it lands on the shelf.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandMetrics.rowHeight)
            }
            ForEach(shelfFiles) { file in
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill").font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                    Text(file.name)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(0)
                    Spacer(minLength: 4)
                    Button(action: { NSWorkspace.shared.open(file.url) }) {
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Open file")
                    .layoutPriority(1)
                    Button(action: { shelfFiles = ShelfFiles.removing(file.url, from: shelfFiles) })
                    {
                        Image(systemName: "xmark").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .layoutPriority(1)
                }
                .padding(.horizontal, 16)
                .frame(height: IslandMetrics.rowHeight)
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
                    .layoutPriority(1)
                }
                .padding(.horizontal, 16)
                .frame(height: IslandMetrics.rowHeight)
            }
            Spacer(minLength: 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let now = Date()
            let files = urls.map { ShelfFile(url: $0, createdAt: now) }
            shelfFiles = ShelfFiles.adding(
                files, to: shelfFiles,
                limit: NotchHUDConfig.shared.clampedShelfLimit)
            return true
        }
    }

    private func headerBar(counts: IslandMetrics.AgentCounts) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: AgentEventKind.idle.color)).frame(width: 7, height: 7)
            if counts.needsInput > 0 {
                Text("\(counts.needsInput) need you")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.yellow)
            }
            if counts.working > 0 {
                Text("\(counts.working) working")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            if counts.needsInput == 0 && counts.working == 0 {
                Text("Agents")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Spacer(minLength: 8)
            if let title = eventManager.currentEvent?.title {
                Text(title)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .trailing)
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
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(panelPinned ? "Unpin panel" : "Pin panel open")
            .accessibilityLabel(panelPinned ? "Unpin panel" : "Pin panel open")
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.headerHeight)
    }

    private func approvalQueueCard(agent: AgentSnapshot) -> some View {
        let controls = agent.approval
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: agent.kind.color)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.source)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(agent.title ?? agent.message ?? agent.kind.label)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
                Spacer(minLength: 4)
                if let paneId = agent.paneId {
                    queueCardActions(controls: controls, paneId: paneId, agentID: agent.id)
                        .layoutPriority(1)
                    approvalActionButton(
                        systemName: "terminal.fill", color: .white.opacity(0.55),
                        help: "Force focus terminal"
                    ) {
                        adapter.attachPane(paneId: paneId)
                        _ = TerminalFocusser.focus(
                            preferredBundleID: NotchHUDConfig.shared.preferredTerminalBundleID)
                    }
                    .layoutPriority(1)
                    approvalActionButton(
                        systemName: "arrow.clockwise", color: .white.opacity(0.55),
                        help: "Retry / re-check agent"
                    ) {
                        Task { await eventManager.pollHerdrAgents() }
                    }
                    .layoutPriority(1)
                    peekButton(agent: agent)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: IslandMetrics.queueCardHeight)
            if let paneId = agent.paneId, peekingPaneId == paneId, !peekText.isEmpty {
                Text(peekText)
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Latest output for \(agent.source)")
            }
        }
        .background(Color.white.opacity(0.05))
        .contentShape(Rectangle())
        .onHover { hovering in
            if let paneId = agent.paneId, hovering {
                fetchPeek(paneId: paneId)
            } else if peekingPaneId == agent.paneId {
                endPeek()
            }
        }
        .contextMenu {
            if let title = agent.title {
                Button("Copy prompt") { copyToClipboard(title) }
            }
            if let message = agent.message {
                Button("Copy message") { copyToClipboard(message) }
            }
        }
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

    @ViewBuilder
    private func queueCardActions(
        controls: IslandMetrics.ApprovalControls, paneId: String, agentID: String
    ) -> some View {
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
            let overflow = controls.overflowCount()
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                approvalActionButton(
                    label: Text(label),
                    color: queueSelections[agentID]?.contains(
                        IslandMetrics.ApprovalControls.optionNumber(forIndex: index)
                    ) == true ? .green : .white.opacity(0.6),
                    help: controls.choices[index]
                ) {
                    queueSelections[agentID] = IslandMetrics.ApprovalControls.toggling(
                        queueSelections[agentID] ?? [], index: index)
                }
            }
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
                    queueSelections[agentID] ?? [])
                eventManager.performAction(paneId: paneId) {
                    $0.approveMulti(paneId: paneId, selections: numbers)
                }
                queueSelections.removeValue(forKey: agentID)
            }
        } else {
            let labels = controls.displayedLabels()
            let overflow = controls.overflowCount()
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                approvalActionButton(
                    label: Text(label),
                    color: .white,
                    help: controls.choices[index],
                    disabled: resolving
                ) {
                    eventManager.performAction(paneId: paneId) {
                        $0.approveChoice(
                            paneId: paneId,
                            choice: IslandMetrics.ApprovalControls.optionNumber(
                                forIndex: index))
                    }
                }
            }
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
        }
    }

    private func sectionHeader(_ title: String, count: Int, color: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: color)).frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) agents")
    }

    private var flatAgentRows: some View {
        VStack(spacing: 0) {
            ForEach(mergedRoster) { agent in
                agentRow(agent: agent)
            }
        }
    }

    private func footerBar(counts: IslandMetrics.AgentCounts, queueCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(counts.total) agents")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            if counts.done > 0 {
                Text("· \(counts.done) done").foregroundColor(
                    Color(hex: AgentEventKind.completed.color)
                )
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            if counts.error > 0 {
                Text("· \(counts.error) failed").foregroundColor(
                    Color(hex: AgentEventKind.failed.color)
                )
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            Spacer(minLength: 8)
            usageGauge
                .layoutPriority(1)
            Text(adapter.kind.label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .layoutPriority(1)
            if queueCount > 0 {
                Text("\(queueCount) pending")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.footerHeight)
    }

    /// Compact token/cost gauge: budget fraction bar + totals.
    @ViewBuilder
    private var usageGauge: some View {
        let config = NotchHUDConfig.shared
        let usage = eventManager.usage
        if config.showUsageGauge, usage.totalTokens > 0 || usage.costUSD > 0 {
            let fraction = UsageTracker.fractionUsed(
                costUSD: usage.costUSD, budgetUSD: config.usageBudgetUSD)
            let color: Color =
                fraction >= 0.9
                ? Color(hex: "#ff6b6b")
                : fraction >= 0.7
                    ? Color(hex: "#ffe066")
                    : Color(hex: "#4ecdc4")
            HStack(spacing: 4) {
                if usage.costUSD > 0 {
                    Text(String(format: "$%.2f", usage.costUSD))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                }
                Text(UsageTracker.compactTokens(usage.totalTokens))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                if usage.totalTokens > 0,
                    let tokensPerMinute = eventManager.usageRate.tokensPerMinute
                {
                    let rateLevel = UsageTracker.rateLevel(
                        rate: tokensPerMinute, warn: config.usageRateWarnTokensPerMin)
                    let rateColor: Color =
                        rateLevel == .red
                        ? Color(hex: "#ff6b6b")
                        : rateLevel == .warn
                            ? Color(hex: "#ffe066")
                            : .white.opacity(0.55)
                    Text("· \(UsageTracker.compactTokens(Int(tokensPerMinute)))/min")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(rateColor)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(color)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(width: 36, height: 4)
            }
            .help(
                "Tokens \(usage.totalTokens) · budget $\(String(format: "%.0f", config.usageBudgetUSD))"
            )
        }
    }

    private func agentRow(agent: AgentSnapshot) -> some View {
        let composing = composingPaneId == agent.paneId
        return HStack(spacing: 8) {
            Circle().fill(Color(hex: agent.kind.color)).frame(width: 6, height: 6)
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
                                    Text(ctx.project)
                                        .font(
                                            .system(
                                                size: 10.5, weight: .semibold, design: .monospaced)
                                        )
                                        .foregroundColor(.white).lineLimit(1).truncationMode(
                                            .middle)
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
                                            .middle)
                                }
                                Text(agent.source)
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.45))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            HStack(spacing: 5) {
                                Text(agent.kind.label)
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundColor(.secondary).lineLimit(1)
                                if let cwd = agent.cwd,
                                    let diff = diffStats[
                                        IslandMetrics.DiffStatCacheKey(id: agent.id, cwd: cwd)]
                                {
                                    Text(diff)
                                        .font(
                                            .system(
                                                size: 8.5, weight: .semibold, design: .monospaced)
                                        )
                                        .foregroundColor(.white.opacity(0.6))
                                        .lineLimit(1)
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
                        if let title = agent.title {
                            Text(title)
                                .font(.system(size: 9, weight: .regular))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
                .onAppear { fetchDiffStats(agent) }
                .onChange(of: agent.cwd) { _ in
                    // No manual dict clear: the key change makes the old-cwd
                    // entry unreachable and the prune (on the next write)
                    // drops it. Clearing here would reintroduce the race.
                    fetchDiffStats(agent)
                }
                if let paneId = agent.paneId {
                    Button(action: { adapter.focusPane(paneId: paneId) }) {
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Focus pane")
                    .accessibilityLabel("Focus \(agent.source)")
                    .layoutPriority(1)
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
                    peekButton(agent: agent)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.rowHeight)
        .background(hoveredRow == agent.id ? Color.white.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.source), \(agent.kind.label)")
        .accessibilityValue(agent.title ?? agent.message ?? "")
        .onHover { hovering in hoveredRow = hovering ? agent.id : nil }
        .contextMenu {
            if let paneId = agent.paneId {
                Button("Focus Pane") { adapter.focusPane(paneId: paneId) }
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
        selectedChoices.removeAll()
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
                kind: event.kind)
            {
                postHiddenApprovalNotification(for: event)
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
        guard let sound = NSSound(named: event.kind.soundName) else { return }
        sound.volume = config.soundVolume
        sound.play()
    }

    /// Notification Center fallback for approvals that arrive while the
    /// island is hidden. Best-effort: delivery failures are logged, never
    /// silently dropped.
    private func postHiddenApprovalNotification(for event: AgentEvent) {
        let content = UNMutableNotificationContent()
        content.title = "\(event.source ?? "agent") needs approval"
        content.body = event.title ?? event.message ?? event.kind.label
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: event.identityKey, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppDelegate.dbg(
                    "notify: delivery failed for \(event.identityKey): \(error)")
            }
        }
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

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
