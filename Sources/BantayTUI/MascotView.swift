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
                .scaleEffect(
                    (state == .working || state == .needsAttention) && animate ? 1.12 : 1.0
                )
                .offset(y: (state == .working || state == .needsAttention) && animate ? -1.5 : 0)

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

    private var animationForState: Animation {
        switch state {
        case .idle:
            return .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
        case .working:
            return .easeInOut(duration: 0.4).repeatForever(autoreverses: true)
        case .needsAttention:
            return .spring(response: 0.25, dampingFraction: 0.4).repeatForever(autoreverses: true)
        default:
            return .default
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
        }
    }

    @ViewBuilder
    private var overlayBadge: some View {
        switch state {
        case .idle:
            Text("z")
                .font(.system(size: max(8, size * 0.45), weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .offset(x: size * 0.5, y: -size * 0.4)
                .opacity(animate ? 0.9 : 0.3)
                .scaleEffect(animate ? 1.1 : 0.8)
        case .working:
            Circle()
                .fill(Color.green)
                .frame(width: 4, height: 4)
                .offset(x: size * 0.45, y: size * 0.35)
        case .needsAttention:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: max(8, size * 0.5)))
                .foregroundColor(.yellow)
                .offset(x: size * 0.45, y: -size * 0.35)
        case .completed:
            Image(systemName: "sparkles")
                .font(.system(size: max(8, size * 0.5)))
                .foregroundColor(.cyan)
                .offset(x: size * 0.45, y: -size * 0.35)
        case .quotaLow:
            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                .font(.system(size: max(8, size * 0.5)))
                .foregroundColor(.orange)
                .offset(x: size * 0.45, y: -size * 0.35)
        }
    }

    private var colorForState: Color {
        switch state {
        case .idle:
            return .white.opacity(0.7)
        case .working:
            return .white
        case .needsAttention:
            return .yellow
        case .completed:
            return Color(hex: "30D158")
        case .quotaLow:
            return Color(hex: "FF9F0A")
        }
    }
}
