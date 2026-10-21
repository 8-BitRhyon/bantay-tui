import SwiftUI

/// Underline tab bar with animated indicator for the expanded notch HUD.
struct NotchTabBarView: View {
    @Binding var selectedTab: ShelfTab

    var body: some View {
        HStack(spacing: 4) {
            if NotchHUDConfig.shared.showAgentsTab {
                tabButton(title: "Agents", tab: .agents, shortcut: "1")
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
            if NotchHUDConfig.shared.showShelfTab {
                tabButton(title: "Shelf", tab: .shelf, shortcut: "5")
            }
            if NotchHUDConfig.shared.showMediaTab {
                tabButton(title: "Media", tab: .media, shortcut: "6")
            }
            if NotchHUDConfig.shared.showNotesTab {
                tabButton(title: "Notes", tab: .notes, shortcut: "7")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
    }

    private func tabButton(title: String, tab: ShelfTab, shortcut: KeyEquivalent) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? BantayTheme.textPrimary : BantayTheme.textTertiary)
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
}
