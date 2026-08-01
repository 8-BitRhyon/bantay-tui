import AppKit
import SwiftUI

struct NotchStatusView: View {
    @EnvironmentObject var eventManager: AgentEventManager
    @State private var isExpanded = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var opacity: Double = 0
    @State private var showDetail = false
    @State private var hoveredRow: String?
    private let adapter = HerdrSocketAdapter()

    private let pillHeight: CGFloat = 36
    private let expandedWidth: CGFloat = 320
    private let rowHeight: CGFloat = 26
    private let spacing: CGFloat = 10

    private var topInset: CGFloat { AppDelegate.topInset }

    private var islandWidth: CGFloat { isExpanded ? expandedWidth : 160 }
    private var islandHeight: CGFloat {
        if isExpanded {
            let content = 40 + CGFloat(eventManager.agents.count) * rowHeight + 10
            return min(topInset + content, 240)
        }
        return topInset + pillHeight
    }
    private var contentHeight: CGFloat {
        isExpanded ? islandHeight - topInset : pillHeight
    }
    private var islandCornerRadius: CGFloat { isExpanded ? 24 : 8 }
    private var morphAnimation: Animation { .smooth(duration: 0.42, extraBounce: 0) }

    private var isIdle: Bool {
        eventManager.currentEvent == nil && !eventManager.agents.isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            islandBackground

            content
                .frame(width: islandWidth, height: contentHeight, alignment: .top)
                .offset(y: topInset)
        }
        .frame(width: islandWidth + islandCornerRadius * 2, height: islandHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(opacity)
        .animation(morphAnimation, value: isExpanded)
        .animation(morphAnimation, value: eventManager.agents.count)
        .onAppear(perform: handleAppear)
        .onHover { hovering in
            handleHover(hovering)
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
            .shadow(color: .black.opacity(0.12), radius: 12)
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
        if let event = eventManager.currentEvent {
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
            .frame(width: 108, height: pillHeight)
    }

    private func closedPill(
        color: String,
        label: String,
        title: String?,
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

            ForEach(eventManager.agents) { agent in
                Button(action: {
                    if let paneId = agent.paneId {
                        adapter.paneFocus(paneId: paneId)
                    }
                }) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: agent.kind.color))
                            .frame(width: 6, height: 6)

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
                    .padding(.horizontal, 16)
                    .frame(height: rowHeight)
                    .background(
                        hoveredRow == agent.id ? Color.white.opacity(0.07) : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredRow = hovering ? agent.id : nil
                }
            }
        }
        .frame(width: islandWidth, height: contentHeight, alignment: .top)
    }

    // MARK: - Behavior

    private func handleAppear() {
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
        if let event = eventManager.currentEvent {
            AppDelegate.showAtNotch()
            if event.playSound {
                playSound(for: event)
            }
        }
    }

    private func handleAgentsChange() {
        AppDelegate.showAtNotch()
    }

    private func playSound(for event: AgentEvent) {
        let config = NotchHUDConfig.shared
        guard config.enableAgentAlerts else { return }
        guard let sound = NSSound(named: event.kind.soundName) else { return }
        sound.volume = config.soundVolume
        sound.play()
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
