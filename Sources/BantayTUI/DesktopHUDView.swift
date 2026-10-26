import SwiftUI

/// Bottom-center spatial HUD for Desktop strip control. Window-only surface:
/// column cards, one primary Chain action, overview, navigation, and an
/// overflow Layout menu. Never renders agent rows or approval controls.
struct DesktopHUDView: View {
    @ObservedObject private var strip = StripWindowManager.shared
    @ObservedObject private var hud = DesktopHUDController.shared
    @ObservedObject private var eventManager = AgentEventManager.shared

    private var windowCount: Int {
        strip.columns.reduce(0) { $0 + $1.windows.count }
    }

    private var approvalCount: Int {
        eventManager.agents.filter {
            $0.kind == .accessRequest || $0.kind == .waiting
        }.count
    }

    private var activeAppName: String {
        guard strip.columns.indices.contains(strip.activeColumnIndex),
            let win = strip.columns[strip.activeColumnIndex].activeWindow
        else { return "No window" }
        if let name = win.agentName, !name.isEmpty { return name }
        return win.title.isEmpty ? "Desktop" : win.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerBar
            if !StripWindowRegistry.hasAccessibilityPermission() {
                accessibilityCard
            }
            columnCards
            actionBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: DesktopHUDController.panelWidth, height: DesktopHUDController.panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 10 / 255, green: 12 / 255, blue: 16 / 255).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .onHover { hud.noteHover($0) }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Desktop")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(.white)
            Text("\(strip.columns.count) cols · \(windowCount) windows")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
            Text(activeAppName)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if approvalCount > 0 {
                Button {
                    hud.hide()
                    NotificationCenter.default.post(name: .notchExpandRequested, object: nil)
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(BantayTheme.statusAttention).frame(width: 6, height: 6)
                        Text("\(approvalCount) need you")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(BantayTheme.statusAttention)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(BantayTheme.statusAttention.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open the Agents inbox at these approvals")
                .accessibilityLabel("\(approvalCount) approvals need you. Open Agents inbox.")
            }
            Button {
                hud.isPinned.toggle()
            } label: {
                Image(systemName: hud.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        hud.isPinned ? BantayTheme.statusWorking : BantayTheme.textTertiary
                    )
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hud.isPinned ? "Unpin Desktop HUD" : "Pin Desktop HUD open")
            .accessibilityLabel(hud.isPinned ? "Unpin Desktop HUD" : "Pin Desktop HUD open")
            Button {
                AppDelegate.showSettings(route: .desktop)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BantayTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
            Button {
                hud.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BantayTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Desktop HUD")
            .accessibilityLabel("Close Desktop HUD")
        }
    }

    private var accessibilityCard: some View {
        Button {
            StripWindowRegistry.openAccessibilitySettings()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(BantayTheme.statusAttention)
                Text("Accessibility permission needed to arrange windows")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                Text("Grant in Settings")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(BantayTheme.statusAttention)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(BantayTheme.statusAttention.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Accessibility permission needed. Open System Settings.")
    }

    private var columnCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(strip.columns.enumerated()), id: \.element.id) { index, col in
                    columnCard(index: index, col: col)
                }
            }
        }
    }

