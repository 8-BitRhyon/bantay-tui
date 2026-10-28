import SwiftUI

/// Navigation bar for the expanded notch HUD: core workflow tabs on the
/// leading edge (Inbox, Tasks, History), quick utility pills on the trailing
/// edge (Shelf, Media). Utilities stay one tap away without competing
/// with the agent workflow for visual weight.
struct NotchTabBarView: View {
    @Binding var selectedTab: ShelfTab
    var shelfDropGlow: Bool = false
    /// A drop forced the shelf open while its tab is hidden. Keep the shelf
    /// pill visible so the selected state is clear, and keep the other tabs
    /// reachable so the panel cannot trap the user.
    var forceShelfVisible: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if NotchHUDConfig.shared.showAgentsTab {
                tabButton(title: "Inbox", tab: .agents, shortcut: "1")
            }
            if NotchHUDConfig.shared.showTasksTab {
                tabButton(title: "Tasks", tab: .tasks, shortcut: "2")
            }
            if NotchHUDConfig.shared.attentionFilterEnabled {
                tabButton(title: "Attention", tab: .attention, shortcut: "3")
            }
            if NotchHUDConfig.shared.showHistoryTab {
                tabButton(title: "History", tab: .history, shortcut: "4")
            }
            Spacer(minLength: 0)
            if NotchHUDConfig.shared.showShelfTab || forceShelfVisible {
                utilityButton(
                    icon: "tray.and.arrow.down", tab: .shelf, shortcut: "5",
                    glow: shelfDropGlow)
            }
            if NotchHUDConfig.shared.showMediaTab {
                utilityButton(icon: "play.circle", tab: .media, shortcut: "7")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private func tabButton(title: String, tab: ShelfTab, shortcut: KeyEquivalent) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                    .foregroundColor(
                        isSelected ? BantayTheme.textPrimary : BantayTheme.textTertiary
                    )
                    .padding(.horizontal, 4)
                Capsule()
                    .fill(isSelected ? BantayTheme.statusWorking : Color.clear)
                    .frame(height: 2)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }

    private func utilityButton(
        icon: String, tab: ShelfTab, shortcut: KeyEquivalent, glow: Bool = false
    ) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    isSelected ? BantayTheme.statusWorking : BantayTheme.textTertiary
                )
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            glow
                                ? BantayTheme.statusWorking.opacity(0.25)
                                : (isSelected
                                    ? BantayTheme.statusWorking.opacity(0.14) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .help(tab.rawValue)
        .accessibilityLabel("\(tab.rawValue) tab")
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }
}
