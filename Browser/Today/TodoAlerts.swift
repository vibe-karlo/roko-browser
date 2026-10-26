import SwiftData
import UserNotifications

/// A to-do with a time: a notification 15 minutes before, with sound, unlike
/// the quiet daily reminders. They're laid out again after every save, so a
/// to-do ticked off, moved or deleted never rings.
@MainActor
enum TodoAlerts {
    private static let prefix = "roko.todo.at."
    static let lead: TimeInterval = 15 * 60
    private static var container: ModelContainer?
    private static var observer: NSObjectProtocol?

    /// Asked the first time a to-do gets a time.
    static func askIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }

    /// Follows every save in the app's store.
    static func watch(_ container: ModelContainer) {
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
            // Pages visited are saved all the time: only a save that touched a to-do counts.
            let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            let touched = keys.contains { key in
                (note.userInfo?[key.rawValue] as? [PersistentIdentifier])?.contains { $0.entityName == "Todo" } ?? false
            }
            guard touched else { return }
            MainActor.assumeIsolated {
                update()
                WidgetBridge.update()
            }
        }
        update()
    }

    static func update() {
        guard let context = container?.mainContext else { return }
        let now = Date.now
        let due = ((try? context.fetch(FetchDescriptor<Todo>())) ?? [])
            .compactMap { todo -> (String, Date, String)? in
                guard Preferences.todoAlerts, !todo.done, let time = todo.time, time.addingTimeInterval(-lead) > now else { return nil }
                return (todo.title, time, prefix + String(Int(time.timeIntervalSinceReferenceDate)) + "." + todo.title)
            }
            .sorted { $0.1 < $1.1 }
            // iOS keeps 64 at most, and the daily reminders and Notify Me need room.
            .prefix(40)
        let center = UNUserNotificationCenter.current()
        let prefix = prefix
        // Awaited rather than a reply handler: iOS answers on a queue of its own.
        Task {
            let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for (title, time, id) in due {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = "At " + time.formatted(date: .omitted, time: .shortened)
                content.sound = .default
                content.userInfo = ["url": "roko://todo"]
                let moment = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                             from: time.addingTimeInterval(-lead))
                try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                            trigger: UNCalendarNotificationTrigger(dateMatching: moment, repeats: false)))
            }
        }
    }
}
