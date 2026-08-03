import AppKit
import SwiftUI

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
    @State private var clipboardItems: [ClipboardItem] = []
    @State private var shelfFiles: [ShelfFile] = []
    @State private var lastChangeCount = NSPasteboard.general.changeCount
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

    private var closedPillWidth: CGFloat {
        let full = min(AppDelegate.notchWidth, IslandMetrics.expandedWidth)
        guard !hasTransientEvent else { return full }
        let config = NotchHUDConfig.shared
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
            width = min(width, max(clearance, IslandMetrics.idleChipWidth))
        }
        return width
    }

    private var islandWidth: CGFloat {
        isExpanded
            ? IslandMetrics.expandedWidth
            : closedPillWidth
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
        isExpanded
            ? IslandMetrics.expandedSize(
                topInset: chipTopOffset, agentCount: eventManager.agents.count,
                queueCount: approvalQueueAgents.count
            ).height
            : IslandMetrics.closedSize(topInset: chipTopOffset, notchWidth: islandWidth).height
    }

    private var contentHeight: CGFloat {
        IslandMetrics.contentHeight(
            isExpanded: isExpanded, topInset: chipTopOffset,
            agentCount: eventManager.agents.count, queueCount: approvalQueueAgents.count)
    }

    /// Agents currently blocked on an approval — pinned at the top of the
    /// expanded control plane.
    private var approvalQueueAgents: [AgentSnapshot] {
        eventManager.agents.filter {
            $0.kind == .accessRequest || $0.kind == .waiting
        }
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
                .frame(width: islandWidth, height: contentHeight, alignment: .top)
                .offset(y: chipTopOffset)
        }
        .overlay(edgeGlow)
        .scaleEffect(activeHoverScale, anchor: .top)
        .frame(width: islandWidth + cornerRad * 2, height: islandHeight, alignment: .top)
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
        .animation(morphAnimation, value: eventManager.agents.count)
        .onAppear(perform: handleAppear)
        .onChange(of: isExpanded) {
            if !isExpanded { cancelComposing() }
            eventManager.setActive(isExpanded)
        }
        .onChange(of: eventManager.currentEvent) { handleEventChange() }
        .onChange(of: eventManager.agents) { handleAgentsChange() }
        .onReceive(
            NotificationCenter.default.publisher(for: .notchVisibilityChanged)
        ) { _ in
            updateIslandVisibility()
        }
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { date in
            now = date
            pollClipboard(at: date)
        }
        .onChange(of: hasSeenOnboarding) { _, seen in
            if !seen { showWelcome = true }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            guard let char = press.characters.first,
                let shortcut = IslandMetrics.shortcutKey(for: char)
            else {
                return .ignored
            }
            handleShortcut(shortcut)
            return .handled
        }
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
            let agent = approvalQueueAgents.first,
            let paneId = agent.paneId
        else {
            return
        }
        switch shortcut {
        case .approve:
            adapter.approve(paneId: paneId)
        case .deny:
            adapter.deny(paneId: paneId)
        case .option(let number):
            if agent.approval.isMulti {
                queueSelections[paneId] = IslandMetrics.ApprovalControls.toggling(
                    queueSelections[paneId] ?? [], index: number - 1)
            } else {
                adapter.approveChoice(paneId: paneId, choice: number)
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
            .onChange(of: event.id) {
                showDetail = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.3)) { showDetail = true }
                }
            }
        } else if !eventManager.agents.isEmpty {
            agentStrip
                .onTapGesture { expandTo(true) }
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
        let maxChips = NotchHUDConfig.shared.clampedIdleMaxChips
        let shown = IslandMetrics.idleShownChips(agentCount: agents.count, maxChips: maxChips)
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
        switch variance {
        case .yesNo:
            approvalActionButton(
                systemName: "checkmark.circle.fill", color: .green, help: "Approve"
            ) {
                adapter.approve(paneId: paneId)
            }
            approvalActionButton(systemName: "xmark.circle.fill", color: .red, help: "Deny") {
                adapter.deny(paneId: paneId)
            }
        case .choices:
            ForEach(0..<choices.count, id: \.self) { index in
                approvalActionButton(
                    label: Text("\(index + 1)"),
                    color: .white,
                    help: choices[index]
                ) {
                    adapter.approveChoice(paneId: paneId, choice: index + 1)
                }
            }
            if choices.isEmpty {
                approvalActionButton(
                    systemName: "checkmark.circle.fill", color: .green, help: "Approve"
                ) {
                    adapter.approve(paneId: paneId)
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
                systemName: "checkmark.circle.fill", color: .green, help: "Submit"
            ) {
                let selections = selectedChoices.sorted().map { $0 + 1 }
                adapter.approveMulti(paneId: paneId, selections: selections)
                selectedChoices.removeAll()
            }
        }
    }

    private func approvalActionButton(
        systemName: String, color: Color, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func approvalActionButton(
        label: Text, color: Color, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var expandedList: some View {
        let counts = IslandMetrics.agentCounts(
            kinds: eventManager.agents.map(\.kind))
        let queue = approvalQueueAgents
        let queueSplit = IslandMetrics.queueSplit(
            blockedCount: queue.count,
            cap: NotchHUDConfig.shared.clampedExpandedQueueCap)
        return VStack(spacing: 0) {
            headerBar(counts: counts)

            if NotchHUDConfig.shared.showShelfTab {
                shelfTabBar
            }

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

            if showShelf {
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

            if eventManager.agents.isEmpty {
                Text("No active agents")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandMetrics.rowHeight)
            }

            if NotchHUDConfig.shared.expandedGroupByState {
                groupedAgentRows
            } else {
                flatAgentRows
            }

            Spacer(minLength: 0)
            footerBar(counts: counts, queueCount: queue.count)
        }
    }

    private var shelfTabBar: some View {
        HStack(spacing: 4) {
            shelfTabButton(title: "Agents", selected: !showShelf) { showShelf = false }
            shelfTabButton(title: "Shelf", selected: showShelf) { showShelf = true }
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
                    Spacer(minLength: 8)
                    Button(action: { NSWorkspace.shared.open(file.url) }) {
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Open file")
                    Button(action: { shelfFiles = ShelfFiles.removing(file.url, from: shelfFiles) })
                    {
                        Image(systemName: "xmark").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
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
                    Spacer(minLength: 8)
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
            }
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.headerHeight)
    }

    private func approvalQueueCard(agent: AgentSnapshot) -> some View {
        let controls = agent.approval
        return HStack(spacing: 8) {
            Circle().fill(Color(hex: agent.kind.color)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.source)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(agent.title ?? agent.message ?? agent.kind.label)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let paneId = agent.paneId {
                queueCardActions(controls: controls, paneId: paneId, agentID: agent.id)
                approvalActionButton(
                    systemName: "terminal.fill", color: .white.opacity(0.55),
                    help: "Force focus terminal"
                ) {
                    adapter.attachPane(paneId: paneId)
                }
                approvalActionButton(
                    systemName: "arrow.clockwise", color: .white.opacity(0.55),
                    help: "Retry / re-check agent"
                ) {
                    Task { await eventManager.pollHerdrAgents() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.queueCardHeight)
        .background(Color.white.opacity(0.05))
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
        if controls.isYesNo {
            approvalActionButton(
                systemName: "checkmark.circle.fill", color: .green, help: "Approve"
            ) {
                adapter.approve(paneId: paneId)
            }
            approvalActionButton(systemName: "xmark.circle.fill", color: .red, help: "Deny") {
                adapter.deny(paneId: paneId)
            }
        } else if controls.isMulti {
            ForEach(Array(controls.optionLabels.enumerated()), id: \.offset) { index, label in
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
            approvalActionButton(
                systemName: "checkmark.circle.fill", color: .green, help: "Submit"
            ) {
                let numbers = IslandMetrics.ApprovalControls.selectionNumbers(
                    queueSelections[agentID] ?? [])
                adapter.approveMulti(paneId: paneId, selections: numbers)
                queueSelections.removeValue(forKey: agentID)
            }
        } else {
            ForEach(Array(controls.optionLabels.enumerated()), id: \.offset) { index, label in
                approvalActionButton(
                    label: Text(label),
                    color: .white,
                    help: controls.choices[index]
                ) {
                    adapter.approveChoice(
                        paneId: paneId,
                        choice: IslandMetrics.ApprovalControls.optionNumber(forIndex: index))
                }
            }
            if controls.optionLabels.isEmpty {
                approvalActionButton(
                    systemName: "checkmark.circle.fill", color: .green, help: "Approve"
                ) {
                    adapter.approve(paneId: paneId)
                }
            }
        }
    }

    private var groupedAgentRows: some View {
        let grouped = Dictionary(grouping: eventManager.agents) { agent in
            IslandMetrics.expandedGroupRank(agent.kind)
        }
        return VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { rank in
                let rows = grouped[rank] ?? []
                if !rows.isEmpty {
                    ForEach(rows) { agent in
                        agentRow(agent: agent)
                    }
                }
            }
        }
    }

    private var flatAgentRows: some View {
        VStack(spacing: 0) {
            ForEach(eventManager.agents) { agent in
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
            Text(adapter.kind.label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            if queueCount > 0 {
                Text("\(queueCount) pending")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.yellow)
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
                    .onKeyPress(.escape) {
                        cancelComposing()
                        return .handled
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08)))
                Button(action: submitPrompt) {
                    Image(systemName: "paperplane.fill").font(.system(size: 9))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .help("Send prompt (Return)")
                Button(action: cancelComposing) {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundColor(
                        .white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
            } else {
                Button(action: { beginComposing(agent) }) {
                    HStack(spacing: 8) {
                        Text(agent.source)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white).lineLimit(1)
                        Text(agent.kind.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary).lineLimit(1)
                        if NotchHUDConfig.shared.showElapsedTime,
                            let startedAt = agent.startedAt,
                            agent.kind.isOngoing
                        {
                            Text(IslandMetrics.elapsedLabel(since: startedAt, now: now))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        Spacer(minLength: 8)
                        if let title = agent.title {
                            Text(title)
                                .font(.system(size: 9, weight: .regular))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let paneId = agent.paneId {
                    Button(action: { adapter.focusPane(paneId: paneId) }) {
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Focus pane")
                    Button(action: { adapter.stop(paneId: paneId) }) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Stop (Ctrl-C)")
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: IslandMetrics.rowHeight)
        .background(hoveredRow == agent.id ? Color.white.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in hoveredRow = hovering ? agent.id : nil }
    }

    // MARK: - Behavior

    private func handleAppear() {
        if AppDelegate.pendingWelcome {
            AppDelegate.pendingWelcome = false
            showWelcome = true
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
        withAnimation(morphAnimation) { isExpanded = expanded }
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
            isExpanded: isExpanded, isComposing: composingPaneId != nil)
        {
            expandTo(false)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) { showDetail = true }
            }
        }
    }

    private func updateIslandVisibility() {
        let config = NotchHUDConfig.shared
        let hasWork = eventManager.currentEvent != nil || !eventManager.agents.isEmpty
        let hiddenAtStart =
            config.hideAtStartup && !AppDelegate.didShowOnce
            && eventManager.currentEvent?.kind != .accessRequest
        let shouldShow = config.islandEnabled && !config.isSnoozed && hasWork && !hiddenAtStart
        let visible = AppDelegate.window?.isVisible ?? false
        if shouldShow != visible {
            AppDelegate.dbg(
                "visibility: \(shouldShow ? "SHOW" : "HIDE") enabled=\(config.islandEnabled) snoozed=\(config.isSnoozed) hasWork=\(hasWork) hiddenAtStart=\(hiddenAtStart) cur=\(eventManager.currentEvent?.kind.rawValue ?? "nil") agents=\(eventManager.agents.count)"
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
        promptText = ""
        DispatchQueue.main.async { promptFocused = true }
    }

    private func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paneId = composingPaneId, !text.isEmpty {
            adapter.agentPrompt(paneId: paneId, text: text)
        }
        cancelComposing()
    }

    private func cancelComposing() {
        composingPaneId = nil
        promptText = ""
        promptFocused = false
    }

    private func playSound(for event: AgentEvent) {
        let config = NotchHUDConfig.shared
        guard config.enableAgentAlerts else { return }
        guard !(config.muteInTerminal && isTerminalFocused()) else { return }
        guard let sound = NSSound(named: event.kind.soundName) else { return }
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
