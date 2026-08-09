import SwiftUI

/// Native SwiftUI view implementing the Barrie-inspired Task Management Widget.
@MainActor
public struct TaskWidgetView: View {
    @ObservedObject var taskStore = TaskStore.shared
    @StateObject private var reminders = RemindersProvider.shared
    @State private var searchText = ""
    @State private var newTaskTitle = ""
    @State private var hoveredTaskID: UUID?
    @State private var remindersEnabled = false
    @State private var reminderAddText = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Search and quick task creation bar (Barrie style)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                TextField(
                    "Search or add a task (@work, @claude, !!)...", text: $newTaskTitle,
                    onCommit: createNewTask
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .disableAutocorrection(true)

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

            // Scrollable task list categorized into Barrie sections
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // Apple Reminders sync section (top, compact).
                    remindersSection

                    let overdue = taskStore.tasks(in: .overdue, searchQuery: newTaskTitle)
                    let today = taskStore.tasks(in: .today, searchQuery: newTaskTitle)
                    let later = taskStore.tasks(in: .later, searchQuery: newTaskTitle)
                    let completed = taskStore.tasks(in: .completed, searchQuery: newTaskTitle)

                    if overdue.isEmpty && today.isEmpty && later.isEmpty && completed.isEmpty {
                        emptyStateView
                    } else {
                        if !overdue.isEmpty {
                            taskSection(
                                title: "OVERDUE", tasks: overdue, color: Color(hex: "FF453A"))
                        }
                        if !today.isEmpty {
                            taskSection(title: "TODAY", tasks: today, color: Color(hex: "FF9F0A"))
                        }
                        if !later.isEmpty {
                            taskSection(title: "LATER", tasks: later, color: Color(hex: "64D2FF"))
                        }
                        if !completed.isEmpty {
                            taskSection(
                                title: "COMPLETED (\(taskStore.doneTodayCount) DONE TODAY 🎉)",
                                tasks: completed, color: Color(hex: "30D158"))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.dashed")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.3))
            Text("No tasks yet")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            Text("Add a task above or tag @claude, @herdr to assign to an agent.")
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Apple Reminders section: one-tap sync, quick add, and live items with
    /// complete/remove. Collapsed to a single row when disabled.
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
                Spacer()
                if reminders.isLoading {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    remindersEnabled.toggle()
                    if remindersEnabled {
                        Task { await reminders.refresh() }
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
                if !reminders.authorized {
                    HStack(spacing: 8) {
                        Text("Allow Reminders access in System Settings to sync.")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.6))
                        Button("Allow") {
                            Task {
                                _ = await reminders.requestAccess()
                                await reminders.refresh()
                            }
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .buttonStyle(.borderless)
                    }
                } else {
                    // Quick add into Reminders.
                    HStack(spacing: 6) {
                        TextField("Add reminder…", text: $reminderAddText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10))
                            .onSubmit {
                                let title = reminderAddText.trimmingCharacters(
                                    in: .whitespacesAndNewlines)
                                guard !title.isEmpty else { return }
                                Task {
                                    await reminders.add(title: title)
                                    reminderAddText = ""
                                }
                            }
                        Button {
                            let title = reminderAddText.trimmingCharacters(
                                in: .whitespacesAndNewlines)
                            guard !title.isEmpty else { return }
                            Task {
                                await reminders.add(title: title)
                                reminderAddText = ""
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(
                        Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    if reminders.reminders.isEmpty {
                        Text("No upcoming reminders.")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.vertical, 2)
                    } else {
                        ForEach(reminders.reminders.prefix(8), id: \.calendarItemIdentifier) { r in
                            HStack(spacing: 7) {
                                Button {
                                    Task { await reminders.complete(r) }
                                } label: {
                                    Image(systemName: "circle")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.5))
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
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    taskStore.toggleCompleted(task.id)
                }
                if !task.isCompleted {
                    NSSound(named: "Tink")?.play()
                }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(task.isCompleted ? .green : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "Mark incomplete" : "Mark completed")
            .accessibilityLabel(task.isCompleted ? "Completed" : "Incomplete")

            // Task title and tags
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(task.isCompleted ? .white.opacity(0.4) : .white)
                        .strikethrough(task.isCompleted)
                        .lineLimit(2)

                    if task.priority == .high {
                        Text("!!")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
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
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15), in: Capsule())
                    }

                    ForEach(task.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }

            Spacer(minLength: 4)

            // Hover actions: Run with Agent & Delete
            if hoveredTaskID == task.id {
                HStack(spacing: 4) {
                    if let agent = task.assignedAgent {
                        Button {
                            runWithAgent(task, agent: agent)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "bolt.fill")
                                Text("Run")
                            }
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Dispatch prompt to \(agent)")
                    }

                    Button {
                        withAnimation {
                            taskStore.removeTask(task.id)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete task")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            hoveredTaskID == task.id ? Color.white.opacity(0.08) : Color.white.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered in
            hoveredTaskID = isHovered ? task.id : nil
        }
    }

    private func createNewTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        taskStore.addTask(title)  // addTask parses NL internally (date/priority/tags)
        newTaskTitle = ""
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
        // Dispatches prompt to target agent via control gateway
        let promptText = task.title
        NotificationCenter.default.post(
            name: Notification.Name("BantayRunTaskWithAgent"),
            object: nil,
            userInfo: ["prompt": promptText, "agent": agent]
        )
    }
}