    private func columnCard(index: Int, col: StripColumn) -> some View {
        let isActive = index == strip.activeColumnIndex
        let isVisible = col.windows.contains { strip.layoutResult.visibleWindowIDs.contains($0.id) }
        let hasApproval = col.windows.contains { $0.agentStatus == .needsApproval }
        return Button {
            if index == strip.activeColumnIndex,
                strip.columns.indices.contains(index),
                strip.columns[index].windows.count > 1
            {
                strip.focusNextWindow()
            } else {
                strip.jumpToColumn(index: index)
            }
            if hasApproval {
                hud.hide()
                NotificationCenter.default.post(name: .notchExpandRequested, object: nil)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(for: col))
                        .frame(width: 6, height: 6)
                    if let win = col.activeWindow {
                        Text(win.agentName ?? win.title)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if col.windows.count > 1 {
                        Text("\(min(col.focusedRow + 1, col.windows.count))/\(col.windows.count)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(isActive ? .white : .white.opacity(0.55))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    if col.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        isActive
                            ? Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
                            : (isVisible
                                ? Color.white.opacity(0.5) : Color.white.opacity(0.15))
                    )
                    .frame(width: max(48, CGFloat(col.widthFraction * 120)), height: 3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        hasApproval
                            ? BantayTheme.statusAttention
                            : (isActive
                                ? Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
                                : Color.clear),
                        lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(
            hasApproval
                ? "Focus window and open its approval"
                : (col.windows.count > 1
                    ? "Select column. Click again to cycle its \(col.windows.count) windows."
                    : "Select column."))
    }

    private func statusColor(for col: StripColumn) -> Color {
        guard let win = col.activeWindow else { return Color.gray.opacity(0.3) }
        switch win.agentStatus {
        case .needsApproval: return BantayTheme.statusAttention
        case .working: return BantayTheme.statusWorking
        case .completed: return BantayTheme.statusCompleted
        case .failed: return BantayTheme.statusFailed
        case .idle: return Color.white.opacity(0.2)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                strip.autoChainCurrentProject(slug: strip.currentProjectSlug())
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .bold))
                    Text("Chain")
                        .font(.system(size: 10, weight: .semibold))
                    Text("⌃⌥M")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(BantayTheme.statusWorking.opacity(0.2), in: Capsule())
                .overlay(Capsule().stroke(BantayTheme.statusWorking.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Chain current project windows (⌃⌥M)")
            .accessibilityLabel("Chain current project windows")

            Button {
                strip.toggleOverviewMode()
            } label: {
                Text(strip.isOverviewMode ? "Exit overview" : "Overview")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Toggle bird's-eye overview")
            .accessibilityLabel("Toggle overview")

            Spacer(minLength: 4)

            Button {
                strip.focusLeft()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Focus left (⌃⌥←)")
            .accessibilityLabel("Focus left column")

            Button {
                strip.focusRight()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Focus right (⌃⌥→)")
            .accessibilityLabel("Focus right column")

            Button {
                strip.cycleWidth()
            } label: {
                Text(widthLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Cycle width (⌃⌥R)")
            .accessibilityLabel("Cycle column width")

            Menu {
                Button("Move left (⌃⌥⇧←)") { strip.moveLeft() }
                Button("Move right (⌃⌥⇧→)") { strip.moveRight() }
                Divider()
                Button("Stack right (⌃⌥])") { strip.stackRight() }
                Button("Stack left (⌃⌥[)") { strip.stackLeft() }
                Button("Pop out (⌃⌥⇧])") { strip.unstack(toRight: true) }
                Button("Toggle tabs (⌃⌥⇧T)") { strip.toggleTabbed() }
                Divider()
                Button(
                    strip.columns.indices.contains(strip.activeColumnIndex)
                        && strip.columns[strip.activeColumnIndex].isPinned
                        ? "Unpin column (⌃⌥P)" : "Pin column (⌃⌥P)"
                ) {
                    strip.togglePin()
                }
                Button("Full width (⌃⌥F)") { strip.toggleFullWidth() }
                Button("Center column (⌃⌥C)") { strip.centerActiveColumn() }
                Divider()
                Button(strip.config.statusHalosEnabled ? "Hide focus halos" : "Show focus halos") {
                    strip.config.statusHalosEnabled.toggle()
                }
                Button(strip.config.dimInactive ? "Stop dimming inactive" : "Dim inactive windows")
                {
                    strip.config.dimInactive.toggle()
                }
                Divider()
                Button("Open Desktop Settings…") { AppDelegate.showSettings(route: .desktop) }
            } label: {
                HStack(spacing: 4) {
                    Text("Layout")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .help("Column layout and display options")
            .accessibilityLabel("Layout options")
        }
    }

    private var widthLabel: String {
        guard strip.columns.indices.contains(strip.activeColumnIndex) else { return "––%" }
        let pct = Int((strip.columns[strip.activeColumnIndex].widthFraction * 100).rounded())
        return "\(pct)%"
    }
}
