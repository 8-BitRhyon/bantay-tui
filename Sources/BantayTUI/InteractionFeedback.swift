import SwiftUI

/// Shared interaction motion. Durations follow the transitions.dev scale so
/// press, hover, selection, and commit feedback read as one system instead of
/// each control inventing its own timing.
enum InteractionMotion {
    static let micro = 0.08
    static let quick = 0.15

    /// Contact should feel immediate, so press-down is short and decelerating.
    static let press = Animation.easeOut(duration: 0.11)
    /// Release springs back with a small overshoot.
    static let release = Animation.spring(response: 0.26, dampingFraction: 0.62)
    static let hoverIn = Animation.easeOut(duration: quick)
    static let hoverOut = Animation.easeOut(duration: micro)
    static let selection = Animation.spring(response: 0.24, dampingFraction: 0.7)

    /// How long a delivered action holds before the card leaves, so the
    /// commit flash is visible without making the action feel slow.
    static let commitHold: Duration = .milliseconds(200)
}

/// Press physics shared by notch controls. Reading `configuration.isPressed`
/// directly keeps the response on the same frame as the click.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94
    var pressedBrightness: Double = -0.05
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(pressed && !reduceMotion ? pressedScale : 1)
            .brightness(pressed ? pressedBrightness : 0)
            .animation(
                pressed ? InteractionMotion.press : InteractionMotion.release,
                value: pressed
            )
    }
}

/// Horizontal shake used when delivery is refused. Failure feedback should be
/// felt, not only read in the inline reason line.
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 5
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    /// Horizontal offset for a normalized progress value. Exposed separately
    /// so the motion math can be checked without a render pass.
    static func offset(progress: CGFloat, amount: CGFloat = 5, shakes: CGFloat = 3) -> CGFloat {
        amount * sin(progress * .pi * shakes)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = Self.offset(progress: animatableData, amount: amount, shakes: shakes)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

/// Border highlight that marks a card action as committed. Plays once per
/// token so repeated deliveries each get their own beat.
struct CommitFlashModifier: ViewModifier {
    let token: Int
    let cornerRadius: CGFloat
    let reduceMotion: Bool

    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2)
                    .opacity(opacity)
                    .allowsHitTesting(false)
            )
            .onChange(of: token) { newValue in
                guard newValue > 0, !reduceMotion else { return }
                opacity = 1
                withAnimation(.easeOut(duration: 0.18)) { opacity = 0 }
            }
    }
}

extension View {
    func commitFlash(token: Int, cornerRadius: CGFloat, reduceMotion: Bool) -> some View {
        modifier(
            CommitFlashModifier(
                token: token, cornerRadius: cornerRadius, reduceMotion: reduceMotion))
    }
}
