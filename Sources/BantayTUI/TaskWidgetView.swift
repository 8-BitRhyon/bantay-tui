import SwiftUI

/// Native SwiftUI view implementing the Barrie-inspired Task Management Widget.
@MainActor
public struct TaskWidgetView: View {
    @ObservedObject var taskStore = TaskStore.shared
    @State private var searchText = ""
    @State private var newTaskTitle = ""
    @State private var hoveredTaskID: UUID?

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

            // Scrollable task list categorized into Barrie sections
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
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
        taskStore.addTask(title)
        newTaskTitle = ""
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
