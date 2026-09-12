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

    private var _store: EKEventStore?
    private var store: EKEventStore? {
        guard ApprovalNotificationController.hasBundleProxy else { return nil }
        if _store == nil {
            _store = EKEventStore()
        }
        return _store
    }

    private var eventStoreObserver: NSObjectProtocol?
    private var debounceSyncTask: Task<Void, Never>?

    private init() {
        checkAuthorizationStatus()
    }

    /// Check system authorization status and cache default calendar list.
    public func checkAuthorizationStatus() {
        let auth = isAuthorized
        authorized = auth
        if auth {
            startStoreObserver()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.defaultList = self.store?.defaultCalendarForNewReminders()
            }
        }
    }

    /// Listens for iCloud / background updates to the EventStore.
    public func startStoreObserver() {
        guard ApprovalNotificationController.hasBundleProxy else { return }
        guard eventStoreObserver == nil else { return }
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.debounceInboundSync()
            }
        }
    }

    private func debounceInboundSync() {
        debounceSyncTask?.cancel()
        debounceSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.syncInboundReminders()
        }
    }

    /// Background inbound sync from Apple Reminders into Bantay TaskStore using default shared store.
    public func syncInboundReminders() async {
        await syncInboundReminders(into: .shared)
    }

    /// Background inbound sync from Apple Reminders into an explicit TaskStore.
    public func syncInboundReminders(into taskStore: TaskStore) async {
        guard NotchHUDConfig.shared.syncAppleReminders, isAuthorized else { return }
        await refresh()
        let batch: [(rawTitle: String, dueDate: Date?, externalID: String?)] = reminders.compactMap
        { item in
            guard let title = item.title, !title.isEmpty else { return nil }
            return (
                rawTitle: title, dueDate: item.dueDateComponents?.date,
                externalID: item.calendarItemIdentifier
            )
        }
        taskStore.batchIngestExternalReminders(batch)
    }

    /// Whether Reminders access is already granted (macOS 13-safe; the 14+
    /// `.fullAccess` enum case is mapped to authorized here).
    public var isAuthorized: Bool {
        guard ApprovalNotificationController.hasBundleProxy else { return false }
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
        guard let store else { return false }
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToReminders()
            } else {
                granted = try await store.requestAccess(to: .reminder)
            }
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
                defaultList = store?.defaultCalendarForNewReminders()
            }
            return true
        }
        return await requestAccess()
    }

    /// Refresh reminders from the default list, newest-sorted by due date.
    public func refresh() async {
        guard isAuthorized else {
            authorized = false
            reminders = []
            return
        }
        authorized = true
        if defaultList == nil {
            defaultList = store?.defaultCalendarForNewReminders()
        }
        isLoading = true
        defer { isLoading = false }
        guard let store else { return }
        let calendar = defaultList ?? store.defaultCalendarForNewReminders()
        guard let calendar else { return }
        let predicate = store.predicateForReminders(in: [calendar])
        // EKReminder isn't Sendable; the fetch callback is @Sendable.
        // AtomicRemindersGate safely coordinates the EventKit callback and 2.0s timeout
        // through an @unchecked Sendable locked container with a Void continuation.
        let gate = AtomicRemindersGate()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.fetchReminders(matching: predicate) { items in
                gate.resume(with: items ?? [], continuation: cont)
            }
            // Timeout safety: resume after 2.0s if EventKit daemon is slow/unresponsive
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                gate.resume(with: [], continuation: cont)
            }
        }
        reminders = gate.items
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
        guard let store else { return false }
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
        guard let store else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        await refresh()
    }

    /// Remove a reminder.
    public func remove(_ reminder: EKReminder) async {
        guard let store else { return }
        try? store.remove(reminder, commit: true)
        await refresh()
    }
}

/// Thread-safe single-resume gate coordinating [EKReminder] and preventing race conditions.
public final class AtomicRemindersGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    public var items: [EKReminder] = []

    public init() {}

    @discardableResult
    public func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }

    public func resume(with items: [EKReminder], continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        self.items = items
        continuation.resume()
    }
}
