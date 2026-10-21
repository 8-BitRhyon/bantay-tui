import SwiftUI

/// Mini-map radar showing spatial layout and agent statuses across the infinite strip.
public struct StripMiniMapHUD: View {
    public let columns: [StripColumn]
    public let activeColumnIndex: Int
    public let visibleWindowIDs: Set<String>
    public let onSelectColumn: (Int) -> Void

    public init(
        columns: [StripColumn],
        activeColumnIndex: Int,
        visibleWindowIDs: Set<String>,
        onSelectColumn: @escaping (Int) -> Void
    ) {
        self.columns = columns
        self.activeColumnIndex = activeColumnIndex
        self.visibleWindowIDs = visibleWindowIDs
        self.onSelectColumn = onSelectColumn
    }

    private func agentIcon(for col: StripColumn) -> String {
        if let agentName = col.activeWindow?.agentName?.lowercased() {
            if agentName.contains("claude") { return "sparkles" }
            if agentName.contains("codex") { return "terminal" }
            if agentName.contains("antigravity") { return "atom" }
            if agentName.contains("cursor") { return "chevron.left.forwardslash.chevron.right" }
        }
        return "macwindow"
    }

    private func statusColor(for col: StripColumn) -> Color {
        guard let win = col.activeWindow else { return Color.gray.opacity(0.3) }
        switch win.agentStatus {
        case .needsApproval:
            return Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
        case .working:
            return Color(red: 6 / 255, green: 182 / 255, blue: 212 / 255)
        case .completed:
            return Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255)
        case .failed:
            return Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
        case .idle:
            return Color.white.opacity(0.2)
        }
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, col in
                let isActive = (index == activeColumnIndex)
                let isVisible = col.windows.contains { visibleWindowIDs.contains($0.id) }

                Button(action: {
                    onSelectColumn(index)
                }) {
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(statusColor(for: col))
                                .frame(width: 5, height: 5)

                            if let win = col.activeWindow {
                                Text(win.agentName ?? win.title)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        // Column width indicator bar
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                isActive
                                    ? Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
                                    : (isVisible
                                        ? Color.white.opacity(0.5) : Color.white.opacity(0.15))
                            )
                            .frame(
                                width: max(16, CGFloat(col.widthFraction * 40)),
                                height: 3
                            )
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isActive
                                    ? Color.white.opacity(0.12)
                                    : (isVisible
                                        ? Color.white.opacity(0.06) : Color.black.opacity(0.4))
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isActive
                                    ? Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
                                    : (col.windows.contains { $0.agentStatus == .needsApproval }
                                        ? Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
                                        : Color.clear),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 10 / 255, green: 12 / 255, blue: 16 / 255).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        )
    }
}
