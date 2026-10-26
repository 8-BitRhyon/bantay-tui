import SwiftUI

/// Placeholder rows shown while a tab loads its data off the main thread.
/// The mode-switch tap must always paint instantly: this renders on the
/// first frame, then the real content replaces it when the background load
/// lands. Static under reduce motion.
struct LoadingSkeleton: View {
    let rows: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    private var shimmerAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<max(rows, 1), id: \.self) { index in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(shimmer ? 0.09 : 0.04))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .animation(shimmerAnimation, value: shimmer)
                    .accessibilityHidden(index > 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
        .onAppear {
            guard !reduceMotion else { return }
            shimmer = true
        }
    }
}
