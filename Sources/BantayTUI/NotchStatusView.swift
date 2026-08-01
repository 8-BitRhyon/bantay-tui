import AppKit
import SwiftUI

struct NotchStatusView: View {
    @EnvironmentObject var eventManager: AgentEventManager
    @State private var isExpanded = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var opacity: Double = 0
    @State private var showDetail = false
    @State private var hoveredRow: String?
    @State private var composingPaneId: String?
    @State private var promptText = ""
    @State private var pulse = false
    @FocusState private var promptFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let adapter = HerdrSocketAdapter()

    private let pillHeight: CGFloat = 36
    private let expandedWidth: CGFloat = 456
    private let rowHeight: CGFloat = 26
    private let spacing: CGFloat = 10

    private var topInset: CGFloat { AppDelegate.topInset }

    private var islandWidth: CGFloat { isExpanded ? expandedWidth : AppDelegate.notchWidth }
    private var islandHeight: CGFloat {
        isExpanded
            ? topInset + 40 + CGFloat(eventManager.agents.count) * rowHeight + 10
            : topInset + pillHeight
    }
    private var contentHeight: CGFloat {
        isExpanded ? islandHeight - topInset : pillHeight
    }
    private var neededWindowHeight: CGFloat {
        min(islandHeight, 560)
    }
    private var neededWindowSize: NSSize {
        NSSize(width: islandWidth + islandCornerRadius * 2, height: neededWindowHeight)
    }
    private var islandCornerRadius: CGFloat { isExpanded ? 24 : 8 }
    private var morphAnimation: Animation {
        reduceMotion ? .linear(duration: 0.1) : .smooth(duration: 0.42, extraBounce: 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            islandBackground

            content
                .frame(width: islandWidth, height: contentHeight, alignment: .top)
                .offset(y: topInset)
        }
        .scaleEffect(pulse ? 1.03 : 1, anchor: .top)
        .frame(width: islandWidth + islandCornerRadius * 2, height: islandHeight, alignment: .top)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            AppDelegate.resizeIsland(size: size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(opacity)
        .animation(morphAnimation, value: isExpanded)
        .animation(morphAnimation, value: eventManager.agents.count)
        .onAppear(perform: handleAppear)
        .onHover { hovering in
            eventManager.setActive(hovering)
            handleHover(hovering)
        }
        .onChange(of: isExpanded) {
            if !isExpanded {
                cancelComposing()
            }
            eventManager.setActive(isExpanded)
        }
        .onChange(of: eventManager.currentEvent) {
            handleEventChange()
        }
        .onChange(of: eventManager.agents) {
            handleAgentsChange()
        }
    }

    // MARK: - Notchly-style island chrome

    private var islandBackground: some View {
        Rectangle()
            .fill(.black)
            .mask(islandMask)
            .frame(width: islandWidth + islandCornerRadius * 2, height: islandHeight)
            .overlay {
                RoundedRectangle(cornerRadius: islandCornerRadius, style: .continuous)
                    .strokeBorder(
                        .white.opacity(isExpanded ? 0.09 : 0.04),
                        lineWidth: 1
                    )
                    .frame(width: islandWidth, height: islandHeight)
            }
    }

    private var islandMask: some View {
        Rectangle()
            .fill(.black)
            .frame(width: islandWidth, height: islandHeight)
            .clipShape(
                .rect(
                    bottomLeadingRadius: islandCornerRadius,
                    bottomTrailingRadius: islandCornerRadius)
            )
            .overlay(alignment: .topTrailing) {
                cornerCutout(topLeading: true)
                    .offset(x: islandCornerRadius + spacing - 0.5, y: -0.5)
            }
            .overlay(alignment: .topLeading) {
                cornerCutout(topLeading: false)
                    .offset(x: -islandCornerRadius - spacing + 0.5, y: -0.5)
            }
    }

    private func cornerCutout(topLeading: Bool) -> some View {
        ZStack(alignment: topLeading ? .topLeading : .topTrailing) {
            Rectangle()
                .fill(.black)
                .frame(width: islandCornerRadius, height: islandCornerRadius)

            Rectangle()
                .fill(.white)
                .clipShape(
                    topLeading
                        ? .rect(topLeadingRadius: islandCornerRadius)
                        : .rect(topTrailingRadius: islandCornerRadius)
                )
                .frame(
                    width: islandCornerRadius + spacing,
                    height: islandCornerRadius + spacing
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
        } else if let event = eventManager.currentEvent {
            closedPill(
                color: event.kind.color,
                label: event.kind.label,
                title: showDetail ? event.title : nil,
                action: {
                    if let paneId = event.paneId {
                        adapter.paneFocus(paneId: paneId)
                    }
                }
            )
            .onChange(of: event.id) {
                showDetail = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showDetail = true
                    }
                }
            }
        } else if !eventManager.agents.isEmpty {
            if isExpanded {
                expandedList
            } else {
                closedPill(
                    color: AgentEventKind.idle.color,
                    label: "Agents · \(eventManager.agents.count)",
                    title: nil,
                    dots: eventManager.agents.map(\.kind),
                    action: {
                        withAnimation(morphAnimation) {
                            isExpanded = true
                        }
                    })
            }
        } else if isExpanded {
            expandedList
        } else {
            emptyBar
        }
    }

