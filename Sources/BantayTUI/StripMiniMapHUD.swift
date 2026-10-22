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
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: Column Radar Cards
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
                                        .font(
                                            .system(size: 9, weight: .medium, design: .monospaced)
                                        )
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
                                            ? Color(
                                                red: 245 / 255, green: 158 / 255, blue: 11 / 255)
                                            : Color.clear),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Row 2: Action Controls Bar (Matching ChainYourMac UI)
            HStack(spacing: 5) {
                StripActionPill(title: "Focus left", shortcut: "←") {
                    StripWindowManager.shared.focusLeft()
                }
                StripActionPill(title: "Focus right", shortcut: "→") {
                    StripWindowManager.shared.focusRight()
                }
                StripActionPill(title: "Move left", shortcut: "⇧←") {
                    StripWindowManager.shared.moveLeft()
                }
                StripActionPill(title: "Move right", shortcut: "⇧→") {
                    StripWindowManager.shared.moveRight()
                }
                StripActionPill(title: "Cycle width", shortcut: "R") {
                    StripWindowManager.shared.cycleWidth()
                }
                StripActionPill(title: "Full width", shortcut: "F") {
                    StripWindowManager.shared.toggleFullWidth()
                }
                StripActionPill(title: "Centre", shortcut: "C") {
                    StripWindowManager.shared.centerCurrentColumn()
                }
                StripActionPill(
                    title: "Pin", shortcut: "P",
                    isHighlighted: columns.indices.contains(activeColumnIndex)
                        && columns[activeColumnIndex].isPinned
                ) {
                    StripWindowManager.shared.togglePin()
                }
                StripActionPill(title: "Stack", shortcut: "]") {
                    StripWindowManager.shared.stackRight()
                }
                StripActionPill(title: "Pop out", shortcut: "⇧]") {
                    StripWindowManager.shared.unstack(toRight: true)
                }
                StripActionPill(
                    title: "Tabs", shortcut: "⇧T",
                    isHighlighted: columns.indices.contains(activeColumnIndex)
                        && columns[activeColumnIndex].isTabbed
                ) {
                    StripWindowManager.shared.toggleTabbed()
                }
                StripActionPill(
                    title: "Focus border",
                    isHighlighted: StripWindowManager.shared.config.statusHalosEnabled
                ) {
                    StripWindowManager.shared.config.statusHalosEnabled.toggle()
                }
                StripActionPill(
                    title: "Dim inactive",
                    isHighlighted: StripWindowManager.shared.config.dimInactive
                ) {
                    StripWindowManager.shared.config.dimInactive.toggle()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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

/// Compact pill button for strip actions matching the ChainYourMac UI.
struct StripActionPill: View {
    let title: String
    var shortcut: String? = nil
    var isHighlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(
                            isHighlighted
                                ? Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
                                : Color.white.opacity(0.5)
                        )
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                Text(title)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(
                        isHighlighted
                            ? Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
                            : Color.white.opacity(0.85))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        isHighlighted
                            ? Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255).opacity(0.15)
                            : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(
                        isHighlighted
                            ? Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
                            : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
