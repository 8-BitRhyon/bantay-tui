import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Compact strip indicator: one tile per column, shown while navigating.
/// Hold Control-Option to keep it on screen, click a tile to jump, drag a
/// tile to reorder. Replaces the earlier oversized minimap panel, whose
/// action pills duplicated the Desktop HUD.
struct StripIndicatorView: View {
    let columns: [StripColumn]
    let activeColumnIndex: Int
    let visibleWindowIDs: Set<String>
    /// Widest the capsule may grow; extra columns scroll sideways instead of
    /// clipping off screen.
    let maxWidth: CGFloat
    let onSelect: (Int) -> Void
    let onReorder: (Int, Int) -> Void

    @State private var draggingIndex: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    tile(index: index, column: column)
                        .onDrag {
                            draggingIndex = index
                            return NSItemProvider(object: String(index) as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: StripTileDropDelegate(
                                target: index,
                                draggingIndex: $draggingIndex,
                                onReorder: onReorder))
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).fill(Color.black.opacity(0.35)))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Strip indicator, column \(activeColumnIndex + 1) of \(columns.count)")
    }

    @ViewBuilder
    private func tile(index: Int, column: StripColumn) -> some View {
        let isActive = index == activeColumnIndex
        let isOnScreen = column.windows.contains { visibleWindowIDs.contains($0.id) }
        let hasApproval = column.windows.contains { $0.agentStatus == .needsApproval }
        let accent = Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
        let attention = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)

        Button {
            onSelect(index)
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    appIcon(for: column.activeWindow?.appBundleID)
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(statusColor(column.activeWindow?.agentStatus))
                        .frame(width: 4, height: 4)
                    if column.windows.count > 1 {
                        Text("\(min(column.focusedRow + 1, column.windows.count))")
                            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        isActive
                            ? accent : Color.white.opacity(isOnScreen ? 0.45 : 0.16)
                    )
                    .frame(width: max(14, CGFloat(column.widthFraction * 34)), height: 2.5)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isActive
                            ? Color.white.opacity(0.14)
                            : (isOnScreen
                                ? Color.white.opacity(0.06) : Color.black.opacity(0.28))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isActive ? accent : (hasApproval ? attention : Color.clear),
                        lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tileHelp(index: index, column: column))
        .accessibilityLabel(
            "Column \(index + 1), \(column.activeWindow?.agentName ?? column.activeWindow?.title ?? "window")"
                + (column.isPinned ? ", pinned" : "")
                + (hasApproval ? ", needs approval" : ""))
    }

    private func tileHelp(index: Int, column: StripColumn) -> String {
        var parts = ["Jump to column \(index + 1)"]
        parts.append("drag to reorder")
        if column.isPinned { parts.append("pinned") }
        if column.isTabbed { parts.append("tabbed") }
        if column.windows.count > 1 { parts.append("\(column.windows.count) windows") }
        return parts.joined(separator: " — ")
    }

    private func statusColor(_ status: StripAgentStatus?) -> Color {
        switch status {
        case .needsApproval:
            return Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
        case .working:
            return Color(red: 6 / 255, green: 182 / 255, blue: 212 / 255)
        case .completed:
            return Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255)
        case .failed:
            return Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
        case .idle, nil:
            return Color.white.opacity(0.25)
        }
    }

    /// App icon for a bundle ID, with an SF Symbol fallback. Icons are
    /// cached because the indicator rebuilds on every navigation step.
    private func appIcon(for bundleID: String?) -> some View {
        Group {
            if let bundleID, let icon = StripIndicatorIconCache.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

/// Icon cache keyed by bundle ID. NSWorkspace lookups hit disk, so the
/// indicator must not repeat them per render pass.
@MainActor
enum StripIndicatorIconCache {
    private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 14, height: 14)
        if cache.count > 64 { cache.removeAll() }
        cache[bundleID] = icon
        return icon
    }
}

/// Drag-to-reorder for indicator tiles. Reorders live as the pointer enters
/// a neighbouring tile, matching the drag feel of ChainYourMac.
private struct StripTileDropDelegate: DropDelegate {
    let target: Int
    @Binding var draggingIndex: Int?
    let onReorder: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let from = draggingIndex, from != target else { return }
        onReorder(from, target)
        draggingIndex = target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingIndex = nil
        return true
    }
}
