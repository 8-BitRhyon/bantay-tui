import SwiftUI

/// Micro-animated native SwiftUI view for the Notch Pet Companion.
public struct MascotView: View {
    public let archetype: MascotArchetype
    public let state: MascotState
    public let size: CGFloat

    @State private var animate = false

    public init(
        archetype: MascotArchetype = .bantayDog, state: MascotState = .idle, size: CGFloat = 18
    ) {
        self.archetype = archetype
        self.state = state
        self.size = size
    }

    public var body: some View {
        ZStack {
            mainIcon
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(colorForState)
                .scaleEffect(scaleForState)
                .offset(x: offsetXForState, y: offsetYForState)
                .rotationEffect(rotationForState)

            // Wearable accessory overlay
            accessoryOverlay

            // State specific badges / overlays
            overlayBadge
        }
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(animationForState) {
                    animate = true
                }
            }
        }
    }

    private var scaleForState: CGFloat {
        guard animate else { return 1.0 }
        switch state {
        case .working: return 1.08
        case .needsAttention: return 1.22
        case .completed: return 1.15
        case .idle: return 1.02
        case .quotaLow: return 1.0
        }
    }

    private var offsetXForState: CGFloat {
        guard animate else { return 0 }
        switch state {
        case .quotaLow: return -1.5
        default: return 0
        }
    }

    private var offsetYForState: CGFloat {
        guard animate else { return 0 }
        switch state {
        case .idle: return -1.5
        case .working: return -1.0
        case .needsAttention: return -3.0
        case .completed: return -2.0
        default: return 0
        }
    }

    private var rotationForState: Angle {
        guard animate else { return .degrees(0) }
        switch state {
        case .completed: return .degrees(360)
        case .needsAttention: return .degrees(-6)
        default: return .degrees(0)
        }
    }

    private var animationForState: Animation {
        switch state {
        case .idle:
            return .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
        case .working:
            return .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
        case .needsAttention:
            return .spring(response: 0.2, dampingFraction: 0.35).repeatForever(autoreverses: true)
        case .completed:
            return .spring(response: 0.6, dampingFraction: 0.6)
        case .quotaLow:
            return .easeInOut(duration: 0.15).repeatForever(autoreverses: true)
        }
    }

    @ViewBuilder
    private var mainIcon: some View {
        switch archetype {
        case .bantayDog:
            Image(systemName: state == .idle ? "pawprint.fill" : "dog.fill")
        case .aiCeo:
            Image(systemName: state == .working ? "laptopcomputer" : "briefcase.fill")
        case .cyberCat:
            Image(systemName: state == .idle ? "cat" : "cat.fill")
        case .roboBuddy:
            Image(systemName: state == .working ? "cpu.fill" : "gearshape.fill")
        case .codeWizard:
            Image(systemName: state == .working ? "wand.and.stars" : "sparkles")
        case .coffeeDev:
            Image(systemName: state == .working ? "cup.and.saucer.fill" : "mug.fill")
        case .gitDragon:
            Image(systemName: state == .working ? "flame.fill" : "lizard.fill")
        }
    }

    @ViewBuilder
    private var accessoryOverlay: some View {
        let acc = NotchHUDConfig.shared.equippedAccessory
        if acc != .none {
            Image(systemName: acc.iconName)
                .font(.system(size: max(6, size * 0.45), weight: .bold))
                .foregroundColor(.yellow)
                .offset(x: -size * 0.35, y: -size * 0.45)
                .shadow(color: .black.opacity(0.5), radius: 1)
        }
    }

    @ViewBuilder
    private var overlayBadge: some View {
        switch state {
        case .idle:
            Text("z")
                .font(.system(size: max(8, size * 0.45), weight: .bold, design: .monospaced))
                .foregroundColor(BantayTheme.textTertiary)
                .offset(x: size * 0.5, y: -size * 0.4)
                .opacity(animate ? 0.9 : 0.3)
                .scaleEffect(animate ? 1.1 : 0.8)
        case .working:
            Circle()
                .fill(BantayTheme.statusWorking)
                .frame(width: 4, height: 4)
                .offset(x: size * 0.45, y: size * 0.35)
        case .needsAttention:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: max(8, size * 0.5)))
                .foregroundColor(BantayTheme.statusAttention)
                .offset(x: size * 0.45, y: -size * 0.35)
        case .completed:
            Image(systemName: "sparkles")
                .font(.system(size: max(8, size * 0.5)))
                .foregroundColor(BantayTheme.statusCompleted)
                .offset(x: size * 0.45, y: -size * 0.35)
        case .quotaLow:
            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                .font(.system(size: max(8, size * 0.5)))
                .foregroundColor(BantayTheme.statusQuota)
                .offset(x: size * 0.45, y: -size * 0.35)
        }
    }

    private var colorForState: Color {
        BantayTheme.color(for: state)
    }
}
