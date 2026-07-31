import AppKit
import SwiftUI

struct NotchStatusView: View {
    @EnvironmentObject var eventManager: AgentEventManager
    @State private var opacity: Double = 0
    @State private var showDetail = false
    private let adapter = HerdrSocketAdapter()

    var body: some View {
        Group {
            if let event = eventManager.currentEvent {
                Button(action: {
                    if let paneId = event.paneId {
                        adapter.paneFocus(paneId: paneId)
                    }
                }) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: event.kind.color))
                            .frame(width: 7, height: 7)

                        Text(event.kind.label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)

                        if showDetail, let title = event.title {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .opacity(opacity)
                .onAppear {
                    if eventManager.currentEvent == nil {
                        AppDelegate.hide()
                    }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        opacity = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showDetail = true
                        }
                    }
                }
                .onChange(of: eventManager.currentEvent) {
                    if let event = eventManager.currentEvent {
                        AppDelegate.showAtNotch()
                        playSound(for: event)
                    } else {
                        AppDelegate.hide()
                    }
                }
                .onChange(of: event.id) {
                    showDetail = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showDetail = true
                        }
                    }
                }
            }
        }
        .frame(minWidth: 120, maxWidth: 420, minHeight: 28)
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
