import EventKit
import Foundation

/// Live bridge to Apple Reminders via EventKit. Lets the task widget show and
/// edit real Reminders (today / overdue / upcoming) instead of an isolated
/// JSON store — the "connect to Apple tasks" ask.
///
/// Permission: the app needs "Reminders" access; `requestAccess` prompts once
/// and the result is cached (and the `NSRemindersUsageDescription` Info.plist
/// key must be set — setup.sh writes it into the bundle).
@MainActor
public final class RemindersProvider: ObservableObject {
    public static let shared = RemindersProvider()

    @Published public private(set) var authorized = false
    @Published public private(set) var reminders: [EKReminder] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var defaultList: EKCalendar?

    // EKEventStore is thread-safe for the calls below; marking it
    // nonisolated(unsafe) avoids the Swift 6.1 "sending 'self.store' risks
    // causing data races" error when awaiting its nonisolated async methods
    // from a @MainActor class. All real accesses stay on the main actor.
    nonisolated(unsafe) private let store = EKEventStore()

    private init() {
        checkAuthorizationStatus()
    }

    /// Check system authorization status and cache default calendar list.
    public func checkAuthorizationStatus() {
        let auth = isAuthorized
        authorized = auth
        if auth {
            defaultList = store.defaultCalendarForNewReminders()
        }
    }

    /// Whether Reminders access is already granted (macOS 13-safe; the 14+
    /// `.fullAccess` enum case is mapped to authorized here).
    public var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    /// Request Reminders permission (prompts once).
    public func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestAccess(to: .reminder)
            authorized = granted
            if granted { defaultList = store.defaultCalendarForNewReminders() }
            return granted
        } catch {
            authorized = false
            return false
        }
    }

    /// Ensure we have access, requesting if needed.
    public func ensureAccess() async -> Bool {
        if isAuthorized {
            authorized = true
            if defaultList == nil {
                defaultList = store.defaultCalendarForNewReminders()
            }
            return true
        }
        return await requestAccess()
    }

    /// Refresh reminders from the default list, newest-sorted by due date.
    public func refresh() async {
        guard await ensureAccess() else { return }
        isLoading = true
        defer { isLoading = false }
        let calendar = defaultList ?? store.defaultCalendarForNewReminders()
        guard let calendar else { return }
        let predicate = store.predicateForReminders(in: [calendar])
        // EKReminder isn't Sendable; the fetch callback is @Sendable, so move
        // through an @unchecked Sendable box (single-writer, continuation
        // ordered) like the rest of the codebase's AppKit bridges.
        let box = RemindersBox()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.fetchReminders(matching: predicate) { items in
                box.items = items ?? []
                cont.resume()
            }
        }
        reminders = box.items
            .filter { !$0.isCompleted }
            .sorted {
                ($0.dueDateComponents?.date ?? .distantFuture)
                    < ($1.dueDateComponents?.date ?? .distantFuture)
            }
    }

    /// Add a reminder to the default list.
    @discardableResult
    public func add(title: String, due: Date? = nil) async -> Bool {
        guard await ensureAccess() else { return false }
        let list = defaultList ?? store.defaultCalendarForNewReminders()
        guard let list else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        do {
            try store.save(reminder, commit: true)
            await refresh()
            return true
        } catch {
            return false
        }
    }

    /// Mark a reminder complete.
    public func complete(_ reminder: EKReminder) async {
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        await refresh()
    }

    /// Remove a reminder.
    public func remove(_ reminder: EKReminder) async {
        try? store.remove(reminder, commit: true)
        await refresh()
    }
}

/// @unchecked Sendable box for crossing the EventKit callback into the
/// continuation (EKReminder is not Sendable; single-writer + continuation
/// ordering make this safe).
private final class RemindersBox: @unchecked Sendable {
    var items: [EKReminder] = []
}
