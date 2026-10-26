import AppKit
import SwiftUI

/// Tactile press feedback (make-interfaces-feel-better principle 12).
/// Uses subtle opacity on press across the control plane without altering
/// geometry or invalidating ScrollViewResponder / AttributeGraph tables.
struct ScalePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct EdgeGlowView: View {
    let cornerRadius: CGFloat
    let width: CGFloat
    let height: CGFloat
    let reduceMotion: Bool
    @State private var glowPulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                Color(hex: IslandMetrics.glowBlockedColor).opacity(glowPulse ? 0.95 : 0.25),
                lineWidth: 2
            )
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: glowPulse
            )
            .onAppear {
                glowPulse = true
            }
    }
}

/// Item 2: breathing opacity cycle for working-agent status dots. The dot
/// pulses 0.4→1.0→0.4 over 1.5s, the universal "I'm busy" signifier. When
/// `enabled` is false (reduce-motion or a non-working kind) it's an identity
/// modifier, keeping the row's modifier type stable.
struct PulsingDotModifier: ViewModifier {
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
struct AgentRowAccessibility: ViewModifier {
    let agent: AgentSnapshot

    private var labelString: String {
        "\(agent.source), \(agent.kind.label)"
    }

    private var valueString: String {
        if let raw = agent.title ?? agent.message {
            return IslandMetrics.cleanHUDText(raw)
        }
        return ""
    }

    func body(content: Content) -> some View {
        content
            // `.contain` (not `.combine`) keeps the inline Approve/Deny/choice
            // buttons individually reachable by VoiceOver — a screen-reader
            // user must be able to act on approvals from the roster.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(labelString)
            .accessibilityValue(valueString)
            .accessibilityAction(named: "Approve") {
                if let paneId = IslandMetrics.actionablePaneId(
                    paneId: agent.paneId, source: agent.source),
                    agent.kind == .accessRequest || agent.kind == .waiting
                {
                    Task { @MainActor in
                        await AgentEventManager.shared.approve(paneId: paneId)
                    }
                }
            }
            .accessibilityAction(named: "Deny") {
                if let paneId = IslandMetrics.actionablePaneId(
                    paneId: agent.paneId, source: agent.source),
                    agent.kind == .accessRequest || agent.kind == .waiting
                {
                    Task { @MainActor in
                        await AgentEventManager.shared.deny(paneId: paneId)
                    }
                }
            }
    }
}

/// Tactile button for row actions featuring haptic feedback and micro-press physics.
struct TactileRowButton: View {
    let systemName: String
    var title: String? = nil
    var color: Color = .white
    var helpText: String = ""
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var foregroundColor: Color {
        isHovered ? .white : color.opacity(0.75)
    }

    private var horizontalPadding: CGFloat {
        title != nil ? 6 : 5
    }

    private var backgroundFill: Color {
        isHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.06)
    }

    private var strokeColor: Color {
        isHovered ? Color.white.opacity(0.25) : Color.white.opacity(0.08)
    }

    var body: some View {
        Button(action: {
            #if os(macOS)
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .generic, performanceTime: .now)
            #endif
            action()
        }) {
            HStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: 9, weight: .medium))
                }
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.93, reduceMotion: reduceMotion))
        .animation(
            isHovered ? InteractionMotion.hoverIn : InteractionMotion.hoverOut,
            value: isHovered
        )
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

/// Copies text string to the system general pasteboard.
@MainActor
func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// Standardized action button for approval queues and inline prompts with haptic feedback.
@MainActor
func approvalActionButton(
    systemName: String, color: Color, help: String, disabled: Bool = false,
    label: String? = nil, action: @escaping @MainActor () -> Void
) -> some View {
    Button(action: {
        #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
        action()
    }) {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(disabled ? color.opacity(0.3) : color)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(label ?? help)
    .disabled(disabled)
}

/// Standardized labeled action button for numbered choice queues with haptic feedback.
@MainActor
func approvalActionButton(
    label: Text, color: Color, help: String, disabled: Bool = false,
    accessibilityLabel: String? = nil, action: @escaping @MainActor () -> Void
) -> some View {
    Button(action: {
        #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
        action()
    }) {
        label
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundColor(disabled ? color.opacity(0.3) : color)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(accessibilityLabel ?? help)
    .disabled(disabled)
}

/// Cancels composing on Escape. `.onKeyPress` is macOS 14+; on older
/// systems the compose row's ✕ button remains the cancel affordance.
struct EscapeCancelsModifier: ViewModifier {
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
struct FocusEffectDisabledCompat: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

/// Global system HUD overlay (volume/brightness pills) rendered at the base of the island.
struct SystemHUDOverlayView: View {
    @ObservedObject private var systemHUDMonitor = SystemHUDMonitor.shared

    var body: some View {
        Group {
            if let hud = systemHUDMonitor.activeHUD {
                HStack(spacing: 8) {
                    Image(systemName: hud.type.iconName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.cyan)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.2))
                            Capsule()
                                .fill(Color.cyan)
                                .frame(width: geo.size.width * CGFloat(hud.type.percentage))
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// Tabs available in the expanded Notch HUD panel.
public enum ShelfTab: String, CaseIterable, Identifiable, Sendable {
    case agents = "Agents"
    case tasks = "Tasks"
    case attention = "Attention"
    case history = "History"
    case shelf = "Shelf"
    case media = "Media"
    public var id: String { rawValue }
}
