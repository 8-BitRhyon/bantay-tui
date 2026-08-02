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
    @State private var showWelcome = false
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
        return hasTransientEvent ? full : min(full, IslandMetrics.idleChipWidth)
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
                topInset: chipTopOffset, agentCount: eventManager.agents.count
            ).height
            : IslandMetrics.closedSize(topInset: chipTopOffset, notchWidth: islandWidth).height
    }

    private var contentHeight: CGFloat {
        IslandMetrics.contentHeight(
            isExpanded: isExpanded, topInset: chipTopOffset,
            agentCount: eventManager.agents.count)
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
        .onChange(of: hasSeenOnboarding) { _, seen in
            if !seen { showWelcome = true }
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView()
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
            closedPill(
                color: AgentEventKind.idle.color,
                label: "Agents · \(eventManager.agents.count)",
                title: nil,
                dots: eventManager.agents.map(\.kind),
                action: { expandTo(true) }
            )
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: AgentEventKind.idle.color)).frame(width: 7, height: 7)
                Text("Active agents")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
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

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

            if eventManager.agents.isEmpty {
                Text("No active agents")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandMetrics.rowHeight)
            }

            ForEach(eventManager.agents) { agent in
                let composing = composingPaneId == agent.paneId
                HStack(spacing: 8) {
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
                            Button(action: { adapter.paneFocus(paneId: paneId) }) {
                                Image(systemName: "arrow.up.right").font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Focus pane")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: IslandMetrics.rowHeight)
                .background(hoveredRow == agent.id ? Color.white.opacity(0.07) : Color.clear)
                .contentShape(Rectangle())
                .onHover { hovering in hoveredRow = hovering ? agent.id : nil }
            }
        }
        .frame(width: islandWidth, height: contentHeight, alignment: .top)
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
