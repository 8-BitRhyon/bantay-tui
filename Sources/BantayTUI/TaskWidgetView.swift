import EventKit
import SwiftUI

/// SwiftUI view for task management.
@MainActor
public struct TaskWidgetView: View {
    @ObservedObject var taskStore = TaskStore.shared
    @StateObject private var reminders = RemindersProvider.shared
    @State private var newTaskTitle = ""
    @State private var hoveredTaskID: UUID?
    @State private var remindersEnabled = NotchHUDConfig.shared.syncAppleReminders
    @FocusState private var fieldFocused: Bool
    /// Last deleted task for Undo. The banner dismisses itself after 5s.
    @State private var deletedBackup: BantayTask?
    @State private var undoTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Search and quick task creation bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                TextField(
                    "Search or add tasks...", text: $newTaskTitle,
                    onCommit: createNewTask
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .disableAutocorrection(true)
                .focused($fieldFocused)
                .onExitCommand { newTaskTitle = "" }

                if !newTaskTitle.isEmpty {
                    Button(action: createNewTask) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add task (Return)")
                    .accessibilityLabel("Add task")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            parsePreview

            // Scrollable task list
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Apple Reminders sync section
                    remindersSection

                    let categorized = taskStore.categorizedTasks(searchQuery: newTaskTitle)

                    if categorized.isEmpty {
                        emptyStateView
                    } else {
                        if !categorized.overdue.isEmpty {
                            taskSection(
                                title: "OVERDUE", tasks: categorized.overdue,
                                color: BantayTheme.statusFailed)
                        }
                        if !categorized.today.isEmpty {
                            taskSection(
                                title: "TODAY", tasks: categorized.today,
                                color: BantayTheme.statusQuota)
                        }
                        if !categorized.later.isEmpty {
                            taskSection(
                                title: "LATER", tasks: categorized.later,
                                color: BantayTheme.statusWorking)
                        }
                        if !categorized.completed.isEmpty {
                            taskSection(
                                title: "COMPLETED · \(categorized.doneTodayCount) TODAY",
                                tasks: categorized.completed, color: BantayTheme.statusCompleted)
                        }
                        if deletedBackup != nil {
                            HStack(spacing: 8) {
                                Text("Task deleted")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))
                                Spacer(minLength: 4)
                                Button("Undo") { undoDelete() }
                                    .font(.system(size: 10, weight: .bold))
                                    .buttonStyle(.plain)
                                    .foregroundColor(BantayTheme.statusAttention)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            reminders.checkAuthorizationStatus()
            let enabled = remindersEnabled || NotchHUDConfig.shared.syncAppleReminders
            if enabled && reminders.isAuthorized {
                Task {
                    await reminders.refresh()
                }
            }
        }
    }

    private var emptyStateView: some View {
        let query = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.dashed")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.3))
            if !query.isEmpty {
                Text("No matches for “\(query)”")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("Clear search") { newTaskTitle = "" }
                    .font(.system(size: 9.5, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(BantayTheme.statusAttention)
            } else if unlinkedReminders.isEmpty {
                Text("No tasks yet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Text("Add a task above or tag @claude, @herdr to assign to an agent.")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                if !remindersEnabled {
                    Button("Connect Reminders") {
                        remindersEnabled = true
                        NotchHUDConfig.shared.syncAppleReminders = true
                        Task {
                            if await reminders.requestAccess() {
                                await reminders.refresh()
                            }
                        }
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(BantayTheme.statusAttention)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Reminders already mirrored as tasks. Showing both lists at once
    /// renders every synced item twice, so the Reminders box only shows
    /// what is not yet in the task list.
    private var unlinkedReminders: [EKReminder] {
        reminders.reminders.filter { reminder in
            !taskStore.tasks.contains { task in
                if let ext = task.externalID, !ext.isEmpty {
                    return reminder.calendarItemIdentifier == ext
                }
                return task.title.caseInsensitiveCompare(reminder.title ?? "") == .orderedSame
            }
        }
    }

    /// Apple Reminders section with sync and quick add.
    @ViewBuilder
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.blue.opacity(0.9))
                Text("APPLE REMINDERS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue.opacity(0.9))
                if let listName = reminders.defaultList?.title, !listName.isEmpty {
                    Text(listName)
                        .font(.system(size: 8.5))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .help("Syncs with this Reminders list only")
                }
                Spacer()
                if reminders.isLoading {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    remindersEnabled.toggle()
                    NotchHUDConfig.shared.syncAppleReminders = remindersEnabled
                    if remindersEnabled {
                        Task {
                            if !reminders.isAuthorized {
                                _ = await reminders.requestAccess()
                            }
                            await reminders.refresh()
                        }
                    }
                } label: {
                    Image(systemName: remindersEnabled ? "link.circle.fill" : "link.circle")
                        .font(.system(size: 13))
                        .foregroundColor(
                            remindersEnabled ? .blue : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Sync Apple Reminders")
            }

            if remindersEnabled {
                if !reminders.authorized && !reminders.isAuthorized {
                    HStack(spacing: 8) {
                        Image(systemName: reminders.permissionDenied ? "lock.slash" : "bell.badge")
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.9))
                        Text(
                            reminders.permissionDenied
                                ? "Access denied. Turn Reminders on in System Settings."
                                : "Allow access to sync your Reminders list."
                        )
                        .font(.system(size: 9.5))
                        .foregroundColor(.white.opacity(0.6))
                        Button(reminders.permissionDenied ? "Open Settings" : "Allow") {
                            if reminders.permissionDenied {
                                reminders.openPrivacySettings()
                            } else {
                                Task {
                                    _ = await reminders.requestAccess()
                                    await reminders.refresh()
                                }
                            }
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .buttonStyle(.borderless)
                    }
                } else {
                    // One entry point: the top field creates the task and,
                    // when sync is on, its reminder. A second input here
                    // only ever misfiled items.
                    if unlinkedReminders.isEmpty {
                        Text("Everything is in your tasks.")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.vertical, 2)
                    } else {
                        ForEach(unlinkedReminders.prefix(8), id: \.calendarItemIdentifier) { r in
                            HStack(spacing: 7) {
                                Button {
                                    Task { await reminders.complete(r) }
                                } label: {
                                    Image(systemName: "circle")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.5))
                                        .frame(minWidth: 28, minHeight: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Complete in Reminders")

                                Text(r.title ?? "(untitled)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 4)

                                if let due = r.dueDateComponents?.date {
                                    Text(IslandMetrics.elapsedLabel(since: due, now: Date()))
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundColor(
                                            due < Date()
                                                ? Color(hex: "FF453A")
                                                : .white.opacity(0.4))
                                }

                                Button {
                                    Task { await reminders.remove(r) }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.4))
                                        .frame(minWidth: 28, minHeight: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove reminder")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    private func taskSection(title: String, tasks: [BantayTask], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                Spacer()
            }
            .padding(.top, 4)

            ForEach(tasks) { task in
                taskRow(task, categoryColor: color)
            }
        }
    }

    private func taskRow(_ task: BantayTask, categoryColor: Color) -> some View {
        HStack(spacing: 8) {
            // Interactive Barrie checkmark circle
            Button {
                withAnimation(BantayTheme.springSnappy) {
                    taskStore.toggleCompleted(task.id)
                }
                if !task.isCompleted, NotchHUDConfig.shared.enableAgentAlerts {
                    NSSound(named: "Tink")?.play()
                }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(
                        task.isCompleted ? BantayTheme.statusCompleted : BantayTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "Mark incomplete" : "Mark completed")
            .accessibilityLabel(task.isCompleted ? "Completed" : "Incomplete")

            // Task title and tags
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(
                            task.isCompleted ? BantayTheme.textTertiary : BantayTheme.textPrimary
                        )
                        .strikethrough(task.isCompleted)
                        .lineLimit(2)

                    if task.priority == .high {
                        Text("!!")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(BantayTheme.statusFailed)
                    }

                    if task.externalID != nil {
                        Text("REMINDERS")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(.blue.opacity(0.85))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .help("Synced with Apple Reminders")
                    }
                }

                HStack(spacing: 6) {
                    if let agent = task.assignedAgent {
                        HStack(spacing: 3) {
                            Image(systemName: "cpu")
                                .font(.system(size: 7))
                            Text(agent)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(BantayTheme.statusWorking)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(BantayTheme.statusWorking.opacity(0.15), in: Capsule())

                        if let routed = task.routedAgent {
                            Text("→ \(routed)")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(BantayTheme.statusAttention)
                                .help("Quota routing diverted this task from \(agent)")
                                .accessibilityLabel("Rerouted to \(routed)")
                        }

                        executionStateBadge(task)
                    }

                    ForEach(task.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(BantayTheme.textTertiary)
                    }
                }
            }

            Spacer(minLength: 4)

            // Hover actions: Run with Agent & Delete
            if hoveredTaskID == task.id || task.assignedAgent != nil {
                HStack(spacing: 4) {
                    if let agent = task.assignedAgent, !task.isCompleted {
                        Button {
                            runWithAgent(task, agent: agent)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "bolt.fill")
                                Text(
                                    task.executionState == .blocked
                                        || task.executionState == .failed
                                        ? "Retry"
                                        : (task.executionState == .pending ? "Run" : "Re-run"))
                            }
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(BantayTheme.statusAttention, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Dispatch prompt to \(agent)")
                    }

                    if hoveredTaskID == task.id {
                        Button {
                            deleteWithUndo(task)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(BantayTheme.statusFailed.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Delete task (Undo available)")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            hoveredTaskID == task.id ? BantayTheme.cardHover : BantayTheme.cardBackground,
            in: RoundedRectangle(cornerRadius: BantayTheme.radiusSmall, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BantayTheme.radiusSmall, style: .continuous)
                .stroke(
                    hoveredTaskID == task.id ? BantayTheme.borderStandard : Color.clear,
                    lineWidth: 0.5)
        )
        .onHover { isHovered in
            hoveredTaskID = isHovered ? task.id : nil
        }
    }

    @ViewBuilder
    private func stateBadge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 7))
            Text(label)
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(color.opacity(0.2), in: Capsule())
    }

    @ViewBuilder
    private func executionStateBadge(_ task: BantayTask) -> some View {
        switch task.executionState {
        case .pending, .dispatched:
            stateBadge(
                icon: "clock", label: "Queued",
                color: BantayTheme.textTertiary)
        case .working:
            HStack(spacing: 2) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 7))
                Text("Working")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(BantayTheme.statusWorking)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(BantayTheme.statusWorking.opacity(0.2), in: Capsule())
        case .blocked:
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 7))
                Text("Blocked")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(BantayTheme.statusAttention)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(BantayTheme.statusAttention.opacity(0.2), in: Capsule())
        case .failed:
            HStack(spacing: 2) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 7))
                Text("Failed")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(BantayTheme.statusFailed)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(BantayTheme.statusFailed.opacity(0.2), in: Capsule())
        default:
            EmptyView()
        }
    }

    private func createNewTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        taskStore.addTask(title)  // addTask parses NL internally (date/priority/tags)
        newTaskTitle = ""
    }

    /// Delete with a 5s Undo window. The store restores the exact task
    /// (same id, tombstones cleared, reminder re-linked) on Undo.
    private func deleteWithUndo(_ task: BantayTask) {
        deletedBackup = task
        undoTask?.cancel()
        withAnimation {
            taskStore.removeTask(task.id)
        }
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { deletedBackup = nil }
        }
    }

    private func undoDelete() {
        undoTask?.cancel()
        if let backup = deletedBackup {
            taskStore.restoreTask(backup)
        }
        deletedBackup = nil
    }

    /// Barrie-style live preview: as the user types, show what the natural
    /// language parser understood (due date, priority, agent) before saving.
    @ViewBuilder
    private var parsePreview: some View {
        let parsed = TaskStore.parseNaturalLanguage(newTaskTitle)
        let hasSignal =
            parsed.dueDate != nil || parsed.priority != .medium
            || parsed.assignedAgent != nil || !parsed.tags.isEmpty
        if !newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasSignal {
            HStack(spacing: 6) {
                if let due = parsed.dueDate {
                    Label(
                        IslandMetrics.elapsedLabel(since: due, now: Date()),
                        systemImage: "calendar"
                    )
                    .foregroundColor(.orange)
                }
                if parsed.priority == .high {
                    Label("high", systemImage: "exclamationmark")
                        .foregroundColor(.red)
                }
                if let agent = parsed.assignedAgent {
                    Label(agent, systemImage: "terminal")
                        .foregroundColor(.cyan)
                }
                ForEach(parsed.tags, id: \.self) { tag in
                    Label(tag, systemImage: "tag")
                        .foregroundColor(.blue)
                }
                Spacer()
                Text(parsed.cleanTitle)
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    private func runWithAgent(_ task: BantayTask, agent: String) {
        taskStore.dispatchTask(task.id)
    }
}
