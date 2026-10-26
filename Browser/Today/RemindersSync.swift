import EventKit
import SwiftData
import UIKit

/// Keeps roko's to-dos and one list in Apple Reminders the same, both ways:
/// added, renamed, moved to another day or time, ticked off or deleted on one
/// side, it's so on the other. Reminders syncs that list through iCloud to
/// your other devices, the Mac and the Watch.
///
/// Each to-do remembers its reminder and how both looked at the last sync
/// (`reminderState`): the side that no longer looks like that is the one that
/// changed. Changed on both sides at once, Reminders wins. What can't be said
/// in Reminders stays roko's own: "this week" is the week's last day there.
@MainActor
enum RemindersSync {
    static let enabledKey = "reminders.sync"
    static let listKey = "reminders.list"
    private static let linkedKey = "reminders.linked"

    private static let store = EKEventStore()
    private static var container: ModelContainer?
    private static var running = false
    private static var again = false
    private static var pending: Task<Void, Never>?
    /// Changes roko itself just made, to either side, don't start another round.
    private static var quietUntil = Date.distantPast
    private static var observers: [NSObjectProtocol] = []

    static var isOn: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var isAllowed: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    // MARK: Lists

    /// Every list in Reminders that can take new reminders.
    static func lists() -> [EKCalendar] {
        guard isAllowed else { return [] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The list being synced: the one chosen, else a "roko" list, made the first time.
    static func list() -> EKCalendar? {
        guard isAllowed else { return nil }
        if let id = UserDefaults.standard.string(forKey: listKey), let chosen = store.calendar(withIdentifier: id) {
            return chosen
        }
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == "roko" && $0.allowsContentModifications }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: listKey)
            return existing
        }
        let made = EKCalendar(for: .reminder, eventStore: store)
        made.title = "roko"
        // Where new lists go on this iPhone: iCloud when it's on.
        made.source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first { $0.sourceType == .local }
        guard (try? store.saveCalendar(made, commit: true)) != nil else { return nil }
        UserDefaults.standard.set(made.calendarIdentifier, forKey: listKey)
        return made
    }

    /// Another list chosen: what's linked to the old one starts afresh there.
    static func choose(_ list: EKCalendar) {
        UserDefaults.standard.set(list.calendarIdentifier, forKey: listKey)
        if let context = container?.mainContext {
            for todo in (try? context.fetch(FetchDescriptor<Todo>())) ?? [] {
                todo.reminderID = nil
                todo.reminderState = nil
            }
            try? context.save()
        }
        UserDefaults.standard.removeObject(forKey: linkedKey)
        schedule(after: .zero)
    }

    /// Off: the links are dropped, nothing is deleted on either side.
    static func turnOff() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        if let context = container?.mainContext {
            for todo in (try? context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { $0.reminderID != nil }))) ?? [] {
                todo.reminderID = nil
                todo.reminderState = nil
            }
            try? context.save()
        }
        UserDefaults.standard.removeObject(forKey: linkedKey)
    }

    // MARK: When

    static func start(_ container: ModelContainer) {
        self.container = container
        observers = [
            // Changed in Reminders, here or synced in from another device.
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { schedule(after: .seconds(1)) }
            },
            // Changed in roko: a save that touched a to-do.
            NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
                let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
                let touched = keys.contains { key in
                    (note.userInfo?[key.rawValue] as? [PersistentIdentifier])?.contains { $0.entityName == "Todo" } ?? false
                }
                guard touched else { return }
                MainActor.assumeIsolated { schedule(after: .seconds(1)) }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { schedule(after: .zero) }
            },
        ]
        schedule(after: .seconds(2))
    }

    /// A round soon; several changes in a row make one.
    static func schedule(after delay: Duration) {
        if LaunchClock.isEnabled, isOn, !isAllowed {
            print("REMINDERS not allowed: \(EKEventStore.authorizationStatus(for: .reminder).rawValue)")
        }
        guard isOn, isAllowed, Date.now >= quietUntil || delay == .zero else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    // MARK: The round

    private static func sync() async {
        guard isOn, isAllowed, let context = container?.mainContext, let list = list() else { return }
        if running {
            again = true
            return
        }
        running = true
        defer {
            running = false
            if again {
                again = false
                schedule(after: .seconds(1))
            }
        }
        let started = CACurrentMediaTime()

        // What's in the list: open ones, and those ticked off in the last two weeks.
        let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: .now)
        let handle = StoreHandle(store: store)
        let open = await fetch(handle, store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list]))
        let closed = await fetch(handle, store.predicateForCompletedReminders(withCompletionDateStarting: twoWeeksAgo, ending: nil,
                                                                              calendars: [list]))
        var reminders: [String: EKReminder] = [:]
        for reminder in open.reminders + closed.reminders { reminders[reminder.calendarItemIdentifier] = reminder }

        let linked = Set(UserDefaults.standard.stringArray(forKey: linkedKey) ?? [])
        let todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        var seen = Set<String>()
        var storeChanged = false

        // Linked: whichever side changed since last time.
        for todo in todos {
            guard let id = todo.reminderID else { continue }
            let reminder = reminders[id] ?? store.calendarItem(withIdentifier: id) as? EKReminder
            guard let reminder, reminder.calendar?.calendarIdentifier == list.calendarIdentifier else {
                // Deleted in Reminders (or moved to another list): gone here too.
                context.delete(todo)
                continue
            }
            seen.insert(id)
            let mine = fingerprint(todo), theirs = fingerprint(reminder)
            if mine == theirs {
                todo.reminderState = mine
            } else if theirs != todo.reminderState {
                pull(reminder, into: todo)
                todo.reminderState = fingerprint(todo)
            } else {
                push(todo, into: reminder)
                storeChanged = save(reminder) || storeChanged
                todo.reminderState = fingerprint(todo)
            }
        }

        // In roko only: into Reminders, unless it's long done. An unlinked
        // reminder that reads the same (from another device) is taken instead.
        for todo in todos where todo.reminderID == nil && todo.modelContext != nil {
            if todo.done, (todo.doneAt ?? .distantPast) < (twoWeeksAgo ?? .distantPast) { continue }
            let same = reminders.values.first { reminder in
                !seen.contains(reminder.calendarItemIdentifier) && !linked.contains(reminder.calendarItemIdentifier)
                    && fingerprint(reminder) == fingerprint(todo)
            }
            let reminder = same ?? EKReminder(eventStore: store)
            if same == nil {
                reminder.calendar = list
                push(todo, into: reminder)
                storeChanged = save(reminder) || storeChanged
            }
            todo.reminderID = reminder.calendarItemIdentifier
            todo.reminderState = fingerprint(todo)
            seen.insert(reminder.calendarItemIdentifier)
        }

        // In Reminders only: deleted in roko if it was linked, else a new to-do.
        for (id, reminder) in reminders where !seen.contains(id) {
            if linked.contains(id) {
                try? store.remove(reminder, commit: false)
                storeChanged = true
            } else if !reminder.isCompleted {
                let todo = Todo(title: reminder.title ?? "", when: .someday)
                pull(reminder, into: todo)
                todo.order = (todos.map(\.order).max() ?? 0) + 1
                todo.reminderID = id
                todo.reminderState = fingerprint(todo)
                context.insert(todo)
                seen.insert(id)
            }
        }

        quietUntil = .now.addingTimeInterval(2)
        if storeChanged { try? store.commit() }
        if context.hasChanges { try? context.save() }
        UserDefaults.standard.set(Array(seen), forKey: linkedKey)
        if LaunchClock.isEnabled {
            print(String(format: "REMINDERS %d to-dos, %d reminders, %.0fms", todos.count, reminders.count,
                         (CACurrentMediaTime() - started) * 1000))
        }
    }

    private static func save(_ reminder: EKReminder) -> Bool {
        (try? store.save(reminder, commit: false)) != nil
    }

    /// Off the main actor: EventKit answers on a queue of its own.
    nonisolated private static func fetch(_ handle: StoreHandle, _ predicate: NSPredicate) async -> ReminderBox {
        await withCheckedContinuation { (continuation: CheckedContinuation<ReminderBox, Never>) in
            handle.store.fetchReminders(matching: predicate) { @Sendable found in
                continuation.resume(returning: ReminderBox(reminders: found ?? []))
            }
        }
    }

    // MARK: Translating

    /// Title, day (and time), done: what both sides can say.
    static func fingerprint(_ todo: Todo) -> String {
        let day = todo.day.map { Self.dayKey.string(from: $0) } ?? "-"
        let time = todo.time.map { Self.timeKey.string(from: $0) } ?? "-"
        return "\(todo.title.trimmingCharacters(in: .whitespaces))|\(day)|\(time)|\(todo.done)"
    }

    static func fingerprint(_ reminder: EKReminder) -> String {
        let parts = reminder.dueDateComponents
        let calendar = Calendar.current
        let due = parts.flatMap { calendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day)) }
        let day = due.map { Self.dayKey.string(from: $0) } ?? "-"
        let time: String = if let parts, let hour = parts.hour, let minute = parts.minute {
            String(format: "%02d:%02d", hour, minute)
        } else { "-" }
        let title = (reminder.title ?? "").trimmingCharacters(in: .whitespaces)
        return "\(title)|\(day)|\(time)|\(reminder.isCompleted)"
    }

    private static func push(_ todo: Todo, into reminder: EKReminder) {
        reminder.title = todo.title
        let calendar = Calendar.current
        if let day = todo.day {
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            if let time = todo.time {
                let clock = calendar.dateComponents([.hour, .minute], from: time)
                parts.hour = clock.hour
                parts.minute = clock.minute
            }
            parts.calendar = calendar
            reminder.dueDateComponents = parts
        } else {
            reminder.dueDateComponents = nil
        }
        // roko's own alert comes 15 minutes before; Reminders' at the time itself.
        reminder.alarms = nil
        if todo.done != reminder.isCompleted {
            reminder.isCompleted = todo.done
            if todo.done { reminder.completionDate = todo.doneAt ?? .now }
        }
    }

    private static func pull(_ reminder: EKReminder, into todo: Todo) {
        todo.title = reminder.title ?? todo.title
        let calendar = Calendar.current
        if let parts = reminder.dueDateComponents,
           let day = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) {
            let sameWeekEnd = todo.wholeWeek && todo.day == calendar.startOfDay(for: day)
            if !sameWeekEnd {
                todo.day = calendar.startOfDay(for: day)
                todo.wholeWeek = false
            }
            if let hour = parts.hour, let minute = parts.minute {
                todo.time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: todo.day ?? day)
                todo.wholeWeek = false
            } else {
                todo.time = nil
            }
        } else {
            todo.day = nil
            todo.wholeWeek = false
            todo.time = nil
        }
        if reminder.isCompleted != todo.done {
            todo.done = reminder.isCompleted
            todo.doneAt = reminder.isCompleted ? (reminder.completionDate ?? .now) : nil
        }
    }

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// The store, handed to EventKit's fetch. EventKit's store is thread-safe.
nonisolated private struct StoreHandle: @unchecked Sendable {
    let store: EKEventStore
}

/// Reminders handed back from EventKit's queue; only read on the main actor.
nonisolated private struct ReminderBox: @unchecked Sendable {
    let reminders: [EKReminder]
}