    private var emptyBar: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: islandWidth, height: pillHeight)
    }

    private func closedPill(
        color: String,
        label: String,
        title: String?,
        dots: [AgentEventKind] = [],
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: color))
                    .frame(width: 7, height: 7)

                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)

                if let title {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !dots.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(dots.prefix(5).enumerated()), id: \.offset) { _, kind in
                            Circle()
                                .fill(Color(hex: kind.color))
                                .frame(width: 4, height: 4)
                        }
                        if dots.count > 5 {
                            Text("+\(dots.count - 5)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
            }
            .frame(width: islandWidth, height: pillHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expandedList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: AgentEventKind.idle.color))
                    .frame(width: 7, height: 7)

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
            .frame(height: 40)

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)

            if eventManager.agents.isEmpty {
                Text("No active agents")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight)
            }

            ForEach(eventManager.agents) { agent in
                let composing = composingPaneId == agent.paneId
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: agent.kind.color))
                        .frame(width: 6, height: 6)

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
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(.white.opacity(0.08))
                            )

                        Button(action: submitPrompt) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Send prompt (Return)")

                        Button(action: cancelComposing) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel (Esc)")
                    } else {
                        Button(action: { beginComposing(agent) }) {
                            HStack(spacing: 8) {
                                Text(agent.source)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .lineLimit(1)

                                Text(agent.kind.label)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)

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
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Focus pane")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: rowHeight)
                .background(
                    hoveredRow == agent.id ? Color.white.opacity(0.07) : Color.clear
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveredRow = hovering ? agent.id : nil
                }
            }
        }
        .frame(width: islandWidth, height: contentHeight, alignment: .top)
    }

    // MARK: - Behavior

    private func handleAppear() {
        DispatchQueue.main.async {
            AppDelegate.resizeIsland(size: neededWindowSize)
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            opacity = 1
        }
        if eventManager.currentEvent != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showDetail = true
                }
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(hovering ? 120 : 150))
            guard !Task.isCancelled else { return }
            withAnimation(morphAnimation) {
                isExpanded = hovering && !eventManager.agents.isEmpty
            }
        }
    }

    private func handleEventChange() {
        eventManager.setActive(eventManager.currentEvent != nil)
        if let event = eventManager.currentEvent {
            AppDelegate.showAtNotch()
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.15)) {
                    pulse = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        pulse = false
                    }
                }
            }
            if event.playSound && eventManager.shouldPlaySound(for: event) {
                playSound(for: event)
            }
        }
    }

    private func handleAgentsChange() {
        AppDelegate.showAtNotch()
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
        DispatchQueue.main.async {
            promptFocused = true
        }
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
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "io.alacritty",
            "org.wezfurlong.wezterm",
            "com.ghostty.app",
            "dev.warp.Warp-Stable",
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
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
