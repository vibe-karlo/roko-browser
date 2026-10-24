import EventKit
import Foundation

/// Today's events from the calendars on this iPhone (iCloud, Google, Outlook,
/// whatever is added in Settings → Calendar), read here and never sent anywhere.
nonisolated struct TodayEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
}

@MainActor
enum TodayCalendar {
    private static let store = EKEventStore()

    static var isAllowed: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var wasAsked: Bool {
        EKEventStore.authorizationStatus(for: .event) != .notDetermined
    }

    /// Asks once; afterwards the answer stands until changed in iOS Settings.
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Calendars left out of Today. Kept as the ones left out, so a calendar
    /// added later shows up without a trip here.
    static var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "today.hiddenCalendars") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "today.hiddenCalendars") }
    }

    /// Every calendar with events on this iPhone.
    static func calendars() -> [EKCalendar] {
        guard isAllowed else { return [] }
        return store.calendars(for: .event)
    }

    /// The next thing on your calendar this week that hasn't ended, all-day
    /// ones only when nothing else is left today.
    static func next(now: Date = .now) -> TodayEvent? {
        guard isAllowed else { return nil }
        let shown = calendars().filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty, let end = Calendar.current.date(byAdding: .day, value: 7, to: now) else { return nil }
        let events = store.events(matching: store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now),
                                                                     end: end, calendars: shown))
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        guard let event = events.first(where: { !$0.isAllDay }) ?? events.first else { return nil }
        return TodayEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event",
                          start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                          location: event.location.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// "Now, until 15:30", "In 25 min, at 14:30", "Tomorrow at 9:00", "Thu at 10:00".
    static func when(_ event: TodayEvent, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = event.start.formatted(date: .omitted, time: .shortened)
        if event.start <= now { return event.isAllDay ? "Today, all day" : "Now, until \(event.end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if calendar.isDateInToday(event.start) {
            if event.isAllDay { return "Today, all day" }
            if minutes < 60 { return "In \(max(minutes, 1)) min, at \(time)" }
            return "Today at \(time)"
        }
        let day = calendar.isDateInTomorrow(event.start) ? "Tomorrow" : event.start.formatted(.dateTime.weekday(.abbreviated))
        return event.isAllDay ? "\(day), all day" : "\(day) at \(time)"
    }

    /// What's left of today: events that haven't ended, all-day ones first.
    static func events() -> [TodayEvent] {
        guard isAllowed else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let shown = calendars().filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        return store.events(matching: predicate)
            .filter { $0.isAllDay || $0.endDate > .now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(8)
            .map { event in
                TodayEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event",
                           start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                           location: event.location.flatMap { $0.isEmpty ? nil : $0 })
            }
    }
}
