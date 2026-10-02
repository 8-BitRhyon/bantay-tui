import AppKit
import SwiftUI

/// Compact dark OLED card summarizing background activity during the user's absence.
struct AwayDigestCardView: View {
    let digest: AwayDigest
    let onDismiss: () -> Void

    init(digest: AwayDigest, onDismiss: @escaping () -> Void) {
        self.digest = digest
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("🌙")
                    .font(.system(size: 11))
                Text("While you were away")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(BantayTheme.textPrimary)

                Text(digest.formattedDuration)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(BantayTheme.statusWorking)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(BantayTheme.statusWorking.opacity(0.12))
                    .clipShape(Capsule())

                Spacer()

                Button(action: {
                    #if os(macOS)
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .generic, performanceTime: .now)
                    #endif
                    onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(BantayTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss away digest")
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(digest.summaryLines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•")
                            .font(.system(size: 9))
                            .foregroundColor(BantayTheme.textTertiary)
                        Text(line)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(BantayTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }

            if let fastest = digest.fastestAgent, digest.completedTasks.count > 1 {
                HStack(spacing: 4) {
                    Text("⚡️ Fastest:")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(BantayTheme.textTertiary)
                    Text("\(fastest.agent) (\(Int(fastest.duration))s)")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(BantayTheme.statusCompleted)
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: BantayTheme.radiusMedium, style: .continuous)
                .fill(BantayTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BantayTheme.radiusMedium, style: .continuous)
                .strokeBorder(BantayTheme.borderSubtle, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}
