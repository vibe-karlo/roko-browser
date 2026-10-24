import SwiftData
import UserNotifications

/// Two quiet reminders at most a day, both without sound:
/// - 8:30 in the morning, "Today is ready", only if Today hasn't been opened yet that day;
/// - 16:00, how many of today's to-dos are still open, only if any are.
/// Worked out again whenever roko goes to the background or Today is opened,
/// so a reminder never says something already done.
@MainActor
enum DailyReminders {
    static let key = "today.reminders"
    private static let morningID = "roko.today.morning"
    private static let todoID = "roko.todo.afternoon"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Asked once, the first time Today or To-do is opened.
    static func askIfNeeded() {
        guard isOn else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .badge])
            }
        }
    }

    static func update(in context: ModelContext) {
        let open = ((try? context.fetch(FetchDescriptor<Todo>())) ?? []).filter(\.isDueNow).count
        update(openToday: open)
    }

    static func update(openToday: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [morningID, todoID])
        guard isOn else { return }
        let calendar = Calendar.current
        let now = Date.now

        // The next morning roko hasn't shown Today on: today's, if it's still early and it hasn't.
        let shownToday = (UserDefaults.standard.object(forKey: "today.lastShown") as? Date).map(calendar.isDateInToday) ?? false
        let morningToday = calendar.date(bySettingHour: 8, minute: 30, second: 0, of: now)!
        let morning = (!shownToday && morningToday > now) ? morningToday : calendar.date(byAdding: .day, value: 1, to: morningToday)!
        let morningContent = UNMutableNotificationContent()
        morningContent.title = "Today"
        morningContent.body = "The weather, your calendar, to-dos and the news, ready for you."
        morningContent.userInfo = ["url": "roko://today"]
        morningContent.interruptionLevel = .passive
        add(morningID, morningContent, at: morning)

        // This afternoon, only if to-dos are open now (it's withdrawn when they're done).
        let afternoon = calendar.date(bySettingHour: 16, minute: 0, second: 0, of: now)!
        guard openToday > 0, afternoon > now else { return }
        let todoContent = UNMutableNotificationContent()
        todoContent.title = "To-do"
        todoContent.body = openToday == 1 ? "One to-do left for today." : "\(openToday) to-dos left for today."
        todoContent.userInfo = ["url": "roko://todo"]
        todoContent.interruptionLevel = .passive
        add(todoID, todoContent, at: afternoon)
    }

    private static func add(_ id: String, _ content: UNNotificationContent, at date: Date) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }
}
